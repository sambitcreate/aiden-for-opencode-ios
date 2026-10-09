import Foundation
import XCTest
@testable import AidenForOpenCode

/// Captures outgoing requests and serves scripted responses so transport
/// additions can be exercised without a live server.
private final class StubOpenCodeURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var recorded: [URLRequest] = []
    static var recordedBodies: [Data] = []

    static func reset(handler replacement: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil) {
        handler = replacement
        recorded = []
        recordedBodies = []
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubOpenCodeURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var payload = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                payload.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = payload
        }
        Self.recorded.append(recorded)
        Self.recordedBodies.append(recorded.httpBody ?? Self.copyHTTPBody(request) ?? Data())
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func copyHTTPBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

/// Minimal wire-valid `Session.Info` fixture.
private func sessionFixture(id: String, title: String) -> String {
    "{\"id\":\"\(id)\",\"projectID\":\"proj_1\",\"cost\":0," +
        "\"tokens\":{\"input\":0,\"output\":0,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}," +
        "\"time\":{\"created\":1,\"updated\":2},\"title\":\"\(title)\",\"location\":{\"directory\":\"/tmp/demo\"}}"
}

private func pageJSON(ids: [(id: String, title: String)], next: String?) -> String {
    let rows = ids.map { sessionFixture(id: $0.id, title: $0.title) }.joined(separator: ",")
    return "{\"data\":[\(rows)],\"cursor\":{\"previous\":null,\"next\":\(next.map { "\"\($0)\"" } ?? "null")}}"
}

private func httpResponse(_ urlString: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: urlString)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private func queryValue(_ name: String, in url: URL?) -> String? {
    guard let url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    return components.queryItems?.first { $0.name == name }?.value
}

final class OpenCodeV2AdditionsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubOpenCodeURLProtocol.reset()
    }

    override func tearDown() {
        StubOpenCodeURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() throws -> OpenCodeClient {
        try OpenCodeClient(
            config: OpenCodeServerConfig(baseURL: URL(string: "http://localhost:4096")!),
            configuration: StubOpenCodeURLProtocol.makeConfiguration()
        )
    }

    // MARK: - activeSessions

    func testActiveSessionsDecodesEmptyMap() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            (httpResponse(request.url!.absoluteString), Data("{\"data\":{}}".utf8))
        }
        let active = try await makeClient().activeSessions()
        XCTAssertTrue(active.isEmpty)
    }

    func testActiveSessionsCollectsIDsAndToleratesUnknownKinds() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "{\"data\":{\"ses_a\":{\"type\":\"running\"}," +
                "\"ses_b\":{\"type\":\"queued\"},\"ses_c\":{\"status\":\"mystery\"}}}"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }
        let active = try await makeClient().activeSessions()
        XCTAssertEqual(active, Set(["ses_a", "ses_b", "ses_c"]))
    }

    func testActiveSessionsSendsBasicHeaderAndNoQueryParams() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            (httpResponse(request.url!.absoluteString), Data("{\"data\":{}}".utf8))
        }
        _ = try await makeClient().activeSessions()

        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/api/session/active"))
        XCTAssertNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query)
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("Basic "))
    }

    // MARK: - allSessions pagination

    func testAllSessionsWalksCursorPagesAndResendsLimit() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let cursor = components.queryItems?.first { $0.name == "cursor" }?.value
            if cursor == "cur-next-1" {
                return (httpResponse(request.url!.absoluteString), Data(pageJSON(ids: [("ses_3", "Three")], next: nil).utf8))
            }
            return (
                httpResponse(request.url!.absoluteString),
                Data(pageJSON(ids: [("ses_1", "One"), ("ses_2", "Two")], next: "cur-next-1").utf8)
            )
        }

        // A caller-supplied `limit` must be overridden so every page asks for
        // the same page size.
        let sessions = try await makeClient().allSessions(query: SessionsQuery(limit: 999, order: .asc), limit: 2)

        XCTAssertEqual(sessions.map(\.id), ["ses_1", "ses_2", "ses_3"])
        XCTAssertEqual(StubOpenCodeURLProtocol.recorded.count, 2)

        let first = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        let second = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.last)
        XCTAssertEqual(queryValue("limit", in: first.url), "2")
        XCTAssertEqual(queryValue("order", in: first.url), "asc")
        XCTAssertNil(queryValue("cursor", in: first.url))
        XCTAssertEqual(queryValue("limit", in: second.url), "2")
        XCTAssertEqual(queryValue("cursor", in: second.url), "cur-next-1")
    }

    func testAllSessionsStopsAtMaxPagesEvenWhenCursorsContinue() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let cursor = components.queryItems?.first { $0.name == "cursor" }?.value
            switch cursor {
            case nil:
                return (httpResponse(request.url!.absoluteString), Data(pageJSON(ids: [("ses_1", "One")], next: "cur-1").utf8))
            case "cur-1":
                return (httpResponse(request.url!.absoluteString), Data(pageJSON(ids: [("ses_2", "Two")], next: "cur-2").utf8))
            default:
                return (httpResponse(request.url!.absoluteString), Data(pageJSON(ids: [("ses_3", "Three")], next: "cur-3").utf8))
            }
        }

        let sessions = try await makeClient().allSessions(query: SessionsQuery(), limit: 1, maxPages: 2)

        XCTAssertEqual(StubOpenCodeURLProtocol.recorded.count, 2)
        XCTAssertEqual(sessions.map(\.id), ["ses_1", "ses_2"])
        XCTAssertNotEqual(queryValue("cursor", in: StubOpenCodeURLProtocol.recorded.last?.url), "cur-2")
    }

    func testAllSessionsDeduplicatesRepeatedIDsAcrossPages() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let cursor = components.queryItems?.first { $0.name == "cursor" }?.value
            if cursor == "cur-dup" {
                return (
                    httpResponse(request.url!.absoluteString),
                    Data(pageJSON(ids: [("ses_2", "Two"), ("ses_3", "Three")], next: nil).utf8)
                )
            }
            return (
                httpResponse(request.url!.absoluteString),
                Data(pageJSON(ids: [("ses_1", "One"), ("ses_2", "Two")], next: "cur-dup").utf8)
            )
        }

        let sessions = try await makeClient().allSessions(query: SessionsQuery(), limit: 2)

        XCTAssertEqual(sessions.map(\.id), ["ses_1", "ses_2", "ses_3"])
    }

    // MARK: - FSEntry decoding

    func testFSEntryDecodesKindFromTypeKeyAndPreservesTrailingSlash() throws {
        let decoder = JSONDecoder()

        let file = try decoder.decode(FSEntry.self, from: Data("{\"path\":\"AGENTS.md\",\"type\":\"file\"}".utf8))
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.path, "AGENTS.md")

        let directory = try decoder.decode(
            FSEntry.self,
            from: Data("{\"path\":\"AidenForOpenCode/Networking/\",\"type\":\"directory\"}".utf8)
        )
        XCTAssertEqual(directory.kind, .directory)
        XCTAssertEqual(directory.path, "AidenForOpenCode/Networking/")
    }

    func testFSEntryEncodesTypeKeyAndFailsClosedOnUnknownKind() throws {
        // Keyed-container key ORDER is unspecified in JSONEncoder — assert
        // via a re-decoded dictionary rather than raw string equality.
        let encoded = try JSONEncoder().encode(FSEntry(path: "src/", kind: .directory))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: String]
        )
        XCTAssertEqual(object["path"], "src/")
        XCTAssertEqual(object["type"], "directory")

        XCTAssertThrowsError(try JSONDecoder().decode(FSEntry.self, from: Data("{\"path\":\"link\",\"type\":\"symlink\"}".utf8)))
    }

    // MARK: - listDirectory

    func testListDirectoryDecodesLocationEnvelopeAndSendsQuery() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "{\"location\":{\"directory\":\"/tmp/demo\",\"workspaceID\":\"ws_1\"," +
                "\"project\":{\"id\":\"proj_1\",\"directory\":\"/tmp/demo\"}}," +
                "\"data\":[{\"path\":\"AidenForOpenCode/\",\"type\":\"directory\"},{\"path\":\"AGENTS.md\",\"type\":\"file\"}]}"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }

        let listing = try await makeClient().listDirectory(path: "docs", scope: LocationScope(directory: "/tmp/demo"))

        XCTAssertEqual(listing.location.directory, "/tmp/demo")
        XCTAssertEqual(listing.location.project.id, "proj_1")
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.entries[0], FSEntry(path: "AidenForOpenCode/", kind: .directory))
        XCTAssertEqual(listing.entries[1], FSEntry(path: "AGENTS.md", kind: .file))

        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        XCTAssertEqual(queryValue("path", in: request.url), "docs")
        XCTAssertEqual(queryValue("location[directory]", in: request.url), "/tmp/demo")
    }

    // MARK: - findEntries

    func testFindEntriesDecodesLocationEnvelopeAndKeepsRankOrder() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "{\"location\":{\"directory\":\"/tmp/demo\"," +
                "\"project\":{\"id\":\"proj_1\",\"directory\":\"/tmp/demo\"}}," +
                "\"data\":[{\"path\":\"network.swift\",\"type\":\"file\"}," +
                "{\"path\":\"net.md\",\"type\":\"file\"},{\"path\":\"subnet/\",\"type\":\"directory\"}]}"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }

        let entries = try await makeClient().findEntries(
            query: "net",
            type: .file,
            limit: 5,
            scope: LocationScope(directory: "/tmp/demo")
        )

        XCTAssertEqual(entries.map(\.path), ["network.swift", "net.md", "subnet/"])

        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        XCTAssertEqual(queryValue("query", in: request.url), "net")
        XCTAssertEqual(queryValue("type", in: request.url), "file")
        XCTAssertEqual(queryValue("limit", in: request.url), "5")
        XCTAssertEqual(queryValue("location[directory]", in: request.url), "/tmp/demo")
    }

    func testFindEntriesFallsBackToBareArrayWhenEnvelopeIsMissing() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "[{\"path\":\"z/\",\"type\":\"directory\"},{\"path\":\"z.txt\",\"type\":\"file\"}]"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }

        let entries = try await makeClient().findEntries(query: "z", type: nil, limit: nil, scope: nil)

        XCTAssertEqual(
            entries,
            [FSEntry(path: "z/", kind: .directory), FSEntry(path: "z.txt", kind: .file)]
        )
        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        XCTAssertNil(queryValue("type", in: request.url))
        XCTAssertNil(queryValue("limit", in: request.url))
    }

    // MARK: - readFile URL construction

    func testReadFileBuildsPercentEncodedWildcardWithScopeDeepObject() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            (
                httpResponse(request.url!.absoluteString, headers: ["Content-Type": "text/plain; charset=utf-8"]),
                Data("# hello".utf8)
            )
        }

        let file = try await makeClient().readFile(
            path: "a b/c%2Fd.txt",
            scope: LocationScope(directory: "/tmp/demo", workspace: "ws_1")
        )

        XCTAssertEqual(file.data, Data("# hello".utf8))
        XCTAssertEqual(file.mime, "text/plain")

        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        // Each segment is encoded individually: spaces escape inside their own
        // segment, pre-encoded input re-escapes, and `/` stays a separator.
        XCTAssertEqual(components.percentEncodedPath, "/api/fs/read/a%20b/c%252Fd.txt")
        XCTAssertEqual(queryValue("location[directory]", in: request.url), "/tmp/demo")
        XCTAssertEqual(queryValue("location[workspace]", in: request.url), "ws_1")
    }

    func testReadFileReturnsNilMimeWithoutContentTypeHeader() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            (httpResponse(request.url!.absoluteString), Data([0x00, 0x01]))
        }

        let file = try await makeClient().readFile(path: "bin/blob", scope: nil)

        XCTAssertEqual(file.data, Data([0x00, 0x01]))
        XCTAssertNil(file.mime)

        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/fs/read/bin/blob")
        XCTAssertNil(components.query)
    }

    // MARK: - Session / message / prompt wire decode

    func testSessionInfoDecodesFractionalTimestampsAndIgnoresOutcome() throws {
        let json = """
        {"id":"ses_1","projectID":"proj_1","cost":0.5,\
        "tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}},\
        "time":{"created":1787617578491.5,"updated":1787617578492},"title":"Demo",\
        "location":{"directory":"/tmp/demo"},"outcome":{"kind":"success"}}
        """
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.id, "ses_1")
        XCTAssertEqual(info.time.created, 1_787_617_578_491.5, accuracy: 0.01)
        XCTAssertEqual(info.location.directory, "/tmp/demo")
        XCTAssertNil(info.agent)
    }

    func testMessagePageDecodesSchemaToolCompletedAssistant() throws {
        let json = """
        {"data":[{"id":"msg_asst","type":"assistant","agent":"build",\
        "model":{"id":"gpt-5","providerID":"openai"},\
        "time":{"created":1000,"completed":2000},\
        "content":[\
          {"type":"text","id":"txt_1","text":"Working"},\
          {"type":"tool","id":"call_1","name":"bash",\
           "provider":{"executed":true,"metadata":{"openai":{"itemId":"call"}},"resultMetadata":{"openai":{"itemId":"result"}}},\
           "state":{"status":"completed","input":{"command":"ls"},\
            "content":[{"type":"text","text":"ok"},{"type":"image","url":"x"}],\
            "structured":{"exit":0},"outputPaths":["/tmp/out"]},\
           "time":{"created":1001,"ran":1002,"completed":1003}}\
        ]}],"cursor":{"previous":null,"next":null}}
        """
        let page = try JSONDecoder().decode(MessagePage.self, from: Data(json.utf8))
        guard case .assistant(let message) = page.data[0] else {
            return XCTFail("expected assistant message")
        }
        XCTAssertEqual(message.id, "msg_asst")
        XCTAssertEqual(message.content.count, 2)
        guard case .text(let text) = message.content[0] else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text.id, "txt_1")
        guard case .tool(let tool) = message.content[1] else {
            return XCTFail("expected tool")
        }
        XCTAssertEqual(tool.provider?.executed, true)
        XCTAssertEqual(tool.provider?.resultMetadata?["openai"]?["itemId"], .string("result"))
        guard case .completed(_, _, let content, let outputPaths, let structured, _) = tool.state else {
            return XCTFail("expected completed tool")
        }
        XCTAssertEqual(outputPaths, ["/tmp/out"])
        XCTAssertEqual(structured["exit"], .int(0))
        XCTAssertEqual(content[0], .text(text: "ok"))
        guard case .unrecognized(let type) = content[1] else {
            return XCTFail("unknown tool content should fail-open")
        }
        XCTAssertEqual(type, "image")
    }

    func testMessagePageDecodesLiveToolCompletedWithoutPartIds() throws {
        let json = """
        {"data":[{"id":"msg_0364f77ad002fu9V1lLNQJarVq","type":"assistant","agent":"build",\
        "model":{"id":"x-preview-f-free","providerID":"opencode","variant":"max"},\
        "time":{"created":1787617578491,"completed":1787617588447},\
        "content":[\
          {"type":"reasoning","text":"plan","state":{"reasoningField":"reasoning_content"},\
           "time":{"created":1,"completed":2}},\
          {"type":"text","text":"Recompiling"},\
          {"type":"future-block","payload":true},\
          {"type":"tool","id":"call_129ec33df18b42ea8c66f829","name":"shell","executed":false,\
           "state":{"status":"completed","input":{"command":"xcodebuild"},\
            "content":[{"type":"text","text":"BUILD FAILED"}],\
            "metadata":{"status":"completed","exit":0}},\
           "time":{"created":3,"ran":4,"completed":5}}\
        ]}],"cursor":{"previous":null,"next":"cur-next"}}
        """
        let page = try JSONDecoder().decode(MessagePage.self, from: Data(json.utf8))
        guard case .assistant(let message) = page.data[0] else {
            return XCTFail("expected assistant")
        }
        XCTAssertEqual(message.content.count, 4)
        guard case .reasoning(let reasoning) = message.content[0] else {
            return XCTFail("expected reasoning")
        }
        XCTAssertEqual(reasoning.id, "")
        XCTAssertEqual(reasoning.text, "plan")
        guard case .text(let text) = message.content[1] else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text.id, "")
        guard case .unrecognized(let unknownType) = message.content[2] else {
            return XCTFail("unknown assistant content should fail-open")
        }
        XCTAssertEqual(unknownType, "future-block")
        guard case .tool(let tool) = message.content[3],
              case .completed(_, _, let content, _, let structured, _) = tool.state else {
            return XCTFail("expected completed tool")
        }
        XCTAssertEqual(tool.provider?.executed, false)
        XCTAssertEqual(structured["exit"], .int(0))
        XCTAssertEqual(content.first, .text(text: "BUILD FAILED"))
        XCTAssertEqual(page.cursor.next, "cur-next")
    }

    func testCompactionMessageUnknownReasonFailsOpen() throws {
        let json = """
        {"id":"msg_cmp","type":"compaction","reason":"overflow","summary":"trimmed","recent":"keep",\
        "time":{"created":10}}
        """
        let message = try JSONDecoder().decode(OCMessage.self, from: Data(json.utf8))
        guard case .compaction(let payload) = message else {
            return XCTFail("expected compaction")
        }
        XCTAssertEqual(payload.id, "msg_cmp")
        XCTAssertEqual(payload.reason, .unrecognized("overflow"))
    }

    func testAdmittedInputDecodesPromptReceiptWithRequiredMime() throws {
        let json = """
        {"admittedSeq":3,"id":"msg_user1","sessionID":"ses_1",\
        "prompt":{"text":"see this","files":[{"uri":"file:///tmp/a.png","mime":"image/png","name":"a.png"}],\
        "agents":[{"name":"build"}]},"delivery":"steer","timeCreated":1787617578491.25,"promotedSeq":4}
        """
        let admitted = try JSONDecoder().decode(AdmittedInput.self, from: Data(json.utf8))
        XCTAssertEqual(admitted.admittedSeq, 3)
        XCTAssertEqual(admitted.id, "msg_user1")
        XCTAssertEqual(admitted.sessionID, "ses_1")
        XCTAssertEqual(admitted.delivery, .steer)
        XCTAssertEqual(admitted.timeCreated, 1_787_617_578_491.25, accuracy: 0.001)
        XCTAssertEqual(admitted.promotedSeq, 4)
        XCTAssertEqual(admitted.prompt.text, "see this")
        XCTAssertEqual(admitted.prompt.files?.first?.mime, "image/png")
        XCTAssertEqual(admitted.prompt.files?.first?.uri, "file:///tmp/a.png")
    }

    func testAdmittedInputFailsClosedWithoutMessageIdentity() {
        let json = """
        {"admittedSeq":1,"sessionID":"ses_1","prompt":{"text":"hi"},"delivery":"queue","timeCreated":1}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AdmittedInput.self, from: Data(json.utf8)))
    }

    func testContextDecodesDataEnvelope() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "{\"data\":[{\"id\":\"msg_u\",\"type\":\"user\",\"text\":\"hello\",\"time\":{\"created\":1}}]}"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }
        let messages = try await makeClient().context(sessionID: "ses_1")
        guard case .user(let user) = messages.first else {
            return XCTFail("expected user")
        }
        XCTAssertEqual(user.id, "msg_u")
        XCTAssertEqual(user.text, "hello")
    }

    func testContextFallsBackToBareArray() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "[{\"id\":\"msg_s\",\"type\":\"system\",\"text\":\"note\",\"time\":{\"created\":2}}]"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }
        let messages = try await makeClient().context(sessionID: "ses_1")
        guard case .system(let system) = messages.first else {
            return XCTFail("expected system")
        }
        XCTAssertEqual(system.id, "msg_s")
    }

    // MARK: - Client request encoding and HTTP errors

    func testLocationIsUnwrappedAndUsesDeepObjectQuery() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "{\"directory\":\"/tmp/demo\",\"project\":{\"id\":\"proj_1\",\"directory\":\"/tmp/demo\"}}"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }

        let info = try await makeClient().location(scope: LocationScope(directory: "/tmp/demo"))
        XCTAssertEqual(info.directory, "/tmp/demo")
        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        XCTAssertEqual(queryValue("location[directory]", in: request.url), "/tmp/demo")
        XCTAssertNil(queryValue("directory", in: request.url))
    }

    func testAgentsDecodeLocationEnvelope() async throws {
        let location = "{\"directory\":\"/tmp/demo\",\"project\":{\"id\":\"proj_1\",\"directory\":\"/tmp/demo\"}}"
        let agent = "{\"id\":\"build\",\"request\":{\"headers\":{},\"body\":{}},\"mode\":\"primary\",\"hidden\":false,\"permissions\":[]}"
        StubOpenCodeURLProtocol.handler = { request in
            (httpResponse(request.url!.absoluteString), Data("{\"location\":\(location),\"data\":[\(agent)]}".utf8))
        }

        let agents = try await makeClient().agents(scope: LocationScope(directory: "/tmp/demo"))
        XCTAssertEqual(agents.map(\.id), ["build"])
        XCTAssertEqual(queryValue("location[directory]", in: StubOpenCodeURLProtocol.recorded.first?.url), "/tmp/demo")
    }

    func testSessionsDecodePageAndFillMissingTitle() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let row = "{\"id\":\"ses_1\",\"projectID\":\"proj_1\",\"cost\":0," +
                "\"tokens\":{\"input\":0,\"output\":0,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}," +
                "\"time\":{\"created\":1,\"updated\":2},\"location\":{\"directory\":\"/tmp/demo\"}}"
            return (httpResponse(request.url!.absoluteString), Data("{\"data\":[\(row)],\"cursor\":{}}".utf8))
        }

        let page = try await makeClient().sessions(query: SessionsQuery(directory: "/tmp/demo", limit: 10))
        XCTAssertEqual(page.data.first?.id, "ses_1")
        XCTAssertEqual(page.data.first?.title, "")
        let request = try XCTUnwrap(StubOpenCodeURLProtocol.recorded.first)
        XCTAssertEqual(queryValue("directory", in: request.url), "/tmp/demo")
        XCTAssertNil(queryValue("location[directory]", in: request.url))
        XCTAssertEqual(queryValue("limit", in: request.url), "10")
    }

    func testCreateSessionEncodesModelRefObjectAndAbsoluteLocation() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let session = sessionFixture(id: "ses_new", title: "New")
            return (httpResponse(request.url!.absoluteString), Data("{\"data\":\(session)}".utf8))
        }

        let created = try await makeClient().createSession(
            agent: "build",
            model: ModelRef(providerID: "anthropic", modelID: "claude-sonnet-4"),
            directory: "/tmp/demo"
        )
        XCTAssertEqual(created.id, "ses_new")

        let body = try XCTUnwrap(StubOpenCodeURLProtocol.recordedBodies.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["agent"] as? String, "build")
        let model = try XCTUnwrap(object["model"] as? [String: Any])
        XCTAssertEqual(model["id"] as? String, "claude-sonnet-4")
        XCTAssertEqual(model["providerID"] as? String, "anthropic")
        XCTAssertNil(model["variant"])
        let location = try XCTUnwrap(object["location"] as? [String: Any])
        XCTAssertEqual(location["directory"] as? String, "/tmp/demo")
        XCTAssertNil(location["workspaceID"])
    }

    func testPromptEncodesNestedPromptAndMapsInboxReceipt() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "{\"data\":{\"id\":\"msg_1\",\"sessionID\":\"ses_1\",\"timeCreated\":1," +
                "\"type\":\"user\",\"payload\":{\"text\":\"hello\"},\"delivery\":\"steer\"}}"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }

        let admitted = try await makeClient().prompt(sessionID: "ses_1", text: "hello")
        XCTAssertEqual(admitted.id, "msg_1")
        XCTAssertEqual(admitted.prompt.text, "hello")
        XCTAssertEqual(admitted.delivery, .steer)

        let body = try XCTUnwrap(StubOpenCodeURLProtocol.recordedBodies.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["text"])
        let prompt = try XCTUnwrap(object["prompt"] as? [String: Any])
        XCTAssertEqual(prompt["text"] as? String, "hello")
        XCTAssertEqual(object["delivery"] as? String, "steer")
        XCTAssertNil(object["resume"])
    }

    func testParseError400SurfacesServerMessageNotDecoding() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            let body = "{\"_tag\":\"InvalidRequestError\",\"message\":\"Expected Model.Ref | null\\n  at [\\\"model\\\"]\",\"kind\":\"Payload\"}"
            return (httpResponse(request.url!.absoluteString, status: 400), Data(body.utf8))
        }

        do {
            _ = try await makeClient().createSession(model: ModelRef(providerID: "x", modelID: "y"))
            XCTFail("expected server error")
        } catch let error as OpenCodeAPIError {
            guard case .server(let status, let message) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "Expected Model.Ref | null\n  at [\"model\"]")
        }
    }

    func testDecodeFailureIncludesBodySnippet() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            (httpResponse(request.url!.absoluteString), Data("{\"oops\":true}".utf8))
        }

        do {
            _ = try await makeClient().session(id: "ses_1")
            XCTFail("expected decoding error")
        } catch let error as OpenCodeAPIError {
            guard case .decoding(let underlying) = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertTrue(String(describing: underlying).contains("oops"))
        }
    }

    func testHealthAcceptsExtraFields() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            (httpResponse(request.url!.absoluteString), Data("{\"healthy\":true,\"version\":\"1\",\"pid\":9}".utf8))
        }
        try await makeClient().health()
    }

    func testPairingPayloadRejectsWrongKindAndQueryEndpoint() throws {
        XCTAssertThrowsError(
            try OpenCodePairingPayload.decode(Data("{\"kind\":\"other\",\"endpoint\":\"http://127.0.0.1:4096\"}".utf8))
        ) { error in
            guard case PairingError.malformedPayload = error else {
                return XCTFail("expected malformedPayload, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try OpenCodePairingPayload(endpoint: "http://127.0.0.1:4096?auth_token=secret")
        ) { error in
            guard case PairingError.malformedPayload = error else {
                return XCTFail("expected malformedPayload, got \(error)")
            }
        }
    }

    func testPairingVerifySucceedsAfterHealthAndLocation() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/api/health") {
                return (httpResponse(request.url!.absoluteString), Data("{\"healthy\":true}".utf8))
            }
            let body = "{\"directory\":\"/tmp/demo\",\"project\":{\"id\":\"proj_1\",\"directory\":\"/tmp/demo\"}}"
            return (httpResponse(request.url!.absoluteString), Data(body.utf8))
        }

        let config = try OpenCodeServerConfig(baseURL: URL(string: "http://localhost:4096")!, password: "secret")
        let verified = try await PairingVerifier.verify(config: config, client: makeClient(), name: "Lan")
        XCTAssertEqual(verified.name, "Lan")
        XCTAssertEqual(verified.directory, "/tmp/demo")
        XCTAssertEqual(StubOpenCodeURLProtocol.recorded.count, 2)
        XCTAssertTrue(StubOpenCodeURLProtocol.recorded[0].url!.path.hasSuffix("/api/health"))
        XCTAssertTrue(StubOpenCodeURLProtocol.recorded[1].url!.path.hasSuffix("/api/location"))
        let authorization = try XCTUnwrap(StubOpenCodeURLProtocol.recorded[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("Basic "))
        XCTAssertFalse(StubOpenCodeURLProtocol.recorded[0].url!.absoluteString.contains("secret"))
    }

    func testPairingVerifyMaps401() async throws {
        StubOpenCodeURLProtocol.handler = { request in
            (
                httpResponse(request.url!.absoluteString, status: 401),
                Data("{\"_tag\":\"UnauthorizedError\",\"message\":\"Authentication required\"}".utf8)
            )
        }
        let config = try OpenCodeServerConfig(baseURL: URL(string: "http://localhost:4096")!)
        do {
            _ = try await PairingVerifier.verify(config: config, client: makeClient())
            XCTFail("expected unauthorized")
        } catch let error as PairingError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
}
