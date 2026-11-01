import Foundation

struct Identity: Decodable, Equatable {
    // Database IDs are integers; keep them typed instead of assuming UUID strings.
    let id: Int
    let displayName: String?
    let status: String
    let roleName: String?
}

enum APIError: Error, Equatable {
    case actionFailed, conflict, invalidDraft, expiredSession, accessDenied, missingAccount, inactiveAccount, unavailable, invalidResponse, missingResource, companySelection

    var requiresSignIn: Bool {
        self == .expiredSession || self == .accessDenied || self == .inactiveAccount
    }

    var message: String {
        switch self {
        case .actionFailed: return "The action was not confirmed. Check required information and refresh the document before retrying."
        case .conflict: return "The document changed or was sent. Your edits are preserved; reload before saving."
        case .invalidDraft: return "Enter a customer, valid line amounts and a tax rate from 0 to 100."
        case .missingResource: return "This document is unavailable in this company."
        case .companySelection: return "Select a company to continue."
        case .expiredSession: return "Your session has expired. Please sign in again."
        case .accessDenied: return "Access was denied. Contact your administrator or sign in with another account."
        case .missingAccount: return "Sign-in succeeded, but no EzBoss account is linked. Contact your administrator."
        case .inactiveAccount: return "This account is inactive. Contact your administrator."
        case .unavailable: return "The account service is unavailable. Please retry."
        case .invalidResponse: return "Your account could not be loaded. Please retry or contact support."
        }
    }
}

// One session per API client; never use a global shared cookie/cache store for identity.
final class APIClient {
    private let baseURL: URL
    private let transport: URLSession

    init(baseURL: URL, protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        transport = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { transport.invalidateAndCancel() }

    func resource(_ path: String, token: String, membership: String? = nil, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String = "application/json", idempotencyKey: String? = nil, providerKey: String? = nil) async throws -> (Data, Int) {
        guard !token.isEmpty else { throw APIError.expiredSession }
        var url = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let membership { request.setValue(membership, forHTTPHeaderField: "X-Company-Membership-Id") }
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let providerKey { request.setValue(providerKey, forHTTPHeaderField:"X-AI-Key") }
        request.timeoutInterval = providerKey == nil ? 20 : 60
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, response.statusCode)
    }

    func transportForCustomRequest(_ request: URLRequest) async throws -> (Data,Int) {
        let (data,response) = try await transport.data(for:request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data,response.statusCode)
    }

    func currentUser(accessToken: String) async throws -> Identity {
        guard !accessToken.isEmpty else { throw APIError.expiredSession }
        var request = URLRequest(url: baseURL.appendingPathComponent("users/me"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch response.statusCode {
        case 200:
            guard let user = try? JSONDecoder().decode(Identity.self, from: data), user.id > 0 else { throw APIError.invalidResponse }
            guard user.status == "active" else { throw APIError.inactiveAccount }
            return user
        case 401: throw APIError.expiredSession
        case 403: throw APIError.accessDenied
        case 404: throw APIError.missingAccount
        case 500...599: throw APIError.unavailable
        default: throw APIError.invalidResponse
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
