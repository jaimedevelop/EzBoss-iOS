import Foundation
import Security

enum NativeAuthFailure: Error { case rejected, unavailable, storage, incomplete }
enum NativeCredentialKind: String, Codable { case session }
struct NativeCredential: Codable {
    let kind: NativeCredentialKind
    let token: String
}

@MainActor
protocol NativeCredentialPersistence {
    func read() throws -> NativeCredential?
    func write(_ value: NativeCredential) throws
    @discardableResult func clear() -> Bool
}
@MainActor
private final class KeychainCredentialPersistence: NativeCredentialPersistence {
    private let service: String
    init(service:String) { self.service=service }
    private var query: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
         kSecAttrAccount as String:"session",kSecAttrSynchronizable as String:false]
    }
    func read() throws -> NativeCredential? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess else { throw NativeAuthFailure.unavailable }
        guard let data=result as? Data, let value=try? JSONDecoder().decode(NativeCredential.self,from:data), value.kind == .session else { throw NativeAuthFailure.rejected }
        return value
    }
    func write(_ value:NativeCredential) throws {
        let data=try JSONEncoder().encode(value)
        let attrs:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status=SecItemUpdate(query as CFDictionary,attrs as CFDictionary)
        if status != errSecSuccess {
            guard status==errSecItemNotFound, SecItemAdd(query.merging(attrs){_,new in new} as CFDictionary,nil)==errSecSuccess else { throw NativeAuthFailure.storage }
        }
    }
    @discardableResult func clear() -> Bool {
        let status=SecItemDelete(query as CFDictionary)
        return status==errSecSuccess || status==errSecItemNotFound
    }
}

// This independent Keychain namespace cannot be mistaken for Auth0/OAuth credentials.
@MainActor
final class BetterAuthCredentialStore: SessionCredentialStore {
    private let origin: URL
    private let persistence: NativeCredentialPersistence
    private let transport: URLSession
    private var cookies: [HTTPCookie] = []
    private var generation = 0
    init(origin: URL, bundleID: String, protocolClasses: [AnyClass]? = nil, persistence: NativeCredentialPersistence? = nil) {
        self.origin = origin; self.persistence = persistence ?? KeychainCredentialPersistence(service:bundleID + ".better-auth")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { config.protocolClasses = protocolClasses }
        transport = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { transport.invalidateAndCancel() }
    var hasSession: Bool { do { return try persistence.read() != nil } catch { return true } }
    @discardableResult func clear() -> Bool {
        generation += 1; cookies.removeAll(); return persistence.clear()
    }
    func login() async throws { throw NativeAuthFailure.incomplete }
    func login(createAccount: Bool) async throws { throw NativeAuthFailure.incomplete }
    func request(_ path: String, body: [String:Any]? = nil, bearer: String? = nil, intermediate: Bool = false) async throws -> ([String:Any],String?) {
        let epoch = generation
        var request = URLRequest(url:origin.appendingPathComponent("api/auth" + path))
        request.httpMethod = body == nil ? "GET" : "POST"; request.timeoutInterval = 15
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject:body); request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)",forHTTPHeaderField:"Authorization") }
        if intermediate {
            let valid = cookies.filter { ($0.expiresDate ?? .distantFuture) > Date() }
            for (key,value) in HTTPCookie.requestHeaderFields(with:valid) { request.setValue(value,forHTTPHeaderField:key) }
        }
        let data: Data; let response: URLResponse
        do { (data,response) = try await transport.data(for:request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw NativeAuthFailure.unavailable }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw NativeAuthFailure.unavailable }
        if response.statusCode >= 500 || response.statusCode == 429 { throw NativeAuthFailure.unavailable }
        guard (200..<300).contains(response.statusCode) else { throw NativeAuthFailure.rejected }
        let decoded=try? JSONSerialization.jsonObject(with:data)
        if path=="/get-session", decoded is NSNull { throw NativeAuthFailure.rejected }
        let object = decoded as? [String:Any] ?? [:]
        if intermediate || path == "/sign-in/email" {
            let headers = response.allHeaderFields.reduce(into:[String:String]()) { if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value } }
            // Transient jar only; never write MFA cookies to Keychain, defaults or disk.
            for cookie in HTTPCookie.cookies(withResponseHeaderFields:headers,for:request.url!) {
                cookies.removeAll { $0.name == cookie.name }
                if cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")) == origin.host { cookies.append(cookie) }
            }
        }
        return (object,response.value(forHTTPHeaderField:"set-auth-token"))
    }
    @discardableResult private func validate(_ token: String) async throws -> String {
        guard token.split(separator:".").count == 2 else { throw NativeAuthFailure.rejected }
        let (value,_) = try await request("/get-session",bearer:token)
        guard let session=value["session"] as? [String:Any], let user=value["user"] as? [String:Any],
              let id=user["id"] as? String, !id.isEmpty, let sessionId=session["id"] as? String, !sessionId.isEmpty,
              session["userId"] as? String == id, let expiry=session["expiresAt"] as? String else { throw NativeAuthFailure.unavailable }
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let expiration=formatter.date(from:expiry) ?? ISO8601DateFormatter().date(from:expiry)
        guard let expiration else { throw NativeAuthFailure.unavailable }
        guard expiration>Date() else { throw NativeAuthFailure.rejected }
        return id
    }
    private func finish(_ result: ([String:Any],String?)) async throws -> Bool {
        if result.0["twoFactorRedirect"] as? Bool == true { return false }
        guard let token = result.1, !token.isEmpty else { throw NativeAuthFailure.incomplete }
        let epoch = generation
        let userId=try await validate(token); try Task.checkCancellation()
        guard let expected=(result.0["user"] as? [String:Any])?["id"] as? String, expected==userId else { throw NativeAuthFailure.rejected }
        guard epoch == generation else { throw CancellationError() }
        try persistence.write(NativeCredential(kind:.session,token:token))
        cookies.removeAll(); return true
    }
    func signIn(email: String, password: String) async throws -> Bool {
        guard clear() else { throw NativeAuthFailure.storage }
        return try await finish(request("/sign-in/email",body:["email":email,"password":password]))
    }
    func verify(code: String, backup: Bool) async throws -> Bool {
        try await finish(request(backup ? "/two-factor/verify-backup-code" : "/two-factor/verify-totp",body:["code":code,"trustDevice":false],intermediate:true))
    }
    func accessToken() async throws -> String {
        guard let value = try persistence.read() else { throw NativeAuthFailure.rejected }
        try await validate(value.token); return value.token
    }
    @discardableResult func revoke() async -> Bool {
        let token = (try? persistence.read())?.token
        let removed = clear() // Invalidate generations before remote work.
        if let token { _ = try? await request("/sign-out",body:[:],bearer:token) }
        return removed
    }
}
