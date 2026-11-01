import Foundation

struct CompanyMembership: Decodable, Identifiable, Equatable {
    let id: String
    let companyName: String?
    let kind: String
    let isActive: Bool
    let employeeIsActive: Bool?
    let companyIsActive: Bool
    var available: Bool { isActive && companyIsActive && (kind == "owner" || employeeIsActive == true) }
}
struct CompanyAccount: Decodable {
    let memberships: [CompanyMembership]
    let companyContext: CompanyContext?
}
struct CompanyContext: Decodable { let membershipId: String }
struct CompanyDiscovery: Decodable { let memberships: [CompanyMembership] }

// PostgreSQL numeric columns may arrive as JSON strings. Never turn absent money into zero.
struct Document: Decodable, Identifiable, Equatable {
    let id: Int
    let estimateNumber: String?
    let invoiceNumber: String?
    let customerName: String?
    let estimateState: String
    let clientState: String?
    let total: Decimal?
    let subtotal: Decimal?
    let tax: Decimal?
    let projectDescription: String?
    let validUntil: String?
    let lineItems: [DocumentLine]?
    let currentRevision: Int?
    let collectionHold: Bool?
    let revisionsHistory: [DocumentHistory]?
    var number: String { (estimateState == "invoice" ? invoiceNumber : estimateNumber) ?? "Number pending" }
    enum CodingKeys: String, CodingKey {
        case id, estimateNumber, invoiceNumber, customerName, estimateState, clientState, total, subtotal, tax, projectDescription, validUntil, lineItems, currentRevision, collectionHold, revisionsHistory
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        guard id > 0 else { throw APIError.invalidResponse }
        estimateNumber = try c.decodeIfPresent(String.self, forKey: .estimateNumber)
        invoiceNumber = try c.decodeIfPresent(String.self, forKey: .invoiceNumber)
        customerName = try c.decodeIfPresent(String.self, forKey: .customerName)
        estimateState = try c.decode(String.self, forKey: .estimateState)
        clientState = try c.decodeIfPresent(String.self, forKey: .clientState)
        total = try c.money(.total); subtotal = try c.money(.subtotal); tax = try c.money(.tax)
        projectDescription = try c.decodeIfPresent(String.self, forKey: .projectDescription)
        validUntil = try c.decodeIfPresent(String.self, forKey: .validUntil)
        lineItems = try c.decodeIfPresent([DocumentLine].self, forKey: .lineItems)
        currentRevision = try c.decodeIfPresent(Int.self, forKey: .currentRevision)
        collectionHold = try c.decodeIfPresent(Bool.self, forKey: .collectionHold)
        revisionsHistory = try c.decodeIfPresent([DocumentHistory].self, forKey: .revisionsHistory)
    }
}
struct DocumentLine: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String?
    let description: String?
    let quantity: Decimal?
    let total: Decimal?
    enum CodingKeys: String, CodingKey { case id, name, description, quantity, total }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        quantity = try c.money(.quantity); total = try c.money(.total)
    }
}
private extension KeyedDecodingContainer {
    func money(_ key: Key) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let text = try? decode(String.self, forKey: key) {
            guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw APIError.invalidResponse }
            return value
        }
        return try decode(Decimal.self, forKey: key)
    }
}

extension APIClient {
    func companies(accessToken: String, membership: String? = nil) async throws -> CompanyAccount {
        let query = membership.map { [URLQueryItem(name: "membershipId", value: $0)] } ?? []
        let (data, status) = try await resource("account/me", token: accessToken, query: query)
        if status == 409 {
            let discovery = try JSONDecoder().decode(CompanyDiscovery.self, from: data)
            return CompanyAccount(memberships: discovery.memberships, companyContext: nil)
        }
        try checkResourceStatus(status)
        return try JSONDecoder().decode(CompanyAccount.self, from: data)
    }
    func documents(accessToken: String, membership: String, search: String, kind: String?, offset: Int) async throws -> [Document] {
        var query = [URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "offset", value: String(offset))]
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { query.append(URLQueryItem(name: "customerName", value: search.trimmingCharacters(in: .whitespacesAndNewlines))) }
        if let kind { query.append(URLQueryItem(name: "estimateState", value: kind)) }
        let (data, status) = try await resource("estimates", token: accessToken, membership: membership, query: query)
        try checkResourceStatus(status)
        return try JSONDecoder().decode([Document].self, from: data)
    }
    func document(accessToken: String, membership: String, id: Int) async throws -> Document {
        guard id > 0 else { throw APIError.invalidResponse }
        let (data, status) = try await resource("estimates/\(id)", token: accessToken, membership: membership)
        try checkResourceStatus(status)
        return try JSONDecoder().decode(Document.self, from: data)
    }
    private func checkResourceStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 401: throw APIError.expiredSession
        case 403: throw APIError.accessDenied
        case 404: throw APIError.missingResource
        case 409: throw APIError.companySelection
        case 500...599: throw APIError.unavailable
        default: throw APIError.invalidResponse
        }
    }
}


// Keep the full owner payload so editing a manual line never strips inventory,
// group or collection metadata belonging to another line.
struct DraftEditor {
    var id: Int?
    var payload: [String: Any] = ["estimateState": "draft", "customerName": "", "taxRate": 0, "lineItems": []]
    var customer: String {
        get { payload["customerName"] as? String ?? "" }
        set { payload["customerName"] = newValue }
    }
    var email: String {
        get { payload["customerEmail"] as? String ?? "" }
        set { payload["customerEmail"] = newValue }
    }
    var description: String {
        get { payload["projectDescription"] as? String ?? "" }
        set { payload["projectDescription"] = newValue }
    }
    var lines: [[String: Any]] {
        get { payload["lineItems"] as? [[String: Any]] ?? [] }
        set { payload["lineItems"] = newValue }
    }
    init() { payload["creationRequestId"] = UUID().uuidString.lowercased() }
    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["draft", "estimate", "change-order", "invoice"].contains(object["estimateState"] as? String ?? ""), let id = object["id"] as? Int,
              let updated = object["updatedAt"] as? String else { throw APIError.conflict }
        self.id = id; payload = object
        payload["expectedUpdatedAt"] = updated; payload["draftOnly"] = object["estimateState"] as? String == "draft"
    }
    func encoded() throws -> Data {
        guard !customer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rate = decimal(payload["taxRate"]), rate >= 0, rate <= 100 else { throw APIError.invalidDraft }
        var body = payload
        body["lineItems"] = try lines.map { line in
            var result = line
            guard let q = decimal(line["quantity"]), q > 0,
                  let price = decimal(line["unitPrice"]), (price >= 0 || (["group","type"].contains(line["adjustmentKind"] as? String ?? "") && q == 1)) else { throw APIError.invalidDraft }
            var rawQuantity = q; var quantity = Decimal()
            var rawPrice = price; var unitPrice = Decimal()
            NSDecimalRound(&quantity, &rawQuantity, 2, .plain)
            NSDecimalRound(&unitPrice, &rawPrice, 2, .plain)
            guard quantity > 0 else { throw APIError.invalidDraft }
            result["quantity"] = NSDecimalNumber(decimal: quantity)
            result["unitPrice"] = NSDecimalNumber(decimal: unitPrice)
            var raw = quantity * unitPrice; var rounded = Decimal()
            NSDecimalRound(&rounded, &raw, 2, .plain)
            result["total"] = NSDecimalNumber(decimal: rounded)
            return result
        }
        body["taxRate"] = NSDecimalNumber(decimal: rate)
        // Identity and computed fields are never authored through this editor.
        let allowed: Set<String> = ["customerName", "customerEmail", "projectDescription", "taxRate", "lineItems", "expectedUpdatedAt", "draftOnly", "creationRequestId", "customerId", "clientSnapshot", "customerPhone", "serviceAddress", "serviceAddress2", "serviceCity", "serviceState", "serviceZipCode"]
        body = body.filter { allowed.contains($0.key) }
        body["nativeAuthoring"] = true
        body["draftOnly"] = id == nil || payload["estimateState"] as? String == "draft"
        if id == nil { body["estimateState"] = "draft" }
        return try JSONSerialization.data(withJSONObject: body)
    }
    private func decimal(_ value: Any?) -> Decimal? {
        if let value = value as? NSNumber { return value.decimalValue }
        if let value = value as? String { return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) }
        return nil
    }
}
extension APIClient {
    func draft(accessToken: String, membership: String, id: Int) async throws -> DraftEditor {
        let (data, status) = try await resource("estimates/\(id)", token: accessToken, membership: membership)
        try draftStatus(status)
        return try DraftEditor(data: data)
    }
    func saveDraft(accessToken: String, membership: String, draft: DraftEditor) async throws -> DraftEditor {
        let body = try draft.encoded()
        let path = draft.id.map { "estimates/\($0)" } ?? "estimates"
        let (data, status) = try await resource(path, token: accessToken, membership: membership,
                                               method: draft.id == nil ? "POST" : "PATCH", body: body)
        try draftStatus(status)
        return try DraftEditor(data: data)
    }
    private func draftStatus(_ status: Int) throws {
        if status == 409 { throw APIError.conflict }
        if status == 400 { throw APIError.invalidDraft }
        if status == 201 { return }
        try checkResourceStatus(status)
    }
}


struct NativeCustomer: Identifiable {
    let payload: [String: Any]
    var id: Int { payload["id"] as? Int ?? 0 }
    var name: String { payload["name"] as? String ?? payload["companyName"] as? String ?? "Customer" }
    var contacts: [[String: Any]] { payload["additionalContacts"] as? [[String: Any]] ?? [] }
}
struct NativeCustomerPage { let clients: [NativeCustomer]; let more: Bool }
extension APIClient {
    func customers(accessToken: String, membership: String, search: String, offset: Int) async throws -> NativeCustomerPage {
        let (data, status) = try await resource("clients", token: accessToken, membership: membership,
          query: [URLQueryItem(name: "searchTerm", value: search), URLQueryItem(name: "pageSize", value: "50"), URLQueryItem(name: "offset", value: String(offset))])
        try checkResourceStatus(status)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = result["clients"] as? [[String: Any]] else { throw APIError.invalidResponse }
        return NativeCustomerPage(clients: rows.map { NativeCustomer(payload: $0) }, more: result["hasMore"] as? Bool ?? false)
    }
}
extension DraftEditor {
    mutating func select(_ customer: NativeCustomer, contact: [String: Any]? = nil) {
        payload["customerId"] = String(customer.id)
        payload["clientSnapshot"] = customer.payload
        self.customer = customer.name
        email = contact?["email"] as? String ?? customer.payload["email"] as? String ?? ""
        payload["customerPhone"] = contact?["phone"] as? String ?? customer.payload["phoneMobile"] as? String ?? ""
        for field in ["serviceAddress", "serviceAddress2", "serviceCity", "serviceState", "serviceZipCode"] {
            let billing = field.replacingOccurrences(of: "service", with: "billing")
            payload[field] = customer.payload["billingEqualToService"] as? Bool == false ? customer.payload[field] : customer.payload[billing]
        }
    }
}


struct DocumentHistory: Decodable, Equatable {
    let date: String
    let changes: String
    let modifiedByName: String?
}
extension APIClient {
    func documentAction(accessToken: String, membership: String, id: Int, action: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        guard id > 0, ["send-email", "issue-invoice", "share-link", "revoke-links", "record-approval"].contains(action) else { throw APIError.invalidResponse }
        let (data, status) = try await resource("estimates/\(id)/\(action)", token: accessToken, membership: membership, method: "POST", body: JSONSerialization.data(withJSONObject: body))
        if status == 204 { return [:] }
        if status == 409 { throw APIError.conflict }
        if status == 400 || status == 502 { throw APIError.actionFailed }
        if status != 201 { try checkResourceStatus(status) }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.invalidResponse }
        return result
    }
}

// Operational resources retain server snapshots, while forms send only edited fields.
struct OperationRow: Identifiable {
    let value: [String: Any]
    var id: String { String(describing: value["id"] ?? value["workOrderId"] ?? "") }
    var title: String { value["name"] as? String ?? value["woNumber"] as? String ?? value["poNumber"] as? String ?? id }
    func text(_ key: String) -> String { value[key].map { $0 is NSNull ? "" : String(describing: $0) } ?? "" }
}
extension APIClient {
    func operation(_ path: String, token: String, membership: String, method: String = "GET", body: [String: Any]? = nil, providerKey: String? = nil) async throws -> Any {
        let target = URLComponents(string:path)
        let (data, status) = try await resource(target?.path ?? path, token: token, membership: membership, query: target?.queryItems ?? [], method: method, body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, providerKey: providerKey)
        if status == 400 || status == 415 || status == 422 { throw APIError.actionFailed }
        if status == 409 { throw APIError.conflict }
        if status != 201 && status != 204 { try checkResourceStatus(status) }
        if status == 204 { return [:] as [String: Any] }
        return try JSONSerialization.jsonObject(with: data)
    }
    static func operationRows(_ result: Any) throws -> [OperationRow] {
        if let rows = result as? [[String: Any]] { return rows.map { OperationRow(value: $0) } }
        guard let object = result as? [String: Any] else { throw APIError.invalidResponse }
        for key in ["items", "jobs", "workOrders", "purchaseOrders", "collections", "laborItems"] {
            if let rows = object[key] as? [[String: Any]] { return rows.map { OperationRow(value: $0) } }
        }
        throw APIError.invalidResponse
    }
}

struct PendingTaskPhoto {
    let data: Data
    let requestID: String
    init(jpeg: Data, requestID: String = UUID().uuidString.lowercased()) throws {
        guard !jpeg.isEmpty, jpeg.count <= 5 * 1024 * 1024 else { throw APIError.actionFailed }
        self.data = jpeg; self.requestID = requestID
    }
}
extension APIClient {
    func uploadTaskPhoto(token: String, membership: String, order: String, task: String, employee: Bool, photo: PendingTaskPhoto) async throws {
        let boundary = "EzBoss-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"task.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(photo.data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let path = employee ? "employee/work-orders/\(order)/tasks/\(task)/photos" : "work-orders/\(order)/tasks/\(task)/photos"
        let (_, status) = try await resource(path, token: token, membership: membership, method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)", idempotencyKey: photo.requestID)
        if status == 409 { throw APIError.conflict }
        if status != 201 { try checkResourceStatus(status) }
    }
}

extension APIClient {
    // Custom-provider traffic originates on the device; no arbitrary endpoint
    // is fetched by the application server and no EzBoss credential is attached.
    func customCollection(endpoint: String, providerKey: String, model: String, prompt: String, inventory: [String:Any]) async throws -> [String:Any] {
        guard var url = URLComponents(string:endpoint),url.scheme == "https",url.host != nil,url.user == nil,url.password == nil,url.query == nil,url.fragment == nil else { throw APIError.actionFailed }
        if !url.path.lowercased().hasSuffix("/chat/completions") { url.path = url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/chat/completions"; if !url.path.hasPrefix("/") { url.path = "/"+url.path } }
        guard let target = url.url else { throw APIError.actionFailed }
        let instruction = "Return only JSON with name, description, items. Each item has contentType (products/labor/tools/equipment), itemId (integer), quantity (positive whole number). Select only supplied IDs of the same contentType. Suggestions require human review."
        let content = String(data:try JSONSerialization.data(withJSONObject:["request":prompt,"inventory":inventory]),encoding:.utf8)!
        var request = URLRequest(url:target);request.httpMethod = "POST";request.timeoutInterval = 60
        request.setValue("Bearer \(providerKey)",forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["model":model,"max_tokens":3000,"messages":[["role":"system","content":instruction],["role":"user","content":content]]])
        let (data,response) = try await transportForCustomRequest(request)
        guard response == 200, data.count < 1_000_000,let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],let choices = object["choices"] as? [[String:Any]],let choice = choices.first,choice["finish_reason"] as? String != "length",let message = choice["message"] as? [String:Any],var text = message["content"] as? String else { throw APIError.actionFailed }
        text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("```json") { text = String(text.dropFirst(7)) } else if text.hasPrefix("```") { text = String(text.dropFirst(3)) }
        if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        guard let proposal = try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any] else { throw APIError.invalidResponse }
        return try nativeAIReview(proposal,inventory:inventory)
    }
}
func nativeAIReview(_ proposal:[String:Any],inventory:[String:Any]) throws -> [String:Any] {
    guard let name = proposal["name"] as? String,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count <= 200,let description = proposal["description"] as? String,description.count <= 5000,let items = proposal["items"] as? [[String:Any]],items.count <= 200 else { throw APIError.invalidResponse }
    var clean: [[String:Any]] = [], preview: [[String:Any]] = [],seen=Set<String>()
    for item in items {
        guard let kind=item["contentType"] as? String,["products","labor","tools","equipment"].contains(kind),let id=item["itemId"] as? Int,let quantity=item["quantity"] as? Int,quantity>0,quantity<=100000,let row=(inventory[kind] as? [[String:Any]])?.first(where:{($0["id"] as? Int)==id}),seen.insert("\(kind):\(id)").inserted else { throw APIError.invalidResponse }
        let value:[String:Any] = ["contentType":kind,"itemId":id,"quantity":quantity];clean.append(value)
        preview.append(value.merging(["name":row["name"] as? String ?? "Inventory"]){_,new in new})
    }
    return ["collection":["name":name,"description":description,"items":clean],"preview":preview]
}
