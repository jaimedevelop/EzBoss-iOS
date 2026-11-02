import SwiftUI
import Auth0
import Security

// Explicit device-only, unlocked Keychain policy for Auth0's credential store.
// Updating existing entries before reading also migrates SDK-default entries.
private struct DeviceCredentialStorage: CredentialsStorage {
    let service: String
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }
    func getEntry(forKey key: String) -> Data? {
        let q = query(key)
        guard SecItemUpdate(q as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary) == errSecSuccess else { return nil }
        var read = q
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    func setEntry(_ data: Data, forKey key: String) -> Bool {
        let q = query(key)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(q.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    func deleteEntry(forKey key: String) -> Bool {
        let status = SecItemDelete(query(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

@MainActor
private final class Auth0CredentialStore: SessionCredentialStore {
    let config: NativeConfiguration
    let manager: CredentialsManager

    init(config: NativeConfiguration) {
        self.config = config
        manager = CredentialsManager(authentication: Auth0.authentication(clientId: config.clientID, domain: config.domain), storage: DeviceCredentialStorage(service: config.bundleID))
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
                    BusinessHome(session: session, identity: identity).id(identity.id).disabled(session.busy)
                default:
                    SignInView(session: session)
                }
            }
            .privacySensitive()
            .overlay {
                if scenePhase != .active {
                    Color.white.overlay(Text("EzBoss").font(.title.bold()))
                        .ignoresSafeArea()
                }
            }
            .tint(WorkspaceDesign.primary)
            .preferredColorScheme(.light)
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
                    Image(systemName: "hammer.fill").font(.system(size: 40)).foregroundStyle(WorkspaceDesign.primary).accessibilityHidden(true)
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
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .top) { UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16).fill(WorkspaceDesign.primary).frame(height: 6) }
                .padding(16)
                .frame(maxWidth: .infinity)
                .disabled(session.busy || session.configuration == nil)
            }
            .background(Color(red: 245/255, green: 245/255, blue: 241/255))
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
