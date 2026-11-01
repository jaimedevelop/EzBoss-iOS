import XCTest
@testable import EzBossCore
final class OperationalTests: XCTestCase {
    func testOperationalListEnvelopesAndNumericIDs() throws {
        for key in ["items","jobs","workOrders","purchaseOrders","collections","laborItems"] {
            let rows = try APIClient.operationRows([key:[["id":7,"name":"Synthetic"]]])
            XCTAssertEqual(rows.first?.id,"7")
        }
        XCTAssertThrowsError(try APIClient.operationRows(["unexpected":[]]))
    }
    func testPhotoIdentitySurvivesRetryAndRejectsOversize() throws {
        let pending = try PendingTaskPhoto(jpeg:Data([0xff,0xd8,0xff]))
        XCTAssertEqual(pending.requestID,pending.requestID)
        XCTAssertThrowsError(try PendingTaskPhoto(jpeg:Data()))
        XCTAssertThrowsError(try PendingTaskPhoto(jpeg:Data(repeating:0,count:5*1024*1024+1)))
    }
}

final class NativeAIReviewTests: XCTestCase {
    func testCustomProviderReviewKeepsOnlyTypedInventoryAndRejectsUnknownIDs() throws {
        let inventory:[String:Any] = ["products":[["id":7,"name":"TEST product"]],"tools":[]]
        let proposal:[String:Any] = ["name":"TEST kit","description":"Review","items":[["contentType":"products","itemId":7,"quantity":2]]]
        let review=try nativeAIReview(proposal,inventory:inventory)
        XCTAssertEqual((review["preview"] as? [[String:Any]])?.first?["name"] as? String,"TEST product")
        var wrong=proposal;wrong["items"] = [["contentType":"tools","itemId":7,"quantity":2]]
        XCTAssertThrowsError(try nativeAIReview(wrong,inventory:inventory))
    }
}
