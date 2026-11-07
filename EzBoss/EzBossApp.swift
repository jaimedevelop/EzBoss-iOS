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
    func login() async throws { try await login(createAccount: false) }
    func login(createAccount: Bool) async throws {
        var webAuth = Auth0.webAuth(clientId: config.clientID, domain: config.domain)
            .redirectURL(config.callbackURL)
            .scope("openid profile email offline_access")
            .audience(config.audience)
            .parameters(createAccount ? ["screen_hint": "signup", "prompt": "login"] : ["prompt": "login"])
        // Registration must start fresh rather than reuse Safari's Auth0 or
        // social-provider session. Leave connections unrestricted so the
        // hosted signup page offers email and enabled providers like Google.
        if createAccount { webAuth = webAuth.useEphemeralSession() }
        let credentials = try await webAuth.start()
        guard manager.store(credentials: credentials) else {
            _ = clear()
            throw SecureStorageError.saveFailed
        }
    }
    private enum SecureStorageError: Error { case saveFailed }
}

extension Session {
    convenience init() {
        let config = try? NativeConfiguration(values: Bundle.main.infoDictionary ?? [:],
                                              bundleID: Bundle.main.bundleIdentifier ?? "")
        self.init(configuration: config, manager: config.map { config -> SessionCredentialStore in
                      if config.authProvider == "better-auth", let origin = config.authOrigin { return BetterAuthCredentialStore(origin:origin,bundleID:config.bundleID) }
                      return Auth0CredentialStore(config:config)
                  },
                  api: config.map { APIClient(baseURL: $0.api,identityDiscovery:$0.authProvider == "better-auth") })
    }
}

@main
struct EzBossApp: App {
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

    private var startupReady: Bool {
        if case .authenticated = session.state { return true }
        return false
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch session.state {
                case .connecting:
                    Color.white.ignoresSafeArea().overlay {
                        EzBossAnimatedMark(reveal: false).frame(width: 230, height: 230*221/741)
                    }
                case .pendingAccount:
                    NativeCompanySetupView(session:session)
                case .authenticated(let identity):
                    BusinessHome(session: session, identity: identity).id(identity.id).disabled(session.busy || session.authenticationUnavailable)
                default:
                    if session.configuration?.authProvider == "better-auth" { NativeIdentityView(session:session) }
                    else { SignInView(session: session) }
                }
            }
            .progressViewStyle(EzBossProgressStyle())
            .modifier(EzBossLoadingTransition(ready: startupReady))
            .privacySensitive()
            .overlay {
                if session.authenticationUnavailable {
                    Color.black.opacity(0.35).ignoresSafeArea().overlay {
                        VStack(spacing:16) {
                            Text("Authentication is temporarily unavailable").font(.headline)
                            Text("Your session and open work are kept. Retry before continuing.")
                            Button("Retry account access") { Task { await session.restore() } }.disabled(session.busy)
                            Button("Sign out") { Task { await session.signOut() } }.disabled(session.busy)
                        }.padding(24).background(.background).clipShape(RoundedRectangle(cornerRadius:8)).padding(24)
                    }
                }
            }
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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image("EzBossLogo", bundle: .main)
                        .resizable().scaledToFit().frame(width: 186, height: 56)
                        .accessibilityLabel("EzBoss")
                        .padding(.top, 16)
                    Spacer().frame(height: 32)
                    VStack(alignment: .leading, spacing: 20) {
                        Text("BUILT FOR THE WAY CONTRACTORS WORK")
                            .font(.system(.caption, design: .default, weight: .bold)).tracking(1.4)
                            .foregroundStyle(Color(red: 32/255, green: 35/255, blue: 33/255))
                        Text("Welcome to EzBoss")
                            .font(.system(.title3, design: .default, weight: .semibold))
                            .foregroundStyle(Color(red: 99/255, green: 104/255, blue: 97/255))
                            .accessibilityAddTraits(.isHeader)
                        (Text("Less tedious estimates.\n").foregroundColor(Color(red: 32/255, green: 35/255, blue: 33/255)) + Text("More building.").foregroundColor(Color(red: 237/255, green: 89/255, blue: 9/255)))
                            .font(.system(.largeTitle, design: .default, weight: .heavy)).tracking(-1.4)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("Put your imported data to work. Turn the materials and labor you already have into reusable collections—and your next estimate into a much shorter to-do.")
                            .font(.body).lineSpacing(5)
                            .foregroundStyle(Color(red: 99/255, green: 104/255, blue: 97/255))
                        if case .unconfigured = session.state { Text(message).foregroundStyle(.secondary) }
                        if case .failed = session.state { Text(message).foregroundStyle(.red) }
                        if let notice = session.notice { Text(notice).foregroundStyle(.secondary) }
                        if session.busy {
                            HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
                        }
                        VStack(spacing: 12) {
                            if case .failed(_, let requiresSignIn) = session.state, !requiresSignIn {
                                Button("Retry account access") { Task { await session.restore() } }
                                    .buttonStyle(.bordered).frame(minHeight: 48)
                            }
                            Button { Task { await session.signIn() } } label: {
                                Text("Sign In").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 54)
                            }
                            .foregroundStyle(.white).background(Color(red: 237/255, green: 89/255, blue: 9/255))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Button { Task { await session.signIn(createAccount: true) } } label: {
                                Text("Create Account").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 54)
                            }
                            .foregroundStyle(Color(red: 32/255, green: 35/255, blue: 33/255))
                            .background(.white)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4), lineWidth: 1))
                            if case .failed = session.state {
                                Button("Sign out") { Task { await session.signOut() } }.frame(minHeight: 44)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(session.busy || session.configuration == nil)
                        .opacity(session.busy || session.configuration == nil ? 0.5 : 1)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: 520)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 245/255, green: 245/255, blue: 241/255).ignoresSafeArea())
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

// Page requests reserve their content layout; only sign-in owns the reveal.
private struct EzBossSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.20)).frame(width: 130, height: 22).padding(.bottom, 10)
            ForEach(0..<4) { index in
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.12)).frame(maxWidth: .infinity).frame(height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.12)).frame(width: index % 2 == 0 ? 65 : 48, height: 14)
                }.frame(height: 28)
            }
        }.frame(maxWidth: 560).padding(20).accessibilityHidden(true)
    }
}
private struct EzBossProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 8) {
            if configuration.label != nil { EzBossSkeleton() }
            else { EzBossAnimatedMark(reveal: false).frame(width: 52, height: 16) }
            configuration.label
        }.accessibilityElement(children: .combine)
    }
}

private struct EzBossAnimatedMark: View {
    var reveal: Bool
    @State private var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let orange = Color(red: 1, green: 125.0/255, blue: 34.0/255)
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let elapsed = max(0, timeline.date.timeIntervalSince(started))
                let full = CGRect(origin: .zero, size: size)
                let image = context.resolve(Image("ezboss-loading", bundle: .main))
                let letters: [(Double, Double)] = [(60,160),(160,255),(255,372),(372,489),(489,587),(587,687)]
                for (index, bounds) in letters.enumerated() {
                    var letter = context
                    letter.clip(to: Path(CGRect(x: bounds.0/741*size.width, y: size.height*0.2, width: (bounds.1-bounds.0)/741*size.width, height: size.height*0.6)))
                    letter.opacity = reveal && !reduceMotion ? min(1, max(0, (elapsed - Double(index)*0.173)/0.397)) : 1
                    letter.draw(image, in: full)
                }
                var border = context
                if reveal && !reduceMotion {
                    let progress = min(1, max(0,(elapsed-0.173)/1.09))
                    border.clip(to: Path(CGRect(x: 0, y: 0, width: size.width*progress, height: size.height)))
                    border.opacity = progress
                }
                for inset in [3.0,12.0] {
                    let frame = CGRect(x: inset/741*size.width, y: inset/221*size.height, width: (741-inset*2)/741*size.width, height: (221-inset*2)/221*size.height)
                    var path = Path(); path.move(to: CGPoint(x: frame.minX, y: frame.minY)); path.addLine(to: CGPoint(x: frame.maxX,y: frame.minY)); path.addLine(to: CGPoint(x: frame.maxX,y: frame.maxY)); path.addLine(to: CGPoint(x: frame.minX,y: frame.maxY)); path.closeSubpath()
                    if reveal || reduceMotion { border.stroke(path, with: .color(orange), lineWidth: 4/741*size.width) }
                    else {
                        let head = elapsed.truncatingRemainder(dividingBy: 2.8)/2.8
                        border.stroke(path.trimmedPath(from: head, to: min(1,head+0.32)), with: .color(orange), lineWidth: 4/741*size.width)
                        if head+0.32>1 { border.stroke(path.trimmedPath(from: 0, to: head+0.32-1), with: .color(orange), lineWidth: 4/741*size.width) }
                    }
                }
            }
        }
        .accessibilityLabel(reveal ? "Page ready" : "Loading")
    }
}

private struct EzBossLoadingTransition: ViewModifier {
    let ready: Bool
    @State private var completed = false
    @State private var dismissing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var covering: Bool { ready && !completed && !reduceMotion }
    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!covering)
            .accessibilityHidden(covering)
            .overlay {
                if covering {
                    Color.white.ignoresSafeArea().overlay { EzBossAnimatedMark(reveal: true).frame(width: 230, height: 230*221/741) }
                        .opacity(dismissing ? 0 : 1)
                        .animation(.easeOut(duration: 0.32), value: dismissing)
                }
            }
            .task(id: ready) {
                guard ready else { completed = false; dismissing = false; return }
                guard !completed else { return }
                guard !reduceMotion else { completed = true; return }
                dismissing = false
                do {
                    try await Task.sleep(for: .milliseconds(1420))
                    dismissing = true
                    try await Task.sleep(for: .milliseconds(320))
                } catch { dismissing = false; return }
                completed = true
                dismissing = false
            }
    }
}
