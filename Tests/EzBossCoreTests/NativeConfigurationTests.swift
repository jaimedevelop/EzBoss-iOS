import XCTest
@testable import EzBossCore

final class NativeConfigurationTests: XCTestCase {
    private let valid: [String: Any] = [
        "Auth0Domain": "tenant.us.auth0.com", "Auth0ClientId": "native-public-id",
        "Auth0Audience": "https://api.example", "APIBaseURL": "https://staging.example/api"
    ]

    func testCallbackUsesActualBundleIDAndTenant() throws {
        let config = try NativeConfiguration(values: valid, bundleID: "pro.ezboss.ios")
        XCTAssertEqual(config.callbackURL.absoluteString, "pro.ezboss.ios://tenant.us.auth0.com/ios/pro.ezboss.ios/callback")
    }

    func testMissingAndPlaceholderValuesFailClosed() {
        for key in valid.keys {
            for value in ["", "YOUR_VALUE", "$(UNRESOLVED)", "CHANGE_ME"] {
                var input = valid; input[key] = value
                XCTAssertThrowsError(try NativeConfiguration(values: input, bundleID: "pro.ezboss.ios"))
            }
        }
    }

    func testRejectsUnsafeAPIAddressesAndDomainURLs() {
        for url in ["http://api.example", "https://u:p@api.example", "https://api.example?token=x", "https://api.example#fragment", "https:///", "https://api.example:99999", "https://api.example/ bad"] {
            var input = valid; input["APIBaseURL"] = url
            XCTAssertThrowsError(try NativeConfiguration(values: input, bundleID: "pro.ezboss.ios"), url)
        }
        for domain in ["https://tenant.auth0.com", "tenant.auth0.com/path", "tenant.auth0.com:443", "-tenant.auth0.com"] {
            var input = valid; input["Auth0Domain"] = domain
            XCTAssertThrowsError(try NativeConfiguration(values: input, bundleID: "pro.ezboss.ios"))
        }
    }

    func testErrorsContainFieldNamesOnly() {
        var input = valid; input["APIBaseURL"] = "https://user:private-password@api.example"
        XCTAssertThrowsError(try NativeConfiguration(values: input, bundleID: "pro.ezboss.ios")) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidFields(["APIBaseURL"]))
            XCTAssertFalse(String(describing: $0).contains("private-password"))
        }
    }
}
