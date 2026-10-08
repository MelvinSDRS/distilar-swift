import Foundation
import os

/// Reports on their way to the server: one file each, kept until the server
/// confirms them, sent one at a time, oldest first.
///
/// A report gets its Idempotency-Key before it is saved, and keeps it, so a
/// retry after a lost answer cannot store it twice.
actor Outbox {
    /// What became of an attempt to send a report.
    enum Outcome: Sendable, Equatable {
        /// The server has it.
        case sent
        /// It is kept, to try again later.
        case waiting
        /// The server refused it for good, so it was dropped.
        case refused(String)
    }

    /// The most reports kept at once.
    static let capacity = 20
    /// How long a report may wait for a connection before it is dropped.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    private let directory: URL
    private var client: IngestClient
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.distilar.sdk", category: "outbox")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var pass: Task<Void, Never>?
    private var passWanted = false
    private var retry: Task<Void, Never>?
    private var failedPasses = 0
    private var waiters: [UUID: [CheckedContinuation<Outcome, Never>]] = [:]

    init(directory: URL, client: IngestClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.client = client
        self.now = now
    }

    deinit {
        retry?.cancel()
    }

    /// Sends later attempts with this client, for a new key or server.
    func use(_ client: IngestClient) {
        self.client = client
    }

    /// Saves a report and its image, then waits for its first attempt, for
    /// at most `limit`. A report still on its way by then is `.waiting`.
    func submit(_ report: Report, image: Data?, within limit: Duration) async throws(DistilarError) -> Outcome {
        try save(report, image: image)
        let id = report.id
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.settle(id, .waiting)
            }
            requestPass()
        }
    }

    /// Tries to send every report that waits, and returns once none is
    /// being sent.
    func drain() async {
        requestPass()
        await pass?.value
    }

    private func requestPass() {
        passWanted = true
        guard pass == nil else { return }
        pass = Task { await runPasses() }
    }

    private func runPasses() async {
        while passWanted {
            passWanted = false
            await deliverWaitingReports()
        }
        pass = nil
        for id in waiters.keys {
            settle(id, .waiting)
        }
        scheduleRetry()
    }

    private func deliverWaitingReports() async {
        var stopped = false
        for var report in load() {
            if stopped || report.notBefore.map({ $0 > now() }) == true {
                settle(report.id, .waiting)
                continue
            }
            let outcome = await deliver(&report)
            switch outcome {
            case .sent:
                remove(report.id)
                failedPasses = 0
            case .refused(let reason):
                log.error("Dropped report \(report.id, privacy: .public): the server refused it: \(reason, privacy: .public)")
                remove(report.id)
            case .waiting:
                // No connection, or the server asked to wait: the next
                // reports would fare no better.
                failedPasses += 1
                stopped = true
            }
            settle(report.id, outcome)
        }
    }

    private func deliver(_ report: inout Report) async -> Outcome {
        do throws(DeliveryError) {
            var message = report.message
            message.screenshotID = try await uploadScreenshot(of: &report)
            _ = try await client.send(message, idempotencyKey: report.id)
            return .sent
        } catch {
            switch error {
            case .refused(let reason):
                return .refused(reason)
            case .unavailable(let retryAfter):
                if let retryAfter {
                    report.notBefore = now().addingTimeInterval(retryAfter)
                    write(report)
                }
                return .waiting
            case .slotGone:
                return .waiting
            }
        }
    }

    /// Puts the report's screenshot on the server, unless it is there
    /// already, and returns its id.
    private func uploadScreenshot(of report: inout Report) async throws(DeliveryError) -> UUID? {
        guard var attachment = report.screenshot else { return nil }
        if let id = attachment.uploadedID {
            return id
        }
        let id = report.id
        guard let image = try? Data(contentsOf: imageURL(id)) else {
            log.error("Report \(id, privacy: .public) lost its screenshot file; sending its text alone")
            return nil
        }
        // A slot kept from an earlier attempt may have expired since: it
        // gets one replacement.
        for _ in 0..<2 {
            let slot: ScreenshotSlot
            if let kept = attachment.slot {
                slot = kept
            } else {
                slot = try await client.openSlot()
                attachment.slot = slot
                report.screenshot = attachment
                write(report)
            }
            do {
                try await client.upload(image, contentType: attachment.contentType, to: slot)
            } catch .slotGone {
                attachment.slot = nil
                report.screenshot = attachment
                write(report)
                continue
            }
            attachment.slot = nil
            attachment.uploadedID = slot.id
            report.screenshot = attachment
            write(report)
            return slot.id
        }
        throw .unavailable(retryAfter: nil)
    }

    private func settle(_ id: UUID, _ outcome: Outcome) {
        for waiter in waiters.removeValue(forKey: id) ?? [] {
            waiter.resume(returning: outcome)
        }
    }

    /// Plans the next pass while reports wait: when the server said to, or
    /// after a delay that doubles with each failed pass, from 5 seconds up to
    /// 10 minutes.
    private func scheduleRetry() {
        retry?.cancel()
        retry = nil
        let reports = load()
        guard !reports.isEmpty else { return }
        let backoff = min(600, 5 * pow(2, Double(max(0, failedPasses - 1))))
        let next = reports.map { $0.notBefore ?? now().addingTimeInterval(backoff) }.min()!
        let delay = max(1, next.timeIntervalSince(now()))
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    // MARK: - Files

    private func reportURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString.lowercased()).json")
    }

    private func imageURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString.lowercased()).image")
    }

    private func save(_ report: Report, image: Data?) throws(DistilarError) {
        guard load().count < Self.capacity else { throw .queueFull }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = directory
            try folder.setResourceValues(values)
            // The report's file goes last: until it exists, the image is an
            // orphan that the next load deletes.
            if let image {
                try image.write(to: imageURL(report.id), options: .atomic)
            }
            try encoder.encode(report).write(to: reportURL(report.id), options: .atomic)
        } catch {
            log.error("Could not save a report: \(error, privacy: .public)")
            try? FileManager.default.removeItem(at: imageURL(report.id))
            throw .storage
        }
    }

    private func write(_ report: Report) {
        do {
            try encoder.encode(report).write(to: reportURL(report.id), options: .atomic)
        } catch {
            log.error("Could not update report \(report.id, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: reportURL(id))
        try? FileManager.default.removeItem(at: imageURL(id))
    }

    /// The reports on disk, oldest first. Drops what can no longer be sent:
    /// files that do not decode, reports past their age, orphan images.
    private func load() -> [Report] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = Set(files.map(\.lastPathComponent))
        var reports: [Report] = []
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            switch file.pathExtension {
            case "json":
                // A file that cannot be read now, such as before the first
                // unlock, is kept for later; one that does not decode never will.
                guard let data = try? Data(contentsOf: file) else { continue }
                guard let report = try? decoder.decode(Report.self, from: data) else {
                    log.error("Dropped an unreadable report file")
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.removeItem(at: directory.appending(path: "\(stem).image"))
                    continue
                }
                if now().timeIntervalSince(report.createdAt) > Self.maxAge {
                    log.error("Dropped report \(report.id, privacy: .public): it waited more than 30 days")
                    remove(report.id)
                    settle(report.id, .waiting)
                    continue
                }
                reports.append(report)
            case "image" where !names.contains("\(stem).json"):
                try? FileManager.default.removeItem(at: file)
            default:
                continue
            }
        }
        return reports.sorted { $0.createdAt < $1.createdAt }
    }
}
