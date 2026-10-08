import Foundation

/// One report in the outbox, as saved on the device. Its id is the
/// Idempotency-Key of every attempt to send it, so a retry after a lost
/// response cannot store it twice.
struct Report: Codable, Sendable, Identifiable {
    var id: UUID
    var createdAt: Date
    var message: MessageBody
    var screenshot: Attachment?
    /// Set when the server asked to wait, with Retry-After.
    var notBefore: Date?

    struct Attachment: Codable, Sendable {
        /// image/png or image/jpeg. The image itself is a file next to the report's.
        var contentType: String
        /// The upload slot in use, kept so that a retry does not open another.
        var slot: ScreenshotSlot?
        /// Set once the server has the image.
        var uploadedID: UUID?
    }
}

/// The rules a report's text follows before it leaves the device.
enum ReportText {
    /// The most the server takes, in Unicode scalars, which is how it counts.
    static let maxLength = 8192

    /// The text as it is sent: trimmed, and without NUL characters, which
    /// the server refuses.
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { $0.value != 0 }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The length the server checks.
    static func length(_ text: String) -> Int {
        clean(text).unicodeScalars.count
    }
}
