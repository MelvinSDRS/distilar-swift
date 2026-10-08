import Foundation
import os
import Testing
@testable import Distilar

/// Stands in for the ingest API: answers each request with the next reply
/// of its script, and records what it was sent.
actor FakeServer: Transport {
    enum Reply: Sendable {
        case status(Int, json: String = "{}", headers: [String: String] = [:])
        /// The request never reaches a server, or its answer is lost.
        case offline
    }

    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        var json: [String: any Sendable] {
            (try? JSONSerialization.jsonObject(with: body) as? [String: any Sendable]) ?? [:]
        }
    }

    private var script: [Reply]
    private let latency: Duration
    private(set) var requests: [Request] = []

    init(_ script: [Reply] = [], latency: Duration = .zero) {
        self.script = script
        self.latency = latency
    }

    func then(_ replies: Reply...) {
        script += replies
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let recorded = Request(
            method: request.httpMethod ?? "GET",
            path: request.url?.path() ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Data()
        )
        requests.append(recorded)
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        guard !script.isEmpty else {
            Issue.record("unexpected request: \(recorded.method) \(recorded.path)")
            throw URLError(.cannotConnectToHost)
        }
        switch script.removeFirst() {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case let .status(code, json, headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(json.utf8), response)
        }
    }
}

extension FakeServer.Reply {
    static func created(_ id: UUID = UUID()) -> Self {
        .status(201, json: #"{"id":"\#(id.uuidString.lowercased())","created_at":"2026-10-08T12:00:00Z"}"#)
    }

    static func slot(_ id: UUID, token: String = "dut_token") -> Self {
        .status(201, json: #"{"id":"\#(id.uuidString.lowercased())","upload_token":"\#(token)","expires_at":"2026-10-08T12:15:00Z"}"#)
    }

    static func uploaded(_ id: UUID) -> Self {
        .status(200, json: #"{"id":"\#(id.uuidString.lowercased())","content_type":"image/png","byte_size":4}"#)
    }

    static func problem(_ status: Int, _ detail: String, headers: [String: String] = [:]) -> Self {
        .status(status, json: #"{"status":\#(status),"title":"","detail":"\#(detail)"}"#, headers: headers)
    }
}

/// An outbox in a fresh folder, talking to `server`.
struct OutboxFixture {
    let outbox: Outbox
    let directory: URL

    init(
        _ server: some Transport,
        baseURL: URL = URL(string: "https://distilar.test")!,
        key: String = "dpk_test",
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "distilar-tests/\(UUID())")
        let client = IngestClient(baseURL: baseURL, projectKey: key, transport: server)
        outbox = Outbox(directory: self.directory, client: client, now: now)
    }

    /// The files the outbox keeps.
    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []).sorted()
    }

    func removeFolder() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A clock a test moves by hand.
final class ManualClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Date.now)

    var now: Date { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 += seconds }
    }
}

extension Report {
    static func sample(
        _ text: String = "The search bar hides the first result",
        installID: String = "install-1",
        screenshot contentType: String? = nil
    ) -> Report {
        Report(
            id: UUID(),
            createdAt: .now,
            message: MessageBody(
                kind: "bug",
                body: text,
                reporter: Reporter(installID: installID, userID: nil),
                appVersion: "2.4 (318)",
                osVersion: "iOS 26.1",
                deviceModel: "iPhone17,1",
                locale: "fr_CA"
            ),
            screenshot: contentType.map { Report.Attachment(contentType: $0) }
        )
    }

    var key: String { id.uuidString.lowercased() }
}
