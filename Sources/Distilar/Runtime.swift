import Foundation
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The state behind ``Distilar``: where reports go, who sends them, and the
/// outbox that holds them until they arrive.
@MainActor
final class Runtime {
    static let shared = Runtime()

    private(set) var outbox: Outbox?
    private var triggers: Task<Void, Never>?
    private static let userIDKey = "com.distilar.user-id"

    func configure(projectKey: String, baseURL: URL) {
        let client = IngestClient(
            baseURL: baseURL,
            projectKey: projectKey.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: URLSession.distilar
        )
        if let outbox {
            Task {
                await outbox.use(client)
                await outbox.drain()
            }
            return
        }
        let outbox = Outbox(directory: Self.directory, client: client)
        self.outbox = outbox
        watch(outbox)
    }

    func identify(_ appUserID: String?) {
        let id = appUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.userIDKey)
        } else {
            // The server takes 200 characters at most.
            UserDefaults.standard.set(String(String.UnicodeScalarView(id.unicodeScalars.prefix(200))), forKey: Self.userIDKey)
        }
    }

    /// A report of what the form holds, with who sends it and from what device.
    func report(kind: FeedbackKind, text: String, screenshot: PreparedScreenshot?) -> Report {
        Report(
            id: UUID(),
            createdAt: .now,
            message: MessageBody(
                kind: kind.rawValue,
                body: ReportText.clean(text),
                reporter: Reporter(
                    installID: InstallID.current(),
                    userID: UserDefaults.standard.string(forKey: Self.userIDKey)
                ),
                appVersion: DeviceInfo.appVersion(),
                osVersion: DeviceInfo.osVersion(),
                deviceModel: DeviceInfo.model(),
                locale: DeviceInfo.locale()
            ),
            screenshot: screenshot.map { Report.Attachment(contentType: $0.contentType) }
        )
    }

    /// Sends what waits now, then again whenever the device gets a connection
    /// or the app comes back to the foreground.
    private func watch(_ outbox: Outbox) {
        #if canImport(UIKit)
        let foreground = UIApplication.willEnterForegroundNotification
        #else
        let foreground = NSApplication.didBecomeActiveNotification
        #endif
        triggers = Task {
            await outbox.drain()
            await withDiscardingTaskGroup { group in
                group.addTask {
                    for await path in NWPathMonitor() where path.status == .satisfied {
                        await outbox.drain()
                    }
                }
                group.addTask {
                    for await _ in NotificationCenter.default.notifications(named: foreground) {
                        await outbox.drain()
                    }
                }
            }
        }
    }

    private static var directory: URL {
        #if os(macOS)
        // Application Support is shared by every app on a Mac.
        let folder = (Bundle.main.bundleIdentifier ?? "Distilar") + "/Distilar/Outbox"
        #else
        let folder = "Distilar/Outbox"
        #endif
        return URL.applicationSupportDirectory.appending(path: folder)
    }
}
