import XCTest
@testable import EzBossCore

final class NativeAuthProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int,[String:String],String))!
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        let (status,headers,body)=Self.handler(request)
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class MemoryCredentials: NativeCredentialPersistence {
    var value:NativeCredential?
    func read() throws -> NativeCredential? { value }
    func write(_ value:NativeCredential) throws { self.value=value }
    func clear()->Bool { value=nil;return true }
}
final class BetterAuthTests: XCTestCase {
    @MainActor func testMfaIntermediateNeverPersistsBodyOrHeaderCredentials() async throws {
        let vault=MemoryCredentials()
        let client=BetterAuthCredentialStore(origin:URL(string:"https://auth.example")!,bundleID:"pro.ezboss.test",protocolClasses:[NativeAuthProtocol.self],persistence:vault)
        NativeAuthProtocol.handler={request in
            XCTAssertEqual(request.url?.path,"/api/auth/sign-in/email")
            return (200,["set-auth-token":"misleading.signature"],#"{"twoFactorRedirect":true,"token":"raw-body-token"}"#)
        }
        let complete=try await client.signIn(email:"fixture@example.test",password:"fixture password")
        XCTAssertFalse(complete);XCTAssertNil(vault.value)
    }
    @MainActor func testOnlyValidatedSignedSessionIsStoredAndOutagesKeepIt() async throws {
        let vault=MemoryCredentials()
        let client=BetterAuthCredentialStore(origin:URL(string:"https://auth.example")!,bundleID:"pro.ezboss.test",protocolClasses:[NativeAuthProtocol.self],persistence:vault)
        var unavailable=false
        NativeAuthProtocol.handler={request in
            if request.url!.path.hasSuffix("sign-in/email") { return (200,["set-auth-token":"signed.fixture"],#"{"token":"untrusted-body","user":{"id":"user"}}"#) }
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer signed.fixture")
            return unavailable ? (503,[:],"private upstream response") : (200,[:],#"{"session":{"id":"session","userId":"user","expiresAt":"2099-01-01T00:00:00Z"},"user":{"id":"user"}}"#)
        }
        let complete=try await client.signIn(email:"fixture@example.test",password:"fixture password")
        XCTAssertTrue(complete);XCTAssertEqual(vault.value?.kind,.session);XCTAssertEqual(vault.value?.token,"signed.fixture")
        unavailable=true
        do { _=try await client.accessToken();XCTFail("Expected unavailable") } catch NativeAuthFailure.unavailable {} catch { XCTFail("Unexpected error") }
        XCTAssertNotNil(vault.value)
        _=client.clear();XCTAssertNil(vault.value)
    }
    @MainActor func testNewIdentityKeepsCredentialThroughCompanySetup() async throws {
        let vault=MemoryCredentials()
        let store=BetterAuthCredentialStore(origin:URL(string:"https://auth.example")!,bundleID:"pro.ezboss.test",protocolClasses:[NativeAuthProtocol.self],persistence:vault)
        let api=APIClient(baseURL:URL(string:"https://api.example")!,protocolClasses:[NativeAuthProtocol.self],identityDiscovery:true)
        let config=try NativeConfiguration(values:["AuthProvider":"better-auth","AuthOrigin":"https://auth.example","APIBaseURL":"https://api.example"],bundleID:"pro.ezboss.test")
        let session=Session(configuration:config,manager:store,api:api)
        var needsSetup=true
        var authUnavailable=false
        NativeAuthProtocol.handler={request in
            switch request.url!.path {
            case "/api/auth/sign-in/email": return (200,["set-auth-token":"signed.fixture"],#"{"user":{"id":"user"}}"#)
            case "/api/auth/get-session": return authUnavailable ? (503,[:],"{}") : (200,[:],#"{"session":{"id":"session","userId":"user","expiresAt":"2099-01-01T00:00:00Z"},"user":{"id":"user"}}"#)
            case "/account/me": return (200,[:],needsSetup ? #"{"pendingIdentity":true}"# : #"{"memberships":[]}"#)
            case "/onboarding/contractor": needsSetup=false;return (201,[:],"{}")
            case "/users/me": return (200,[:],#"{"id":42,"status":"active","displayName":"Fixture"}"#)
            default: return (503,[:],"{}")
            }
        }
        let complete=try await session.nativeSignIn(email:"fixture@example.test",password:"fixture password")
        XCTAssertTrue(complete);XCTAssertEqual(session.state,.pendingAccount);XCTAssertNotNil(vault.value)
        try await session.createNativeCompany(["firstName":"Fixture","lastName":"User","employeeCount":"1","tradeTypes":["Electrical"]])
        XCTAssertEqual(session.state,.authenticated(Identity(id:42,displayName:"Fixture",status:"active",roleName:nil)))
        XCTAssertNotNil(vault.value)
        let authenticated=session.state
        authUnavailable=true;await session.restore()
        XCTAssertEqual(session.state,authenticated);XCTAssertTrue(session.authenticationUnavailable);XCTAssertNotNil(vault.value)
        var ran=false
        do { let _:Bool=try await session.business { _,_ in ran=true;return true };XCTFail("Writes must wait for revalidation") }catch{}
        XCTAssertFalse(ran)
        authUnavailable=false;await session.restore();XCTAssertFalse(session.authenticationUnavailable)

    }
    func testAmbiguousCompanyDiscoveryDoesNotInvalidateIdentity() async throws {
        let api=APIClient(baseURL:URL(string:"https://api.example")!,protocolClasses:[NativeAuthProtocol.self],identityDiscovery:true)
        NativeAuthProtocol.handler={request in
            request.url!.path=="/account/me" ? (409,[:],#"{"memberships":[]}"#) : (200,[:],#"{"id":42,"status":"active"}"#)
        }
        let identity=try await api.currentUser(accessToken:"fixture-token")
        XCTAssertEqual(identity.id,42)
    }
    func testBetterAuthConfigurationDoesNotRequireInventedLegacyIdentity() throws {
        let values:[String:Any]=["AuthProvider":"better-auth","AuthOrigin":"https://alpha.example","APIBaseURL":"https://alpha.example/api"]
        let config=try NativeConfiguration(values:values,bundleID:"pro.ezboss.test")
        XCTAssertEqual(config.authProvider,"better-auth");XCTAssertEqual(config.domain,"")
        for unsafe in ["http://alpha.example","https://user:secret@alpha.example","https://alpha.example/path","https://alpha.example?code=private"] {
            var bad=values;bad["AuthOrigin"]=unsafe
            XCTAssertThrowsError(try NativeConfiguration(values:bad,bundleID:"pro.ezboss.test"))
        }
    }
}
