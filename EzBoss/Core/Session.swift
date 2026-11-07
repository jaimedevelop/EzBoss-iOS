import Foundation
import Combine
import Security

// Implementations own secure persistence and refresh-token rotation; the state machine
// only receives access tokens long enough to load the API identity.
@MainActor
protocol SessionCredentialStore {
    var hasSession: Bool { get }
    func login() async throws
    func login(createAccount: Bool) async throws
    func accessToken() async throws -> String
    @discardableResult func clear() -> Bool
}

enum SessionState: Equatable {
    case unconfigured, signedOut, connecting, pendingAccount
    case authenticated(Identity)
    case failed(String, requiresSignIn: Bool)
}

@MainActor
final class Session: ObservableObject {
    @Published private(set) var state: SessionState = .signedOut
    @Published private(set) var authenticationUnavailable = false
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    let configuration: NativeConfiguration?
    private let manager: SessionCredentialStore?
    private let api: APIClient?
    private var locallySignedOut = false

    init(configuration: NativeConfiguration?, manager: SessionCredentialStore?, api: APIClient?) {
        self.configuration = configuration
        self.manager = manager
        self.api = api
        if configuration == nil || manager == nil || api == nil { state = .unconfigured }
    }

    func signIn(createAccount: Bool = false) async {
        guard !busy, configuration != nil, let manager else { return }
        busy = true
        resourceGeneration = UUID()
        state = .connecting
        notice = nil
        defer { busy = false }
        // Do not allow retry to restore a previous account after a cancelled account switch.
        guard manager.clear() else {
            state = .failed("The previous session could not be removed securely. Retry sign-out.", requiresSignIn: true)
            return
        }
        do {
            locallySignedOut = false
            try await manager.login(createAccount: createAccount)
            try Task.checkCancellation()
            await loadIdentity()
        } catch {
            _ = manager.clear()
            // Provider errors may contain private values. Never display or log raw payloads.
            state = .failed("Sign-in was cancelled or could not finish. Please try again.", requiresSignIn: true)
        }
    }

    var nativeCredentials: BetterAuthCredentialStore? { manager as? BetterAuthCredentialStore }
    func nativeSignIn(email: String, password: String, code: String? = nil, backup: Bool = false) async throws -> Bool {
        guard !busy, let native = nativeCredentials else { throw NativeAuthFailure.incomplete }
        busy = true; resourceGeneration = UUID(); notice = nil
        defer { busy = false }
        let complete: Bool
        if let code { complete = try await native.verify(code:code,backup:backup) }
        else { locallySignedOut = false; complete = try await native.signIn(email:email,password:password) }
        if complete { await loadIdentity() }
        return complete
    }

    func createNativeCompany(_ fields:[String:Any]) async throws {
        guard !busy, case .pendingAccount = state, let manager, let api else { throw APIError.unavailable }
        busy=true; resourceGeneration=UUID(); defer { busy=false }
        let token=try await manager.accessToken()
        let (_,status)=try await api.resource("onboarding/contractor",token:token,method:"POST",body:JSONSerialization.data(withJSONObject:fields))
        guard (200..<300).contains(status) else { throw status>=500 ? APIError.unavailable : APIError.actionFailed }
        await loadIdentity()
    }

    func restore() async {
        guard !busy, !locallySignedOut, let manager else { return }
        guard manager.hasSession else {
            _ = manager.clear()
            authenticationUnavailable = false
            state = .signedOut
            return
        }
        busy = true
        resourceGeneration = UUID()
        if case .authenticated = state { /* Keep drafts and camera state during validation. */ }
        else { state = .connecting }
        defer { busy = false }
        await loadIdentity()
    }

    private func loadIdentity() async {
        let canPreserveIdentity:Bool
        if case .authenticated = state { canPreserveIdentity = nativeCredentials != nil } else { canPreserveIdentity = false }
        guard let manager, let api else { return }
        let accessToken: String
        do {
            // This one shared manager serializes renewal and stores rotated refresh tokens.
            accessToken = try await manager.accessToken()
        } catch NativeAuthFailure.unavailable {
            if canPreserveIdentity { authenticationUnavailable = true; return }
            state = .failed("Authentication is temporarily unavailable. Retry without signing out.", requiresSignIn: false)
            return
        } catch {
            _ = manager.clear()
            authenticationUnavailable = false
            state = .failed("Your session could not be restored. Please sign in again.", requiresSignIn: true)
            return
        }
        do {
            let identity = try await api.currentUser(accessToken: accessToken)
            try Task.checkCancellation()
            authenticationUnavailable = false
            state = .authenticated(identity)
        } catch let error as APIError {
            if error == .unavailable && canPreserveIdentity { authenticationUnavailable = true; return }
            authenticationUnavailable = false
            if error == .missingAccount && nativeCredentials != nil { state = .pendingAccount; return }
            if error.requiresSignIn { _ = manager.clear() }
            state = .failed(error.message, requiresSignIn: error.requiresSignIn)
        } catch {
            if canPreserveIdentity { authenticationUnavailable = true; return }
            state = .failed("Your account could not be loaded. Check your connection and retry.", requiresSignIn: false)
        }
    }

    // Results belong to the authenticated generation that started them. Revalidation,
    // logout and account switching cannot deliver an old response into a new shell.
    private var resourceGeneration = UUID()
    func business<T>(_ operation: (APIClient, String) async throws -> T) async throws -> T {
        guard case .authenticated = state, let manager, let api else { throw APIError.expiredSession }
        guard !busy && !authenticationUnavailable else { throw APIError.unavailable }
        let generation = resourceGeneration
        do {
            let token: String
            do { token = try await manager.accessToken() }
            catch is CancellationError { throw CancellationError() }
            catch NativeAuthFailure.unavailable {
                guard generation == resourceGeneration else { throw CancellationError() }
                authenticationUnavailable = true; throw APIError.unavailable
            }
            catch {
                guard generation == resourceGeneration else { throw CancellationError() }
                _ = manager.clear()
                resourceGeneration = UUID()
                state = .failed("Your session could not be restored. Please sign in again.", requiresSignIn: true)
                throw APIError.expiredSession
            }
            guard generation == resourceGeneration, case .authenticated = state else { throw CancellationError() }
            let result = try await operation(api, token)
            try Task.checkCancellation()
            guard generation == resourceGeneration, case .authenticated = state else { throw CancellationError() }
            return result
        } catch {
            guard generation == resourceGeneration else { throw CancellationError() }
            if error as? APIError == .expiredSession {
                _ = manager.clear()
                resourceGeneration = UUID()
                state = .failed(APIError.expiredSession.message, requiresSignIn: true)
            }
            throw error
        }
    }

    func signOut() async {
        guard !busy, configuration != nil, let manager else { return }
        busy = true
        resourceGeneration = UUID()
        locallySignedOut = true
        authenticationUnavailable = false
        state = .signedOut
        notice = nil
        let cleared: Bool
        if let native = manager as? BetterAuthCredentialStore { cleared = await native.revoke() }
        else { cleared = manager.clear() }
        defer { busy = false }
        notice = cleared ? "Signed out." : "Local session removal failed. Retry sign-out before leaving this device."
    }
}


// SDK deletion returns false for both an absent item and an actual Keychain error.
// Only a precise item-not-found lookup makes the former safe to treat as cleared.
func clearStoredCredential(delete: () -> Bool, lookupStatus: () -> OSStatus) -> Bool {
    if delete() { return true }
    return lookupStatus() == errSecItemNotFound
}
