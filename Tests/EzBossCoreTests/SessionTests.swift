import XCTest
import Security
@testable import EzBossCore

@MainActor
private final class CredentialStore: SessionCredentialStore {
    var hasSession = true
    var clearSucceeds = true
    var failure: Error?
    var loginCalls = 0
    var tokenCalls = 0
    var logoutCalls = 0
    var clears = 0
    var onLogin: (() async -> Void)?
    var onLogout: (() -> Void)?
    func login() async throws {
        loginCalls += 1
        await onLogin?()
        if let failure { throw failure }
        hasSession = true
    }
    func accessToken() async throws -> String {
        tokenCalls += 1
        if let failure { throw failure }
        return "synthetic-access-token"
    }
    func clear() -> Bool {
        clears += 1
        if clearSucceeds { hasSession = false }
        return clearSucceeds
    }
    func logout() async throws {
        logoutCalls += 1
        onLogout?()
        if let failure { throw failure }
    }
}

@MainActor
final class SessionTests: XCTestCase {
    private func session(_ store: CredentialStore, status: Int = 200) throws -> Session {
        StubProtocol.status = status
        StubProtocol.body = #"{"id":42,"displayName":"Employee","roleName":"Employee","status":"active"}"#
        StubProtocol.request = nil
        let config = try NativeConfiguration(values: ["Auth0Domain": "test.auth0.com", "Auth0ClientId": "native-client",
            "Auth0Audience": "https://api.example", "APIBaseURL": "https://api.example"], bundleID: "pro.ezboss.mobile")
        return Session(configuration: config, manager: store,
                       api: APIClient(baseURL: config.api, protocolClasses: [StubProtocol.self]))
    }

    func testLoginClearsOldCredentialsAndLoadsAPIIdentity() async throws {
        let store = CredentialStore()
        let app = try session(store)
        await app.signIn()
        XCTAssertEqual(store.clears, 1)
        XCTAssertEqual(store.loginCalls, 1)
        XCTAssertEqual(store.tokenCalls, 1)
        guard case .authenticated(let identity) = app.state else { return XCTFail("Expected API identity") }
        XCTAssertEqual(identity.id, 42)
        XCTAssertEqual(identity.roleName, "Employee")
        XCTAssertFalse(app.busy)
    }

    func testRestorationUsesRenewingStoreWithoutBrowserLogin() async throws {
        let store = CredentialStore()
        let app = try session(store)
        await app.restore()
        XCTAssertEqual(store.loginCalls, 0)
        XCTAssertEqual(store.tokenCalls, 1)
        guard case .authenticated = app.state else { return XCTFail("Expected restored identity") }
    }

    func testAbsentSessionNeverCallsAPI() async throws {
        let store = CredentialStore(); store.hasSession = false
        let app = try session(store)
        await app.restore()
        XCTAssertEqual(app.state, .signedOut)
        XCTAssertEqual(store.tokenCalls, 0)
        XCTAssertNil(StubProtocol.request)
    }

    func testRenewalFailureClearsSessionAndRedactsProviderError() async throws {
        let store = CredentialStore(); store.failure = NSError(domain: "private-token-value", code: 1)
        let app = try session(store)
        await app.restore()
        guard case .failed(let message, let requiresSignIn) = app.state else { return XCTFail("Expected failure") }
        XCTAssertTrue(requiresSignIn)
        XCTAssertFalse(message.contains("private-token-value"))
        XCTAssertFalse(store.hasSession)
        XCTAssertNil(StubProtocol.request)
    }

    func testRejectedIdentityClearsCredentialsWhileServiceFailureAllowsRetry() async throws {
        for status in [401, 403, 404, 503] {
            let store = CredentialStore()
            let app = try session(store, status: status)
            await app.restore()
            guard case .failed(_, let requiresSignIn) = app.state else { return XCTFail("Expected denied identity") }
            XCTAssertEqual(requiresSignIn, status == 401 || status == 403)
            XCTAssertEqual(store.hasSession, status == 404 || status == 503)
            if status == 503 {
                StubProtocol.status = 200
                await app.restore()
                guard case .authenticated = app.state else { return XCTFail("Expected retry recovery") }
            }
        }
    }

    func testLogoutRemovesIdentityBeforeBrowserAndSurvivesBrowserFailure() async throws {
        let store = CredentialStore()
        let app = try session(store)
        await app.restore()
        store.failure = NSError(domain: "browser cancelled", code: 1)
        store.onLogout = {
            XCTAssertEqual(app.state, .signedOut)
            XCTAssertFalse(store.hasSession)
        }
        await app.signOut()
        XCTAssertEqual(app.state, .signedOut)
        XCTAssertNotNil(app.notice)
        let calls = store.tokenCalls
        await app.restore()
        XCTAssertEqual(store.tokenCalls, calls)
    }

    func testStorageRemovalFailureBlocksAccountSwitchAndForegroundRestoration() async throws {
        let store = CredentialStore(); store.clearSucceeds = false
        let app = try session(store)
        await app.signIn()
        XCTAssertEqual(store.loginCalls, 0)
        await app.signOut()
        await app.restore()
        XCTAssertEqual(app.state, .signedOut)
        XCTAssertEqual(store.tokenCalls, 0)
    }

    func testOverlappingActionsDoNotStartAnotherLoginOrRestore() async throws {
        let store = CredentialStore()
        let app = try session(store)
        store.onLogin = {
            await app.signIn()
            await app.restore()
            XCTAssertTrue(app.busy)
        }
        await app.signIn()
        XCTAssertEqual(store.loginCalls, 1)
        XCTAssertEqual(store.tokenCalls, 1)
    }
    func testCancelledLoginClearsSessionAndNeverLoadsIdentity() async throws {
        let store = CredentialStore()
        let app = try session(store)
        store.onLogin = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { await app.signIn() }
        await task.value
        guard case .failed(_, let requiresSignIn) = app.state else { return XCTFail("Expected cancelled sign-in") }
        XCTAssertTrue(requiresSignIn)
        XCTAssertFalse(store.hasSession)
        XCTAssertEqual(store.tokenCalls, 0)
        XCTAssertNil(StubProtocol.request)
    }

    func testFreshInstallCanSignInWithNoPreviousSession() async throws {
        let store = CredentialStore()
        store.hasSession = false
        let app = try session(store)
        await app.restore()
        XCTAssertEqual(app.state, .signedOut)
        await app.signIn()
        XCTAssertEqual(store.loginCalls, 1)
        guard case .authenticated = app.state else { return XCTFail("Expected first login") }
    }

    func testDeletingAbsentCredentialIsSuccessful() {
        XCTAssertTrue(clearStoredCredential(delete: { false }, lookupStatus: { errSecItemNotFound }))
    }

    func testActualKeychainFailureNeverCountsAsRemoval() {
        for status in [errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed,
                       errSecMissingEntitlement, errSecNotAvailable, errSecDecode] {
            XCTAssertFalse(clearStoredCredential(delete: { false }, lookupStatus: { status }))
        }
    }

    func testSuccessfulDeletionDoesNotRequireAnotherKeychainLookup() {
        XCTAssertTrue(clearStoredCredential(delete: { true }, lookupStatus: {
            XCTFail("Successful removal needs no lookup")
            return errSecNotAvailable
        }))
    }

}
