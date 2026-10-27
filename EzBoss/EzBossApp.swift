import SwiftUI
import Auth0
import Security

@MainActor
private final class Auth0CredentialStore: SessionCredentialStore {
    let config: NativeConfiguration
    let manager: CredentialsManager

    init(config: NativeConfiguration) {
        self.config = config
        manager = CredentialsManager(authentication: Auth0.authentication(clientId: config.clientID, domain: config.domain))
    }

    var hasSession: Bool { manager.hasValid() || manager.canRenew() }
    func accessToken() async throws -> String { try await manager.credentials(minTTL: 30).accessToken }
    func clear() -> Bool {
        clearStoredCredential(delete: { manager.clear() }, lookupStatus: {
            // Match the SDK's default service/account without reading credential bytes.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: config.bundleID,
                kSecAttrAccount as String: "credentials",
                kSecAttrSynchronizable as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            return SecItemCopyMatching(query as CFDictionary, nil)
        })
    }
    func login() async throws {
        let credentials = try await Auth0.webAuth(clientId: config.clientID, domain: config.domain)
            .redirectURL(config.callbackURL)
            .scope("openid profile email offline_access")
            .audience(config.audience)
            .start()
        guard manager.store(credentials: credentials) else {
            _ = clear()
            throw SecureStorageError.saveFailed
        }
    }
    func logout() async throws {
        try await Auth0.webAuth(clientId: config.clientID, domain: config.domain)
            .redirectURL(config.callbackURL).clearSession()
    }
    private enum SecureStorageError: Error { case saveFailed }
}

extension Session {
    convenience init() {
        let config = try? NativeConfiguration(values: Bundle.main.infoDictionary ?? [:],
                                              bundleID: Bundle.main.bundleIdentifier ?? "")
        self.init(configuration: config, manager: config.map { Auth0CredentialStore(config: $0) },
                  api: config.map { APIClient(baseURL: $0.api) })
    }
}

@main
struct EzBossApp: App {
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch session.state {
                case .authenticated(let identity):
                    AuthenticatedShell(session: session, identity: identity).id(identity.id)
                default:
                    SignInView(session: session)
                }
            }
            .tint(.orange)
            .task { await session.restore() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await session.restore() } }
            }
        }
    }
}

private struct SignInView: View {
    @ObservedObject var session: Session

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "hammer.fill").font(.system(size: 40)).foregroundStyle(.orange).accessibilityHidden(true)
                    Text("Welcome to EzBoss").font(.largeTitle.bold())
                    Text(message)
                    if let notice = session.notice { Text(notice).foregroundStyle(.secondary) }
                    if session.busy { ProgressView("Connecting…") }
                    if case .failed(_, let requiresSignIn) = session.state, !requiresSignIn {
                        Button("Retry account access") { Task { await session.restore() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Sign in") { Task { await session.signIn() } }
                        .buttonStyle(.borderedProminent)
                    if session.configuration != nil {
                        Button("Sign out") { Task { await session.signOut() } }
                    }
                }
                .padding(28)
                .disabled(session.busy || session.configuration == nil)
            }
            .navigationTitle("EzBoss")
        }
    }

    private var message: String {
        switch session.state {
        case .unconfigured:
            return "Sign-in setup is pending. Configure the Apple app identity, Auth0 Native application and staging API before signing in."
        case .failed(let message, _): return message
        case .connecting: return "Connecting to your account…"
        default: return "Sign in to access your EzBoss account."
        }
    }
}

private enum AccountRoute: Hashable { case account }

private struct AuthenticatedShell: View {
    @ObservedObject var session: Session
    let identity: Identity

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Welcome, \(identity.displayName ?? "User")").font(.title2.bold())
                    Text("Your EzBoss account is connected.")
                }
                Section("Account") {
                    NavigationLink("Account access", value: AccountRoute.account)
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: AccountRoute.self) { _ in
                Form {
                    Section("Signed-in account") {
                        LabeledContent("Name", value: identity.displayName ?? "Not provided")
                        LabeledContent("Role", value: identity.roleName ?? "Not assigned")
                        LabeledContent("Status", value: identity.status)
                    }
                    Section {
                        Button("Refresh account access") { Task { await session.restore() } }
                        Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                    }
                }
                .navigationTitle("Account access")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await session.signOut() } }
                }
            }
        }
    }
}
