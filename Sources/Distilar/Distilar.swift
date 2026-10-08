import Foundation

/// Distilar collects bug reports and feature requests from the people who
/// use your app.
///
/// Call ``configure(projectKey:baseURL:)`` once at launch, call
/// ``identify(appUserID:)`` when a user signs in or out, and present
/// ``DistilarFeedbackForm`` in a sheet.
@MainActor
public enum Distilar {
    /// Starts Distilar, and sends any report an earlier launch could not.
    ///
    /// Call it once at launch, before the form can appear. Calling it again
    /// switches to the new key or server, for reports still waiting too.
    ///
    /// - Parameters:
    ///   - projectKey: The project key from the Distilar dashboard. It is
    ///     meant to ship inside your app.
    ///   - baseURL: The Distilar server. Leave it out to use Distilar's own.
    public static func configure(projectKey: String, baseURL: URL = .distilarDefault) {
        Runtime.shared.configure(projectKey: projectKey, baseURL: baseURL)
    }

    /// Ties later reports to your app's id for the signed-in user, so that one
    /// person's reports count once across all their devices.
    ///
    /// Pass `nil` at sign-out. Never pass an email address or a name. The id is
    /// kept on the device until it changes.
    public static func identify(appUserID: String?) {
        Runtime.shared.identify(appUserID)
    }

    /// The version of this SDK, sent with each report.
    nonisolated static let sdkVersion = "0.1.0"
}

extension URL {
    /// Distilar's hosted server.
    public static let distilarDefault = URL(string: "https://api.distilar.com")!
}

/// What a report is about.
public enum FeedbackKind: String, Sendable, CaseIterable, Identifiable {
    /// Something that does not work as it should.
    case bug
    /// Something the user would like the app to do.
    case feature

    /// The kind itself, so that `.sheet(item:)` can present the form for it.
    public var id: Self { self }
}

/// Why the form could not take a report.
public enum DistilarError: Error, Sendable, Equatable {
    /// ``Distilar/configure(projectKey:baseURL:)`` was never called.
    case notConfigured
    /// The server refused the report, for a reason that sending it again
    /// would not change, such as an unknown project key. The text is the
    /// server's explanation, in English, for your logs.
    case rejected(String)
    /// Too many reports already wait on this device for a connection.
    case queueFull
    /// The report could not be saved on this device.
    case storage
}
