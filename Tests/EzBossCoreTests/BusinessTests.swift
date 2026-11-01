import XCTest
@testable import EzBossCore

final class BusinessTests: XCTestCase {
    private func api(_ status: Int, _ body: String) -> APIClient {
        StubProtocol.status = status; StubProtocol.body = body; StubProtocol.request = nil
        return APIClient(baseURL: URL(string: "https://staging.example/api")!, protocolClasses: [StubProtocol.self])
    }
    func testListUsesCompanyAndEscapesCustomerSearchBeforePagination() async throws {
        let client = api(200, #"[{"id":7,"estimateNumber":"E7","estimateState":"estimate","total":"123.45"},{"id":8,"estimateNumber":"E8","invoiceNumber":"I8","estimateState":"invoice","total":12.50}]"#)
        let rows = try await client.documents(accessToken: "synthetic", membership: "company-a", search: " A & B+ ", kind: "invoice", offset: 25)
        XCTAssertEqual(rows[0].total, Decimal(string: "123.45"))
        XCTAssertEqual(rows[1].number, "I8")
        let request = try XCTUnwrap(StubProtocol.request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Company-Membership-Id"), "company-a")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "customerName" }?.value, "A & B+")
        XCTAssertEqual(query.first { $0.name == "offset" }?.value, "25")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "25")
        XCTAssertEqual(query.first { $0.name == "estimateState" }?.value, "invoice")
    }
    func testCompanyAmbiguityDiscoversMembershipsWithoutSelectingFirst() async throws {
        let client = api(409, #"{"memberships":[{"id":"m1","companyName":"One","kind":"owner","isActive":true,"companyIsActive":true},{"id":"m2","kind":"employee","isActive":true,"employeeIsActive":false,"companyIsActive":true}]}"#)
        let result = try await client.companies(accessToken: "synthetic")
        XCTAssertNil(result.companyContext)
        XCTAssertTrue(result.memberships[0].available)
        XCTAssertFalse(result.memberships[1].available)
    }
    func testResourceFailuresDoNotBecomeEmptyOrMissingAccount() async {
        for (status, expected) in [(403, APIError.accessDenied), (404, .missingResource), (401, .expiredSession), (409, .companySelection), (503, .unavailable)] {
            do { _ = try await api(status, "private body").document(accessToken: "synthetic", membership: "m1", id: 7); XCTFail("Expected denial") }
            catch { XCTAssertEqual(error as? APIError, expected) }
        }
    }
    func testEmptyListAndAbsentMoneyAreExplicit() async throws {
        let rows = try await api(200, "[]").documents(accessToken: "synthetic", membership: "m1", search: "", kind: nil, offset: 0)
        XCTAssertTrue(rows.isEmpty)
        let row = try await api(200, #"{"id":7,"estimateState":"draft","lineItems":[]}"#).document(accessToken: "synthetic", membership: "m1", id: 7)
        XCTAssertNil(row.total)
        XCTAssertEqual(row.lineItems, [])
    }
}
