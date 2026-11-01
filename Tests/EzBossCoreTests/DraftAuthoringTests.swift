import XCTest
@testable import EzBossCore

final class DraftAuthoringTests: XCTestCase {
    func testDraftCentRoundingAndMetadataSurvive() throws {
        var draft = DraftEditor()
        draft.customer = "TEST customer"
        draft.lines = [["description": "Manual", "quantity": "3", "unitPrice": "0.335", "type": "manual", "notes": "keep"]]
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.encoded()) as? [String: Any])
        let line = try XCTUnwrap((body["lineItems"] as? [[String: Any]])?.first)
        XCTAssertEqual(line["total"] as? Double, 1.02)
        XCTAssertEqual(line["notes"] as? String, "keep")
        XCTAssertEqual(body["draftOnly"] as? Bool, true)
    }
    func testSignedAdjustmentRemainsSignedAndKeepsItsKind() throws {
        var draft = DraftEditor(); draft.customer = "TEST"
        draft.lines = [["type":"custom","quantity":1,"unitPrice":-20,"adjustmentKind":"group"]]
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:draft.encoded()) as? [String:Any])
        let line = try XCTUnwrap((body["lineItems"] as? [[String:Any]])?.first)
        XCTAssertEqual(line["total"] as? Double,-20)
        XCTAssertEqual(line["adjustmentKind"] as? String,"group")
    }
    func testMissingCustomerAndInvalidAmountsNeverEncode() throws {
        var draft = DraftEditor()
        XCTAssertThrowsError(try draft.encoded())
        draft.customer = "TEST customer"
        for price in ["-1", "invalid"] {
            draft.lines = [["quantity": 1, "unitPrice": price]]
            XCTAssertThrowsError(try draft.encoded())
        }
    }
    func testLoadedDraftCarriesConcurrencyTokenAndExcludesIdentity() throws {
        let draft = try DraftEditor(data: Data(#"{"id":7,"estimateState":"draft","updatedAt":"2026-10-31T12:00:00.000Z","customerName":"TEST","taxRate":"8.25","lineItems":[],"invoiceNumber":"cannot-write"}"#.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.encoded()) as? [String: Any])
        XCTAssertEqual(body["expectedUpdatedAt"] as? String, "2026-10-31T12:00:00.000Z")
        XCTAssertNil(body["invoiceNumber"])
        XCTAssertNil(body["id"])
    }
    func testUnknownDocumentStateCannotEnterEditor() {
        XCTAssertThrowsError(try DraftEditor(data: Data(#"{"id":7,"estimateState":"unknown","updatedAt":"2026-10-31T12:00:00Z"}"#.utf8)))
    }
    func testConflictKeepsDraftAndDoesNotReportSuccess() async throws {
        StubProtocol.status = 409; StubProtocol.body = "{}"
        let api = APIClient(baseURL: URL(string: "https://staging.example/api")!, protocolClasses: [StubProtocol.self])
        var draft = DraftEditor(); draft.customer = "TEST"
        do { _ = try await api.saveDraft(accessToken: "synthetic", membership: "company-a", draft: draft); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? APIError, .conflict) }
        XCTAssertEqual(draft.customer, "TEST")
        XCTAssertEqual(StubProtocol.request?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.request?.value(forHTTPHeaderField: "X-Company-Membership-Id"), "company-a")
    }
    func testSentEditorKeepsConcurrencyTokenAndUsesRevisionPolicy() throws {
        let draft = try DraftEditor(data: Data(#"{"id":7,"estimateState":"estimate","updatedAt":"2026-10-31T12:00:00Z","customerName":"TEST","taxRate":0,"lineItems":[]}"#.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.encoded()) as? [String: Any])
        XCTAssertEqual(body["draftOnly"] as? Bool, false)
        XCTAssertEqual(body["nativeAuthoring"] as? Bool, true)
        XCTAssertNotNil(body["expectedUpdatedAt"])
    }
    func testClientContactSelectionPreservesSnapshotAndAddress() throws {
        var draft = DraftEditor()
        draft.select(NativeCustomer(payload: ["id": 4, "name": "TEST company", "billingAddress": "TEST address", "billingEqualToService": true]), contact: ["name": "Approver", "email": "test@example.com", "phone": "555"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.encoded()) as? [String: Any])
        XCTAssertEqual(body["customerId"] as? String, "4")
        XCTAssertEqual(body["customerEmail"] as? String, "test@example.com")
        XCTAssertEqual(body["serviceAddress"] as? String, "TEST address")
        XCTAssertNotNil(body["clientSnapshot"])
    }

}
