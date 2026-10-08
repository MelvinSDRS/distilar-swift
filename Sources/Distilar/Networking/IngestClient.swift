import Foundation

/// How the SDK reaches the server: URLSession in an app. Tests put a fake
/// server or a link that loses answers in its place.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: Transport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }

    /// The session every call uses: no cookies, no cache, and no waiting for
    /// a connection, since the outbox decides when to try again.
    static let distilar: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}

/// Why a call to the server failed.
enum DeliveryError: Error, Equatable {
    /// Try again later: no connection, a timeout, a server error or a full
    /// rate limit. The server may say how many seconds to wait.
    case unavailable(retryAfter: TimeInterval?)
    /// The upload slot expired, or the server does not know it: open another.
    case slotGone
    /// The server will never take this, however often it is sent.
    case refused(String)
}

/// The three calls of the ingest API the SDK makes.
struct IngestClient: Sendable {
    var baseURL: URL
    var projectKey: String
    var transport: any Transport

    static let clientName = "distilar-swift/\(Distilar.sdkVersion)"

    /// Opens a slot for one screenshot.
    func openSlot() async throws(DeliveryError) -> ScreenshotSlot {
        let (data, response) = try await call(request("POST", "v1/screenshots"))
        guard response.statusCode == 201 else { throw failure(response, data) }
        return try decode(ScreenshotSlot.self, from: data)
    }

    /// Sends the image for a slot. The server answers a repeat of a finished
    /// upload with its result, so a retry is safe.
    func upload(_ image: Data, contentType: String, to slot: ScreenshotSlot) async throws(DeliveryError) {
        var request = request("PUT", "v1/screenshots/\(slot.id.uuidString.lowercased())")
        request.setValue(slot.uploadToken, forHTTPHeaderField: "Upload-Token")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = image
        let (data, response) = try await call(request)
        switch response.statusCode {
        case 200:
            _ = try decode(UploadedScreenshot.self, from: data)
        case 403, 404, 410:
            throw .slotGone
        default:
            throw failure(response, data)
        }
    }

    /// Sends a message. Every attempt for one report carries the same
    /// Idempotency-Key, so the server stores it once.
    func send(_ message: MessageBody, idempotencyKey: UUID) async throws(DeliveryError) -> MessageCreated {
        var request = request("POST", "v1/messages")
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(message)
        } catch {
            throw .refused("the message could not be encoded: \(error)")
        }
        let (data, response) = try await call(request)
        guard response.statusCode == 200 || response.statusCode == 201 else { throw failure(response, data) }
        return try decode(MessageCreated.self, from: data)
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(projectKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.clientName, forHTTPHeaderField: "Distilar-Client")
        return request
    }

    private func call(_ request: URLRequest) async throws(DeliveryError) -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where Self.badAddress.contains(error.code) {
            throw .refused("the server address \(baseURL.absoluteString) cannot be used: \(error.code.rawValue)")
        } catch {
            throw .unavailable(retryAfter: nil)
        }
        guard let response = response as? HTTPURLResponse else { throw .unavailable(retryAfter: nil) }
        return (data, response)
    }

    /// Errors that a retry cannot fix: the address itself is wrong.
    private static let badAddress: Set<URLError.Code> = [
        .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection,
    ]

    private func failure(_ response: HTTPURLResponse, _ data: Data) -> DeliveryError {
        let status = response.statusCode
        if [408, 425, 429].contains(status) || (500...599).contains(status) {
            let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            return .unavailable(retryAfter: wait.map(TimeInterval.init))
        }
        let problem = try? JSONDecoder().decode(Problem.self, from: data)
        return .refused(problem?.explanation ?? "HTTP \(status)")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(DeliveryError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // A success status with some other body, such as a captive
            // portal's page: the report has not arrived.
            throw .unavailable(retryAfter: nil)
        }
    }
}
