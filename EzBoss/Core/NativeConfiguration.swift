import Foundation

enum ConfigurationError: Error, Equatable {
    case invalidFields([String])
}

struct NativeConfiguration {
    let authProvider: String
    let authOrigin: URL?
    let domain: String
    let clientID: String
    let audience: String
    let api: URL
    let bundleID: String

    init(values: [String: Any], bundleID: String) throws {
        func value(_ key: String) -> String {
            (values[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func populated(_ value: String) -> Bool {
            !value.isEmpty && !value.uppercased().contains("YOUR_") &&
                !value.contains("$(") && !value.uppercased().contains("CHANGE_ME") &&
                !value.contains(where: { $0.isWhitespace || $0.isNewline })
        }
        let provider = value("AuthProvider").isEmpty ? "auth0" : value("AuthProvider")
        let authURL = URL(string:value("AuthOrigin"))
        let domain = value("Auth0Domain")
        let clientID = value("Auth0ClientId")
        let audience = value("Auth0Audience")
        let apiString = value("APIBaseURL")
        let url = URL(string: apiString)
        let validPort = url?.port.map { (1...65535).contains($0) } ?? true
        var invalid: [String] = []
        if provider == "auth0" && (!populated(domain) || domain.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$"#, options: .regularExpression) == nil) {
            invalid.append("Auth0Domain")
        }
        if provider == "auth0" && (!populated(clientID) || clientID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil) {
            invalid.append("Auth0ClientId")
        }
        if provider == "auth0" && !populated(audience) { invalid.append("Auth0Audience") }
        if !populated(apiString) || url?.scheme != "https" || url?.host?.isEmpty != false ||
            url?.user != nil || url?.password != nil || url?.query != nil || url?.fragment != nil || !validPort {
            invalid.append("APIBaseURL")
        }
        if !populated(bundleID) || bundleID.range(of: #"^[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)+$"#, options: .regularExpression) == nil {
            invalid.append("CFBundleIdentifier")
        }
        if !["auth0","better-auth"].contains(provider) { invalid.append("AuthProvider") }
        if provider == "better-auth" && (authURL?.scheme != "https" || authURL?.host?.isEmpty != false || authURL?.host?.contains("*") == true || !(1...65535).contains(authURL?.port ?? 443) || authURL?.user != nil || authURL?.password != nil || authURL?.query != nil || authURL?.fragment != nil || !["", "/"].contains(authURL?.path ?? "invalid")) { invalid.append("AuthOrigin") }
        self.authProvider = provider; self.authOrigin = authURL
        guard invalid.isEmpty, let api = url else { throw ConfigurationError.invalidFields(invalid) }
        self.domain = domain
        self.clientID = clientID
        self.audience = audience
        self.api = api
        self.bundleID = bundleID
    }

    var callbackURL: URL {
        URL(string: "\(bundleID)://\(domain)/ios/\(bundleID)/callback")!
    }
}
