import Foundation
import Testing
@testable import Distilar

@Suite struct OutboxTests {
    @Test func aReportGoesOutWithWhatTheServerNeeds() async throws {
        let server = FakeServer([.created()])
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }
        let report = Report.sample()

        #expect(try await fixture.outbox.submit(report, image: nil, within: .seconds(5)) == .sent)

        let request = try #require(await server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/messages")
        #expect(request.headers["Authorization"] == "Bearer dpk_test")
        #expect(request.headers["Idempotency-Key"] == report.key)
        #expect(request.headers["Distilar-Client"] == "distilar-swift/\(Distilar.sdkVersion)")
        #expect(request.headers["Content-Type"] == "application/json")
        // The server refuses unknown fields: nothing beyond these, and no
        // null for what the report leaves out.
        let body = try JSONSerialization.jsonObject(with: request.body) as? NSDictionary
        #expect(body == [
            "kind": "bug",
            "body": "The search bar hides the first result",
            "reporter": ["install_id": "install-1"],
            "app_version": "2.4 (318)",
            "os_version": "iOS 26.1",
            "device_model": "iPhone17,1",
            "locale": "fr_CA",
        ])
        #expect(fixture.files.isEmpty)
    }

    @Test func aReportWaitsOutAnOutageAndKeepsItsKey() async throws {
        let offline = FakeServer([.offline])
        let fixture = OutboxFixture(offline)
        defer { fixture.removeFolder() }
        let report = Report.sample()

        #expect(try await fixture.outbox.submit(report, image: nil, within: .seconds(5)) == .waiting)
        #expect(fixture.files == ["\(report.key).json"])

        // The app restarts: a new outbox finds the report and sends it as it
        // was, under the same key, so the server can tell it is a repeat.
        let online = FakeServer([.status(200, json: #"{"id":"m1","created_at":"2026-10-08T12:00:00Z"}"#)])
        let relaunched = OutboxFixture(online, directory: fixture.directory)
        await relaunched.outbox.drain()

        let first = try #require(await offline.requests.first)
        let retry = try #require(await online.requests.first)
        #expect(retry.headers["Idempotency-Key"] == report.key)
        // The server compares the fields, not the bytes: key order may differ.
        #expect(NSDictionary(dictionary: retry.json) == NSDictionary(dictionary: first.json))
        #expect(fixture.files.isEmpty)
    }

    @Test func aRefusedReportIsDroppedWithTheServersReason() async throws {
        let server = FakeServer([
            .status(422, json: #"{"detail":"validation failed","errors":[{"location":"body.locale","message":"expected length <= 35"}]}"#),
        ])
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }

        let outcome = try await fixture.outbox.submit(.sample(), image: nil, within: .seconds(5))

        #expect(outcome == .refused("validation failed: body.locale: expected length <= 35"))
        #expect(fixture.files.isEmpty)
        await fixture.outbox.drain()
        #expect(await server.requests.count == 1)
    }

    @Test func aReportWaitsAsLongAsTheServerAsks() async throws {
        let clock = ManualClock()
        let server = FakeServer([.problem(429, "rate limit reporter-hour reached", headers: ["Retry-After": "120"])])
        let fixture = OutboxFixture(server, now: { clock.now })
        defer { fixture.removeFolder() }

        #expect(try await fixture.outbox.submit(.sample(), image: nil, within: .seconds(5)) == .waiting)
        clock.advance(by: 119)
        await fixture.outbox.drain()
        #expect(await server.requests.count == 1)

        await server.then(.created())
        clock.advance(by: 2)
        await fixture.outbox.drain()
        #expect(await server.requests.count == 2)
        #expect(fixture.files.isEmpty)
    }

    @Test func aScreenshotGoesUpBeforeTheMessageThatNamesIt() async throws {
        let slot = UUID()
        let server = FakeServer([.slot(slot, token: "dut_abc"), .uploaded(slot), .created()])
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }
        let image = Data([0x89, 0x50, 0x4E, 0x47])

        let outcome = try await fixture.outbox.submit(.sample(screenshot: "image/png"), image: image, within: .seconds(5))

        #expect(outcome == .sent)
        let requests = await server.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "POST /v1/screenshots",
            "PUT /v1/screenshots/\(slot.uuidString.lowercased())",
            "POST /v1/messages",
        ])
        #expect(requests[1].headers["Upload-Token"] == "dut_abc")
        #expect(requests[1].headers["Content-Type"] == "image/png")
        #expect(requests[1].body == image)
        #expect(requests[2].json["screenshot_id"] as? String == slot.uuidString)
        #expect(fixture.files.isEmpty)
    }

    @Test func aRetryKeepsItsSlotUntilTheServerForgetsIt() async throws {
        let first = UUID()
        let second = UUID()
        let server = FakeServer([.slot(first), .offline])
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }

        #expect(try await fixture.outbox.submit(.sample(screenshot: "image/png"), image: Data([1]), within: .seconds(5)) == .waiting)
        // The next attempt uploads to the same slot; once the server says it
        // expired, one new slot replaces it.
        await server.then(.problem(410, "this upload slot has expired"), .slot(second), .uploaded(second), .created())
        await fixture.outbox.drain()

        let requests = await server.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "POST /v1/screenshots",
            "PUT /v1/screenshots/\(first.uuidString.lowercased())",
            "PUT /v1/screenshots/\(first.uuidString.lowercased())",
            "POST /v1/screenshots",
            "PUT /v1/screenshots/\(second.uuidString.lowercased())",
            "POST /v1/messages",
        ])
        #expect(requests.last?.json["screenshot_id"] as? String == second.uuidString)
    }

    @Test func aScreenshotTheServerHasIsNotSentAgain() async throws {
        let slot = UUID()
        let server = FakeServer([.slot(slot), .uploaded(slot), .offline])
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }

        #expect(try await fixture.outbox.submit(.sample(screenshot: "image/jpeg"), image: Data([1]), within: .seconds(5)) == .waiting)
        await server.then(.created())
        await fixture.outbox.drain()

        let requests = await server.requests
        #expect(requests.map(\.path).filter { $0.hasPrefix("/v1/screenshots") }.count == 2)
        #expect(requests.last?.json["screenshot_id"] as? String == slot.uuidString)
        #expect(fixture.files.isEmpty)
    }

    @Test func callsAtOnceSendAReportOnce() async throws {
        let server = FakeServer([.created()], latency: .milliseconds(200))
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }
        let outbox = fixture.outbox

        await withTaskGroup { group in
            group.addTask { _ = try? await outbox.submit(.sample(), image: nil, within: .seconds(5)) }
            for _ in 0..<5 {
                group.addTask { await outbox.drain() }
            }
        }

        #expect(await server.requests.count == 1)
        #expect(fixture.files.isEmpty)
    }

    @Test func aSuccessThatIsNotTheAPIsAnswerKeepsTheReport() async throws {
        // Such as a captive portal's login page.
        let server = FakeServer([.status(200, json: "<html>Sign in to the Wi-Fi</html>")])
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }
        let report = Report.sample()

        #expect(try await fixture.outbox.submit(report, image: nil, within: .seconds(5)) == .waiting)
        #expect(fixture.files == ["\(report.key).json"])
    }

    @Test func theOutboxHoldsAtMostTwentyReports() async throws {
        let server = FakeServer(Array(repeating: .offline, count: Outbox.capacity))
        let fixture = OutboxFixture(server)
        defer { fixture.removeFolder() }

        for _ in 0..<Outbox.capacity {
            _ = try await fixture.outbox.submit(.sample(), image: nil, within: .seconds(5))
        }

        await #expect(throws: DistilarError.queueFull) {
            try await fixture.outbox.submit(.sample(), image: nil, within: .seconds(5))
        }
        #expect(fixture.files.count == Outbox.capacity)
    }

    @Test(arguments: [
        ("  Two spaces, then a newline\n", "Two spaces, then a newline", 26),
        ("NUL\u{0} inside", "NUL inside", 10),
        // One character on screen, two Unicode scalars: the server counts two.
        ("e\u{301}", "e\u{301}", 2),
    ])
    func textIsCleanedAndCountedAsTheServerCounts(text: String, sent: String, length: Int) {
        #expect(ReportText.clean(text) == sent)
        #expect(ReportText.length(text) == length)
    }
}
