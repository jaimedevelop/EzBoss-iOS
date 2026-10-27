import XCTest
@testable import EzBossCore

final class StubProtocol: URLProtocol {
    static var status = 200
    static var body = ""
    static var request: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private func client(status: Int, body: String = "private provider error") -> APIClient {
        StubProtocol.status = status; StubProtocol.body = body; StubProtocol.request = nil
        return APIClient(baseURL: URL(string: "https://staging.example/api/")!, protocolClasses: [StubProtocol.self])
    }

    func testAccountRequestPreservesAPIPrefixAndUsesBearer() async throws {
        let api = client(status: 200, body: #"{"id":42,"displayName":"Owner","roleName":"Owner","status":"active"}"#)
        let identity = try await api.currentUser(accessToken: "test-access-token")
        XCTAssertEqual(identity.id, 42)
        XCTAssertEqual(StubProtocol.request?.url?.absoluteString, "https://staging.example/api/users/me")
        XCTAssertEqual(StubProtocol.request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertNil(StubProtocol.request?.url?.query)
    }

    func testDeniedMissingAndUnavailableResponsesRemainDistinct() async {
        for (status, expected) in [(401, APIError.expiredSession), (403, .accessDenied), (404, .missingAccount), (503, .unavailable), (302, .invalidResponse)] {
            do {
                _ = try await client(status: status).currentUser(accessToken: "test-access-token")
                XCTFail("Expected status \(status) to deny identity")
            } catch {
                XCTAssertEqual(error as? APIError, expected)
                XCTAssertFalse(expected.message.contains("private provider error"))
            }
        }
    }

    func testInactiveAndMalformedIdentityNeverBecomeAuthenticated() async {
        for (body, expected) in [(#"{"id":42,"status":"suspended"}"#, APIError.inactiveAccount), (#"{"id":42}"#, .invalidResponse), (#"{"id":0,"status":"active"}"#, .invalidResponse), (#"{"id":"not-an-integer","status":"active"}"#, .invalidResponse)] {
            do {
                _ = try await client(status: 200, body: body).currentUser(accessToken: "test-access-token")
                XCTFail("Expected identity rejection")
            } catch { XCTAssertEqual(error as? APIError, expected) }
        }
    }

    func testEmptyTokenNeverStartsRequest() async {
        let api = client(status: 200)
        do { _ = try await api.currentUser(accessToken: ""); XCTFail("Expected missing token failure") }
        catch { XCTAssertEqual(error as? APIError, .expiredSession) }
        XCTAssertNil(StubProtocol.request)
    }

    func testRedirectDelegateRefusesCrossOriginDestination() {
        let delegate = NoRedirects()
        let transport = URLSession(configuration: .ephemeral)
        defer { transport.invalidateAndCancel() }
        let task = transport.dataTask(with: URL(string: "https://staging.example/users/me")!)
        let response = HTTPURLResponse(url: URL(string: "https://staging.example/users/me")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var called = false
        delegate.urlSession(transport, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://other.example")!)) {
            XCTAssertNil($0); called = true
        }
        XCTAssertTrue(called)
    }
}
