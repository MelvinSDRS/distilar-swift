import Foundation
import ImageIO
import Testing
@testable import Distilar

/// A live Distilar server, such as the dev server of the server repo, named
/// by two variables:
///
///     DISTILAR_E2E_URL=http://127.0.0.1:18080 DISTILAR_E2E_KEY=dpk_… swift test
enum LiveServer {
    static let url = ProcessInfo.processInfo.environment["DISTILAR_E2E_URL"].flatMap(URL.init(string:))
    static let key = ProcessInfo.processInfo.environment["DISTILAR_E2E_KEY"]

    static func outbox(_ transport: some Transport) -> OutboxFixture {
        OutboxFixture(transport, baseURL: url!, key: key!)
    }
}

/// Passes every request to the server, but loses the answer to the first
/// message: the server stores it, and the device never hears back.
actor LossyLink: Transport {
    private(set) var statuses: [Int] = []
    private(set) var messageIDs: [String] = []
    private var lostOne = false

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await URLSession.distilar.send(request)
        guard request.url?.path() == "/v1/messages", let http = response as? HTTPURLResponse else {
            return (data, response)
        }
        statuses.append(http.statusCode)
        if let created = try? JSONDecoder().decode(MessageCreated.self, from: data) {
            messageIDs.append(created.id)
        }
        if !lostOne {
            lostOne = true
            throw URLError(.networkConnectionLost)
        }
        return (data, response)
    }
}

@Suite(.enabled(if: LiveServer.url != nil && LiveServer.key != nil, "needs DISTILAR_E2E_URL and DISTILAR_E2E_KEY"))
struct EndToEndTests {
    @Test func aReportWithAPhotoReachesTheServer() async throws {
        let photo = try ScreenshotEncoderTests.image(width: 1170, height: 2532, as: .heic, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.5, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        let prepared = try await ScreenshotEncoder.prepare(photo)
        let fixture = LiveServer.outbox(URLSession.distilar)
        defer { fixture.removeFolder() }
        let report = Report.sample("End-to-end report with a photo, \(UUID())", installID: "e2e-\(UUID())",
                                   screenshot: prepared.contentType)

        #expect(try await fixture.outbox.submit(report, image: prepared.data, within: .seconds(30)) == .sent)
        #expect(fixture.files.isEmpty)
    }

    @Test func aLostAnswerEndsAsOneMessage() async throws {
        let link = LossyLink()
        let fixture = LiveServer.outbox(link)
        defer { fixture.removeFolder() }
        let report = Report.sample("End-to-end report whose answer is lost, \(UUID())", installID: "e2e-\(UUID())")

        #expect(try await fixture.outbox.submit(report, image: nil, within: .seconds(30)) == .waiting)
        await fixture.outbox.drain()

        // The retry is answered 200 with the first message: stored once.
        #expect(await link.statuses == [201, 200])
        let ids = await link.messageIDs
        #expect(ids.count == 2 && ids.first == ids.last)
        #expect(fixture.files.isEmpty)
    }
}
