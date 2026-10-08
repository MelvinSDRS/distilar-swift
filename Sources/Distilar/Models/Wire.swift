import Foundation

// The ingest API's request and response bodies, as its OpenAPI document at
// /v1/openapi.json defines them. The server refuses unknown fields, and an
// optional left nil is left out of the JSON.

/// The body of POST /v1/messages.
struct MessageBody: Codable, Sendable, Equatable {
    var kind: String
    var body: String
    var reporter: Reporter
    var appVersion: String?
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var screenshotID: UUID?

    enum CodingKeys: String, CodingKey {
        case kind, body, reporter, locale
        case appVersion = "app_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case screenshotID = "screenshot_id"
    }
}

/// Who sent a message: the install, and the app's user once signed in.
struct Reporter: Codable, Sendable, Equatable {
    var installID: String?
    var userID: String?

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case userID = "user_id"
    }
}

/// The answer to POST /v1/messages, both the first time (201) and for a repeat (200).
struct MessageCreated: Decodable, Sendable {
    var id: String
}

/// The answer to POST /v1/screenshots.
struct ScreenshotSlot: Codable, Sendable, Equatable {
    var id: UUID
    var uploadToken: String

    enum CodingKeys: String, CodingKey {
        case id
        case uploadToken = "upload_token"
    }
}

/// The answer to PUT /v1/screenshots/{id}.
struct UploadedScreenshot: Decodable, Sendable {
    var id: UUID
}

/// An RFC 9457 problem document, as the server sends with every error.
struct Problem: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        var location: String?
        var message: String?
    }

    var detail: String?
    var errors: [Detail]?

    /// The detail, followed by the first field error when there is one.
    var explanation: String? {
        let first = errors?.first.flatMap { error in
            error.message.map { message in error.location.map { "\($0): \(message)" } ?? message }
        }
        return [detail, first].compactMap(\.self).joined(separator: ": ").nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
