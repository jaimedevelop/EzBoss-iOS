import SwiftUI
import UIKit
import AVFoundation

@MainActor
final class BusinessModel: ObservableObject {
    @Published var memberships: [CompanyMembership] = []
    @Published var selected: String?
    @Published var loading = false
    @Published var error: String?
    private var generation = UUID()

    func load(_ session: Session, selecting: String? = nil) async {
        let request = UUID(); generation = request
        // Remove the old company's entire navigation tree before any await.
        selected = nil; error = nil; loading = true
        defer { if generation == request { loading = false } }
        do {
            let account = try await session.business { api, token in try await api.companies(accessToken: token, membership: selecting) }
            guard generation == request else { return }
            memberships = account.memberships
            selected = account.companyContext?.membershipId
        } catch is CancellationError { }
        catch {
            guard generation == request else { return }
            memberships = []
            self.error = (error as? APIError)?.message ?? "Company access could not be loaded. Check your connection and retry."
        }
    }
}

struct BusinessHome: View {
    @ObservedObject var session: Session
    let identity: Identity
    @StateObject private var model = BusinessModel()

    var body: some View {
        Group {
            if let membership = model.selected {
                CompanyHome(session: session, identity: identity, membership: membership, memberships: model.memberships, select: { id in
                    Task { await model.load(session, selecting: id) }
                }).id(membership)
            } else {
                NavigationStack {
                    List {
                        Section("Company access") {
                            if model.loading { ProgressView("Loading companies…") }
                            else if let error = model.error {
                                Text(error); Button("Retry") { Task { await model.load(session) } }
                            } else {
                                Text(model.memberships.isEmpty ? "No company is linked to this account. Contact your administrator." : "Select a company to continue.")
                                ForEach(model.memberships) { membership in
                                    Button(membership.companyName ?? "Company") { Task { await model.load(session, selecting: membership.id) } }
                                        .disabled(!membership.available)
                                }
                            }
                        }
                        NavigationLink("Account requests and terms") { NativeAccountLifecycle(session:session,membership:"") }
                        Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                    }.navigationTitle("EzBoss")
                }
            }
        }.task { await model.load(session) }
    }
}

private struct CompanyHome: View {
    @ObservedObject var session: Session
    let identity: Identity
    let membership: String
    let memberships: [CompanyMembership]
    let select: (String) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Welcome, \(identity.displayName ?? "User")").font(.title2.bold())
                    Text(memberships.first { $0.id == membership }?.companyName ?? "Company")
                    Menu("Switch company") {
                        ForEach(memberships.filter(\.available)) { company in
                            Button(company.companyName ?? "Company") { select(company.id) }
                        }
                    }
                }
                Section("Business documents") {
                    NavigationLink("Create estimate draft") { DraftEditorView(session: session, membership: membership, id: nil) }
                    NavigationLink("Estimates") { DocumentBrowser(session: session, membership: membership, initialKind: "estimate") }
                    NavigationLink("Invoices") { DocumentBrowser(session: session, membership: membership, initialKind: "invoice") }
                    NavigationLink("All documents") { DocumentBrowser(session: session, membership: membership, initialKind: "") }
                }
                Section("Recent documents") {
                    DocumentResults(session: session, membership: membership, search: "", kind: nil, dashboard: true)
                }
                Section("Operations") {
                    NavigationLink("Projects") { NativeBusinessRecords(session:session,membership:membership,project:true) }
                    NavigationLink("Finance") { NativeBusinessRecords(session:session,membership:membership,project:false) }
                    NavigationLink("AI collection assistant") { NativeAICollectionView(session:session,membership:membership) }
                    ForEach(OperationalModule.allCases) { module in
                        NavigationLink(module.title) { OperationalBrowser(session: session, membership: membership, module: module) }
                    }
                }
                Section("Account") {
                    NavigationLink("Account requests and terms") { NativeAccountLifecycle(session: session, membership: membership) }
                    NavigationLink("Company invitations") { NativeInvitations(session:session,membership:membership) }
                    NavigationLink("People") { NativePeopleSettings(session: session, membership: membership, settings: false) }
                    NavigationLink("Profile and preferences") { NativePeopleSettings(session: session, membership: membership, settings: true) }
                    LabeledContent("Role", value: identity.roleName ?? "Not assigned")
                    Button("Refresh account access") { Task { await session.restore() } }
                    Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                }
            }.navigationTitle("Dashboard")
        }
    }
}

private struct DocumentBrowser: View {
    @ObservedObject var session: Session
    let membership: String
    let initialKind: String
    @State private var search = ""
    @State private var kind: String
    init(session: Session, membership: String, initialKind: String) {
        self.session = session; self.membership = membership; self.initialKind = initialKind
        _kind = State(initialValue: initialKind)
    }
    var body: some View {
        List {
            Picker("Document type", selection: $kind) {
                Text("All").tag(""); Text("Estimate").tag("estimate"); Text("Draft").tag("draft")
                Text("Invoice").tag("invoice"); Text("Change order").tag("change-order")
            }
            DocumentResults(session: session, membership: membership, search: search, kind: kind.isEmpty ? nil : kind, dashboard: false)
        }
        .searchable(text: $search, prompt: "Customer name")
        .navigationTitle("Documents")
    }
}

@MainActor
private final class DocumentListModel: ObservableObject {
    @Published var rows: [Document] = []
    @Published var loading = false
    @Published var error: String?
    @Published var more = false
    private var offset = 0
    private var generation = UUID()
    func load(_ session: Session, membership: String, search: String, kind: String?, reset: Bool) async {
        if !reset && loading { return }
        let request = UUID(); generation = request
        if reset { rows = []; offset = 0; more = false }
        error = nil; loading = true
        defer { if generation == request { loading = false } }
        let next = offset
        do {
            if reset { try await Task.sleep(for: .milliseconds(250)) }
            let page = try await session.business { api, token in
                try await api.documents(accessToken: token, membership: membership, search: search, kind: kind, offset: next)
            }
            guard generation == request else { return }
            offset = next + page.count
            for row in page where !rows.contains(where: { $0.id == row.id }) { rows.append(row) }
            more = page.count == 25
        } catch is CancellationError { }
        catch {
            guard generation == request else { return }
            // A permission failure must remove even previously loaded protected rows.
            if let apiError = error as? APIError, [.accessDenied, .expiredSession, .companySelection].contains(apiError) { rows = []; more = false }
            self.error = (error as? APIError)?.message ?? "Documents could not be loaded. Check your connection and retry."
        }
    }
}

private struct DocumentResults: View {
    @ObservedObject var session: Session
    let membership: String
    let search: String
    let kind: String?
    let dashboard: Bool
    @StateObject private var model = DocumentListModel()
    private var query: String { membership + "|" + search + "|" + (kind ?? "") }
    var body: some View {
        Group {
            ForEach(dashboard ? Array(model.rows.prefix(5)) : model.rows) { document in
                NavigationLink {
                    DocumentDetail(session: session, membership: membership, id: document.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.number).font(.headline)
                        Text(document.customerName ?? "Customer")
                        Text("\(document.estimateState.capitalized) · \(document.clientState ?? "Not sent")").font(.caption).foregroundStyle(.secondary)
                        Text(amount(document.total))
                    }
                }
            }
            if model.loading { ProgressView("Loading documents…") }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
                Button("Retry documents") { Task { await load(reset: model.rows.isEmpty) } }
            } else if model.rows.isEmpty && !model.loading { Text("No matching documents.").foregroundStyle(.secondary) }
            if model.more && !dashboard { Button("Load more") { Task { await load(reset: false) } }.disabled(model.loading) }
            Button("Refresh documents") { Task { await load(reset: true) } }.disabled(model.loading)
        }
        .task(id: query) { await load(reset: true) }
    }
    private func load(reset: Bool) async { await model.load(session, membership: membership, search: search, kind: kind, reset: reset) }
}

private struct DocumentDetail: View {
    @ObservedObject var session: Session
    let membership: String
    let id: Int
    @State private var document: Document?
    @State private var error: String?
    @State private var loading = false
    @State private var acting = false
    @State private var approver = ""
    @State private var approvalReason = ""
    @State private var approvalDate = ""
    @State private var actionMessage: String?
    @State private var customerURL: URL?
    @State private var revokeWarning = false
    var body: some View {
        List {
            if loading { ProgressView("Loading document…") }
            if let error { Text(error); Button("Retry") { Task { await load() } } }
            if let document {
                Section(document.number) {
                    if !loading {
                        NavigationLink("Edit document") { DraftEditorView(session: session, membership: membership, id: document.id) }
                    }
                    Text(document.customerName ?? "Customer")
                    LabeledContent("Type", value: document.estimateState.capitalized)
                    LabeledContent("Client status", value: document.clientState ?? "Not sent")
                    if let description = document.projectDescription, !description.isEmpty { Text(description) }
                    if let date = document.validUntil { LabeledContent("Valid until", value: date) }
                }
                Section("Document actions") {
                    if document.collectionHold == true { Text("Collection is on hold pending approval of revision \(document.currentRevision ?? 0).").foregroundStyle(.orange) }
                    Button("Send / resend email") { Task { await act("send-email") } }
                    Button("Prepare customer link / checkout") { Task { await act("share-link") } }
                    if let customerURL { Link("Open customer view / checkout", destination: customerURL); ShareLink(item: customerURL) }
                    if document.estimateState == "draft" || document.estimateState == "estimate" { Button("Issue linked invoice") { Task { await act("issue-invoice") } } }
                    Button("Revoke customer links", role: .destructive) { revokeWarning = true }
                    if let actionMessage { Text(actionMessage) }
                    if acting { ProgressView() }
                }.disabled(acting)
                if (document.collectionHold == true || document.clientState != "accepted") && document.estimateState != "invoice" {
                    Section("Record off-app client approval") {
                        TextField("Client approver name", text: $approver)
                        TextField("Edit reason and approval evidence", text: $approvalReason, axis: .vertical)
                        TextField("Approval date (YYYY-MM-DD)", text: $approvalDate)
                        Button("Record approval") { Task { await act("record-approval", body: ["expectedRevision": document.currentRevision ?? 0, "approverName": approver, "reason": approvalReason, "approvalDate": approvalDate]) } }
                          .disabled(acting || approver.isEmpty || approvalReason.isEmpty || approvalDate.isEmpty)
                    }
                }
                Section("History") {
                    ForEach(Array((document.revisionsHistory ?? []).enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading) { Text(event.changes); Text("\(event.modifiedByName ?? "Actor recorded") · \(event.date)").font(.caption) }
                    }
                }
                Section("Line items") {
                    ForEach(document.lineItems ?? []) { line in
                        VStack(alignment: .leading) {
                            Text(line.name ?? line.description ?? "Item")
                            if let description = line.description { Text(description).foregroundStyle(.secondary) }
                            if let quantity = line.quantity { Text("Quantity: \(quantity.description)") }
                            Text(amount(line.total))
                        }
                    }
                    if document.lineItems?.isEmpty != false { Text("No line items.") }
                }
                Section("Totals") {
                    LabeledContent("Subtotal", value: amount(document.subtotal))
                    LabeledContent("Tax", value: amount(document.tax))
                    LabeledContent("Total", value: amount(document.total))
                    Text("Amounts use the document's stored numeric values. Currency is not supplied by this document contract.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(document?.number ?? "Document")
            .confirmationDialog("Revoke all existing customer links?", isPresented: $revokeWarning) {
                Button("Revoke links", role: .destructive) { Task { await act("revoke-links") } }
            }
            .task { await load() }
            .refreshable { await load() }
            .toolbar { Button("Refresh") { Task { await load() } }.disabled(loading) }
    }
    private func act(_ action: String, body: [String: Any] = [:]) async {
        guard !acting else { return }
        acting = true; actionMessage = nil; customerURL = nil
        defer { acting = false }
        do {
            let result = try await session.business { api, token in try await api.documentAction(accessToken: token, membership: membership, id: id, action: action, body: body) }
            if action == "share-link", let value = result["url"] as? String { customerURL = URL(string: value) }
            actionMessage = action == "send-email" ? "Email accepted for delivery. Inbox receipt still needs verification." : action == "issue-invoice" ? "Linked invoice created. Open it from Invoices." : action == "revoke-links" ? "Customer links revoked." : action == "record-approval" ? "Client approval recorded. Refresh to verify collection status." : "Customer link ready."
            if action == "record-approval" { approver = ""; approvalReason = ""; approvalDate = "" }
            await load()
        } catch { actionMessage = (error as? APIError)?.message ?? "The action was not confirmed. Refresh before retrying." }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; document = nil; error = nil
        defer { loading = false }
        do { document = try await session.business { api, token in try await api.document(accessToken: token, membership: membership, id: id) } }
        catch is CancellationError { }
        catch { self.error = (error as? APIError)?.message ?? "Document could not be loaded. Check your connection and retry." }
    }
}

private func amount(_ value: Decimal?) -> String {
    guard let value else { return "Amount unavailable" }
    return value.formatted(.number.precision(.fractionLength(2)))
}


private struct DraftEditorView: View {
    @ObservedObject var session: Session
    let membership: String
    let id: Int?
    @State private var draft = DraftEditor()
    @State private var busy = false
    @State private var ready = false
    @State private var error: String?
    @State private var saved = false
    @State private var reloadWarning = false
    @State private var showCustomers = false
    @State private var importingCollection = false
    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if saved { Text("Saved. Reopen the document to verify totals and approval status.").foregroundStyle(.green) }
            if ready {
                Section("Customer") {
                    Button("Select saved client or contact") { showCustomers = true }
                    TextField("Customer name", text: $draft.customer)
                    TextField("Email (optional)", text: $draft.email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    TextField("Scope description", text: $draft.description, axis: .vertical)
                    TextField("Tax percent", text: Binding(get: { String(describing: draft.payload["taxRate"] ?? 0) }, set: { draft.payload["taxRate"] = $0 })).keyboardType(.decimalPad)
                }
                Section("Line items") {
                    ForEach(draft.lines.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            TextField("Description", text: line(index, "description"))
                            TextField("Quantity", text: line(index, "quantity")).keyboardType(.decimalPad)
                            TextField("Unit price (negative for discount)", text: line(index, "unitPrice")).keyboardType(.numbersAndPunctuation)
                            Button("Remove line", role: .destructive) { draft.lines.remove(at: index) }
                        }
                    }
                    Button("Add discount / surcharge (negative for discount)") { draft.lines.append(["description":"Discount / surcharge","type":"custom","quantity":1,"unitPrice":0,"adjustmentKind":"group"]) }
                    Button("Import collection") { importingCollection = true }
                    Button("Add manual line") { draft.lines.append(["description": "", "quantity": 1, "unitPrice": 0, "type": "manual"]) }
                }
                Button(busy ? "Saving…" : "Save document") { Task { await save() } }.disabled(busy)
            }
            if busy { ProgressView() }
            if id != nil {
                Button("Reload stored draft") { reloadWarning = true }.disabled(busy)
            }
        }
        .disabled(busy)
        .sheet(isPresented: $importingCollection) { NativeCollectionImportPicker(session: session,membership: membership) { lines in draft.lines.append(contentsOf:lines); importingCollection = false; saved = false } }
        .sheet(isPresented: $showCustomers) {
            CustomerPicker(session: session, membership: membership) { customer, contact in
                draft.select(customer, contact: contact); saved = false; showCustomers = false
            }
        }
        .navigationTitle(id == nil ? "Estimate draft" : "Edit document")
        .onChange(of: draft.customer) { _, _ in saved = false }
        .confirmationDialog("Discard local edits and reload?", isPresented: $reloadWarning) {
            Button("Discard edits and reload", role: .destructive) { Task { await load() } }
        }
        .task { if !ready { await load() } }
    }
    private func line(_ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { String(describing: draft.lines[index][key] ?? "") }, set: { draft.lines[index][key] = $0; saved = false })
    }
    private func load() async {
        busy = true; error = nil; saved = false
        defer { busy = false }
        guard let id else { ready = true; return }
        do { draft = try await session.business { api, token in try await api.draft(accessToken: token, membership: membership, id: id) }; ready = true }
        catch { self.error = (error as? APIError)?.message ?? "Could not load draft. Retry when connected." }
    }
    private func save() async {
        busy = true; error = nil; saved = false
        defer { busy = false }
        do {
            let value = draft
            draft = try await session.business { api, token in try await api.saveDraft(accessToken: token, membership: membership, draft: value) }
            saved = true
        } catch { self.error = (error as? APIError)?.message ?? "Save was not confirmed. Your edits are preserved. Reopen the document before retrying an uncertain create." }
    }
}


private struct CustomerPicker: View {
    @ObservedObject var session: Session
    let membership: String
    let select: (NativeCustomer, [String: Any]?) -> Void
    @State private var search = ""
    @State private var rows: [NativeCustomer] = []
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { row in
                    Button(row.name) { select(row, nil) }
                    ForEach(row.contacts.indices, id: \.self) { index in
                        Button("\(row.name) — \(row.contacts[index]["name"] as? String ?? "Contact")") { select(row, row.contacts[index]) }
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error) }
                if !busy && rows.isEmpty { Text("No matching clients.") }
                Button("Search / retry") { Task { await load(reset: true) } }.disabled(busy)
                if more { Button("Load more") { Task { await load(reset: false) } }.disabled(busy) }
            }.navigationTitle("Select client")
             .searchable(text: $search)
             .task { await load(reset: true) }
        }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        if reset { rows = []; more = false }
        let query = search, offset = rows.count
        do {
            let page = try await session.business { api, token in try await api.customers(accessToken: token, membership: membership, search: query, offset: offset) }
            rows.append(contentsOf: page.clients.filter { row in !rows.contains { $0.id == row.id } }); more = page.more
        } catch { self.error = (error as? APIError)?.message ?? "Clients could not be loaded. Retry when connected." }
    }
}

private enum OperationalModule: String, CaseIterable, Identifiable {
    case products, labor, tools, equipment, collections, purchasing, workOrders, assignedJobs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workOrders: return "Work orders"
        case .assignedJobs: return "My assigned jobs"
        case .purchasing: return "Purchasing"
        default: return rawValue.capitalized
        }
    }
    var path: String {
        switch self {
        case .collections: return "collections"
        case .purchasing: return "purchase-orders"
        case .workOrders: return "work-orders"
        case .assignedJobs: return "employee/work-orders"
        default: return "inventory/\(rawValue)"
        }
    }
    var inventory: Bool { [.products,.labor,.tools,.equipment].contains(self) }
}

private struct OperationalBrowser: View {
    @ObservedObject var session: Session
    let membership: String
    let module: OperationalModule
    @State private var rows: [OperationRow] = []
    @State private var error: String?
    @State private var loading = false
    @State private var search = ""
    @State private var creating = false
    @State private var more = false
    var body: some View {
        List {
            if loading { ProgressView("Loading…") }
            if let error { Text(error).foregroundStyle(.red); Button("Retry") { Task { await load() } } }
            if rows.isEmpty && !loading && error == nil { Text("No items in this company.") }
            if more && !loading { Button("Load more") { Task { await load(reset:false) } } }
            ForEach(rows.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { row in
                NavigationLink {
                    OperationalDetail(session: session, membership: membership, module: module, id: row.id)
                } label: {
                    VStack(alignment: .leading) {
                        Text(row.title)
                        Text(row.text("status")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(module.title).searchable(text: $search)
        .toolbar {
            if module.inventory || module == .collections || module == .purchasing {
                Button("Create") { creating = true }
            }
        }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            NavigationStack { OperationalEditor(session: session, membership: membership, module: module, row: nil) }
        }
        .task { await load() }.refreshable { await load() }
    }
    private func load(reset:Bool = true) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let offset = reset ? 0 : rows.count
            let page = try await session.business { api, token in
                try APIClient.operationRows(await api.operation(module.path+(module == .purchasing ? "?limit=25&offset=\(offset)" : ""), token: token, membership: membership))
            }
            if reset { rows = page } else { rows.append(contentsOf:page.filter { item in !rows.contains { $0.id == item.id } }) }
            more = module == .purchasing && page.count == 25
        } catch { rows = []; more = false; self.error = (error as? APIError)?.message ?? "Unable to load. Check your connection and retry." }
    }
}

private struct OperationalEditor: View {
    @ObservedObject var session: Session
    let membership: String
    let module: OperationalModule
    let row: OperationRow?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var price = "0"
    @State private var vendor = ""
    @State private var quantity = "1"
    @State private var kind = "product"
    @State private var reference = ""
    @State private var inventory: [OperationRow] = []
    @State private var hierarchy: [String:String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString.lowercased()
    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.red) }
            if module == .purchasing {
                TextField("Supplier", text: $vendor)
                Picker("Inventory type", selection: $kind) { Text("Product").tag("product"); Text("Tool").tag("tool"); Text("Equipment").tag("equipment"); Text("Manual").tag("manual") }
                if kind != "manual" {
                    Picker("Inventory item", selection: $reference) {
                        Text("Select item").tag("")
                        ForEach(inventory) { Text($0.title).tag($0.id) }
                    }
                }
                TextField("Quantity", text: $quantity).keyboardType(.decimalPad)
            }
            if module != .purchasing || kind == "manual" { TextField("Name", text: $name) }
            TextField("Description", text: $description, axis: .vertical)
            if module.inventory {
                Section("Inventory hierarchy") {
                    ForEach(Array(["trade","section","category","subcategory","type"].prefix(module == .labor ? 3 : module == .products ? 5 : 4).enumerated()), id: \.offset) { index, level in
                        InventoryHierarchyField(session:session,membership:membership,module:module,level:level,parent:index == 0 ? "" : hierarchy[["trade","section","category","subcategory","type"][index-1]] ?? "",selection:Binding(get:{hierarchy[level] ?? ""},set:{value in
                            hierarchy[level] = value
                            for child in ["trade","section","category","subcategory","type"].dropFirst(index+1) { hierarchy[child] = "" }
                        }))
                    }
                }
            }
            if module.inventory || (module == .purchasing && kind == "manual") {
                TextField("Unit price", text: $price).keyboardType(.decimalPad)
            }
            Button("Save") { Task { await save() } }.disabled(busy)
            if busy { ProgressView("Waiting for confirmation…") }
        }
        .navigationTitle(row == nil ? "Create \(module.title)" : "Edit \(module.title)")
        .toolbar { Button("Cancel") { dismiss() }.disabled(busy) }
        .task {
            name = row?.text("name") ?? ""; description = row?.text("description") ?? ""
            price = row?.text([.equipment,.tools].contains(module) ? "minimumCustomerCharge" : "unitPrice") ?? "0"
            if module == .labor { price = String(describing:(row?.value["flatRates"] as? [[String:Any]])?.first?["rate"] ?? 0) }
            if price.isEmpty { price = "0" }
            for level in ["trade","section","category","subcategory","type"] { hierarchy[level] = row?.text(level+"Id") ?? "" }
        }
        .task(id: kind) {
            guard module == .purchasing && kind != "manual" else { return }
            reference = ""
            do {
                inventory = try await session.business { api, token in
                    try APIClient.operationRows(await api.operation("inventory/\(kind == "product" ? "products" : kind == "tool" ? "tools" : "equipment")", token: token, membership: membership))
                }
            } catch { self.error = "Inventory could not be loaded. Retry selecting the inventory type." }
        }
    }
    private func save() async {
        busy = true; error = nil; defer { busy = false }
        do {
            var body: [String: Any] = ["name": name, "description": description]
            if module == .collections { body["category"] = "General" }
            if module.inventory {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let money = Decimal(string: price), money >= 0 else { throw APIError.invalidDraft }
                for (level,id) in hierarchy { if let id = Int(id) { body[level+"Id"] = id } }
                if module == .labor {
                    var rates = row?.value["flatRates"] as? [[String:Any]] ?? []
                    if rates.isEmpty { rates.append(["name":"Standard","rate":NSDecimalNumber(decimal:money)]) }
                    else { rates[0]["rate"] = NSDecimalNumber(decimal:money) }
                    body["flatRates"] = rates
                }
                if module == .products { body["unitPrice"] = NSDecimalNumber(decimal: money) }
                if module == .equipment { body["minimumCustomerCharge"] = NSDecimalNumber(decimal: money); if row == nil { body["equipmentType"] = "owned"; body["status"] = "available" } }
                if module == .tools { body["minimumCustomerCharge"] = NSDecimalNumber(decimal: money) }
            }
            if module == .purchasing {
                guard let q = Double(quantity), q.isFinite, q > 0 else { throw APIError.invalidDraft }
                var line: [String: Any] = ["itemType": kind, "quantity": q]
                if kind == "manual" {
                    guard let amount = Double(price), amount.isFinite, amount >= 0 else { throw APIError.invalidDraft }
                    line["name"] = name; line["unitPrice"] = amount
                } else {
                    guard let id = Int(reference), id > 0 else { throw APIError.invalidDraft }; line["itemId"] = id
                }
                body = ["vendor": vendor, "notes": description, "idempotencyKey": requestID, "lineItems": [line]]
            }
            let payload = body
            _ = try await session.business { api, token in
                try await api.operation(module.path + (row.map { "/\($0.id)" } ?? ""), token: token, membership: membership, method: row == nil ? "POST" : "PATCH", body: payload)
            }
            dismiss()
        } catch { self.error = (error as? APIError)?.message ?? "Save was not confirmed. Your entries are preserved. Retry to confirm." }
    }
}

private struct OperationalDetail: View {
    @ObservedObject var session: Session
    let membership: String
    let module: OperationalModule
    let id: String
    @State private var row: OperationRow?
    @State private var busy = false
    @State private var error: String?
    @State private var editing = false
    @State private var delta = ""
    @State private var receiptQuantity = "1"
    @State private var receiptPrice = "0"
    @State private var supplier = ""
    @State private var requestID = UUID().uuidString.lowercased()
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if busy { ProgressView("Waiting for confirmation…") }
            Button("Refresh") { Task { await load() } }.disabled(busy)
            if let row {
                Text(row.title).font(.title2)
                ForEach(["description","status","onHand","assigned","total","actualTotal","serviceAddress","needsManagerReview","estimateUpdatedAt"], id: \.self) { key in
                    if !row.text(key).isEmpty { LabeledContent(key, value: row.text(key)) }
                }
                if module.inventory || module == .collections { Button("Edit") { editing = true } }
                if module.inventory || module == .collections {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                if module == .collections {
                    Button("Add / change inventory selection") { editingSelection = true }
                    ForEach(items(row,"itemSelections")) { item in Text("\(item.text("itemName")) × \(item.text("quantity"))") }
                }
                if module == .products {
                    TextField("Stock change (+ or −)", text: $delta).keyboardType(.numbersAndPunctuation)
                    Button("Apply stock change") {
                        guard let change = Double(delta), change.isFinite, change != 0 else { error = "Enter a nonzero stock change."; return }
                        Task { await action("adjust-stock", body: ["onHandChange": change,"requestId":requestID]); if error == nil { delta = "" } }
                    }
                }
                if module == .purchasing {
                    if row.text("status") == "draft" { Button("Submit order") { Task { await action("submit", body: ["version":row.value["version"] ?? 0]) } } }
                    if ["draft","ordered","partially_received"].contains(row.text("status")) { Button("Cancel order",role:.destructive) { Task { await action("cancel",body:["version":row.value["version"] ?? 0]) } } }
                    TextField("Actual supplier", text: $supplier)
                    TextField("Quantity received", text: $receiptQuantity).keyboardType(.decimalPad)
                    TextField("Actual unit price", text: $receiptPrice).keyboardType(.decimalPad)
                    ForEach(items(row,"lineItems")) { line in
                        Section(line.text("nameSnapshot").isEmpty ? line.title : line.text("nameSnapshot")) {
                            Text("Ordered \(line.text("quantity")); received \(line.text("quantityReceived"))")
                            if ["ordered","partially_received"].contains(row.text("status")) {
                                Button("Receive this line") {
                                    guard let q = Double(receiptQuantity), q.isFinite, q > 0, let p = Double(receiptPrice), p.isFinite, p >= 0 else { error = "Enter valid receipt amounts."; return }
                                    Task { await action("receipts",body:["idempotencyKey":requestID,"supplier":supplier,"items":[["itemId":line.id,"quantityReceived":q,"actualUnitPrice":p]]]) }
                                }
                            }
                        }
                    }
                }
                if module == .workOrders {
                    Button("Manage assignments and schedule") { managing = true }
                    Button("Approve work order") { Task { await action("approval",body:["version":row.value["version"] ?? 0]) } }
                    Button("Complete approved work order") { Task { await action("complete",body:["version":row.value["version"] ?? 0]) } }
                }
                if module == .workOrders || module == .assignedJobs {
                    ForEach(items(row,"appointments")) { appointment in Text("\(appointment.text("scheduledDate")) — \(appointment.text("timezone")) — \(appointment.text("status"))") }
                    ForEach(items(row,"tasks")) { task in
                        Section(task.title) {
                            Text(task.text("description"))
                            TaskPhotoCapture(session: session, membership: membership, order: id, task: task.id, employee: module == .assignedJobs) { Task { await load() } }
                            ForEach(items(task,"media")) { photo in
                                if let url = URL(string:photo.text("url")), url.scheme == "https" { Link("View private task photo",destination:url) }
                                else { Text("Photo unavailable. Refresh its access or complete private-storage migration.").font(.caption) }
                            }
                            Text(task.value["isCompleted"] as? Bool == true ? "Completed" : "Open")
                            Button("Complete task") { Task { await complete(task, order: row) } }.disabled(task.value["isCompleted"] as? Bool == true)
                        }
                    }
                    if module == .assignedJobs {
                        ForEach(["clock-in","start-break","end-break","start-lunch","end-lunch","clock-out"],id:\.self) { command in
                            Button(command.replacingOccurrences(of:"-",with:" ").capitalized) { Task { await action("attendance/\(command)") } }
                        }
                    }
                }
            }
        }
        .disabled(busy).navigationTitle(module.title)
        .sheet(isPresented:$editing,onDismiss:{ Task { await load() } }) { NavigationStack { OperationalEditor(session:session,membership:membership,module:module,row:row) } }
        .sheet(isPresented:$managing,onDismiss:{ Task { await load() } }) { if let row { NavigationStack { WorkOrderManagement(session:session,membership:membership,order:row) { managing = false } } } }
        .sheet(isPresented:$editingSelection,onDismiss:{ Task { await load() } }) { if let row { NavigationStack { CollectionSelectionEditor(session:session,membership:membership,collection:row) { editingSelection = false } } } }
        .confirmationDialog("Delete this item?",isPresented:$confirmingDelete) { Button("Delete",role:.destructive) { Task { await action("",method:"DELETE") } } }
        .task { await load() }
    }
    @State private var confirmingDelete = false
    @State private var editingSelection = false
    @State private var managing = false
    private func items(_ row: OperationRow,_ key: String) -> [OperationRow] { (row.value[key] as? [[String:Any]] ?? []).map { OperationRow(value:$0) } }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let result = try await session.business { api, token in try await api.operation("\(module.path)/\(id)",token:token,membership:membership) }
            guard let object = result as? [String:Any] else { throw APIError.invalidResponse }
            row = OperationRow(value: object["job"] as? [String:Any] ?? object); error = nil
        } catch { row = nil; self.error = (error as? APIError)?.message ?? "Could not load this item. Retry refresh." }
    }
    private func action(_ command:String, method:String = "POST", body:[String:Any] = [:]) async {
        busy = true; error = nil
        do {
            _ = try await session.business { api, token in try await api.operation("\(module.path)/\(id)" + (command.isEmpty ? "" : "/\(command)"),token:token,membership:membership,method:method,body:body) }
            requestID = UUID().uuidString.lowercased()
            if method == "DELETE" { row = nil } else { await load() }
        } catch { self.error = (error as? APIError)?.message ?? "Action was not confirmed. Refresh or retry." }
        busy = false
    }
    private func complete(_ task: OperationRow, order: OperationRow) async {
        if module == .assignedJobs { await action("tasks/\(task.id)/complete"); return }
        let tasks = items(order,"tasks").map { item -> [String:Any] in
            var value = item.value
            if item.id == task.id { value["isCompleted"] = true }
            return value
        }
        await action("",method:"PATCH",body:["version":order.value["version"] ?? 0,"tasks":tasks])
    }
}

private struct TaskPhotoCapture: View {
    @ObservedObject var session: Session
    let membership: String
    let order: String
    let task: String
    let employee: Bool
    let confirmed: () -> Void
    @State private var showingCamera = false
    @State private var pending: PendingTaskPhoto?
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading) {
            if let message { Text(message).font(.caption) }
            if let pending {
                Text("Photo ready for private upload")
                Button("Upload / retry photo") { Task { await upload(pending) } }.disabled(busy)
                Button("Discard photo",role:.destructive) { self.pending = nil }.disabled(busy)
            } else {
                Button("Take private task photo") { Task {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { message = "Camera unavailable on this device."; return }
                    let granted: Bool
                    if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { granted = true } else { granted = await AVCaptureDevice.requestAccess(for: .video) }
                    if granted { showingCamera = true } else { message = "Camera access denied. Enable camera access in Settings, then retry." }
                } }
            }
        }.sheet(isPresented: $showingCamera) {
            TaskCamera { image in
                showingCamera = false
                guard let image else { return }
                // Re-render pixels to remove location and camera metadata.
                let maxSide: CGFloat = 1600
                let scale = min(1, maxSide / max(image.size.width,image.size.height))
                let size = CGSize(width:image.size.width * scale,height:image.size.height * scale)
                let rendered = UIGraphicsImageRenderer(size:size).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
                guard let data = rendered.jpegData(compressionQuality:0.8), let photo = try? PendingTaskPhoto(jpeg:data) else { message = "Photo must be 5 MB or smaller. Retake it."; return }
                pending = photo; message = nil
            }
        }
    }
    private func upload(_ photo: PendingTaskPhoto) async {
        busy = true; defer { busy = false }
        do {
            try await session.business { api, token in try await api.uploadTaskPhoto(token:token,membership:membership,order:order,task:task,employee:employee,photo:photo) }
            pending = nil; message = "Private photo saved."; confirmed()
        } catch { message = "Upload not confirmed. The photo is kept here; retry uses the same request ID." }
    }
}
private struct TaskCamera: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(_ completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController,didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]) { completion(info[.originalImage] as? UIImage) }
    }
}

private struct CollectionSelectionEditor: View {
    @ObservedObject var session: Session
    let membership: String
    let collection: OperationRow
    let done: () -> Void
    @State private var kind = "products"
    @State private var selected = ""
    @State private var quantity = "1"
    @State private var rows: [OperationRow] = []
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.red) }
            Picker("Type",selection:$kind) { ForEach(["products","labor","tools","equipment"],id:\.self) { Text($0.capitalized).tag($0) } }
            Picker("Item",selection:$selected) {
                Text("Select inventory").tag("")
                ForEach(rows) { Text($0.title).tag($0.id) }
            }
            TextField("Whole quantity (0 removes selection)",text:$quantity).keyboardType(.numberPad)
            Button("Save selection") { Task {
                guard let item = Int(selected),let q = Int(quantity),q >= 0 else { error = "Select an item and a whole quantity.";return }
                busy = true; defer { busy = false }
                do {
                    _ = try await session.business { api,token in try await api.operation("collections/\(collection.id)/native-selection",token:token,membership:membership,method:"PUT",body:["contentType":kind,"itemId":item,"quantity":q,"expectedUpdatedAt":collection.text("updatedAt")]) }
                    done()
                } catch { self.error = (error as? APIError)?.message ?? "Selection was not confirmed. Reload the collection before retrying." }
            } }.disabled(busy)
        }.navigationTitle("Collection items")
         .task(id:kind) {
            selected = ""; rows = []
            do { rows = try await session.business { api,token in try APIClient.operationRows(await api.operation("inventory/\(kind)",token:token,membership:membership)) } }
            catch { self.error = "Inventory could not be loaded. Select the type again to retry." }
         }
    }
}

private struct NativeCollectionImportPicker: View {
    @ObservedObject var session: Session
    let membership: String
    let add: ([[String:Any]]) -> Void
    @State private var rows: [OperationRow] = []
    @State private var preview: [[String:Any]]?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView() }
                if let preview {
                    ForEach(preview.indices,id:\.self) { i in
                        Text("\(preview[i]["name"] as? String ?? "Item") — \(String(describing:preview[i]["quantity"] ?? 0)) × \(String(describing:preview[i]["unitPrice"] ?? 0))")
                    }
                    Button("Add reviewed lines to draft") { add(preview) }.disabled(preview.isEmpty || busy)
                    Button("Choose another collection") { self.preview = nil }
                } else {
                    ForEach(rows) { row in
                        Button(row.title) { Task {
                            busy = true; error = nil; defer { busy = false }
                            do {
                                let result = try await session.business { api,token in try await api.operation("collections/\(row.id)/import-preview",token:token,membership:membership) }
                                guard let object = result as? [String:Any],let lines = object["lineItems"] as? [[String:Any]] else { throw APIError.invalidResponse }
                                preview = lines
                            } catch { self.error = "Could not price this collection. Review its inventory and retry." }
                        } }.disabled(busy)
                    }
                    Button("Refresh / retry") { Task { await load() } }
                }
            }.navigationTitle("Import collection").task { await load() }
        }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do { rows = try await session.business { api,token in try APIClient.operationRows(await api.operation("collections",token:token,membership:membership)) }; error = nil }
        catch { self.error = "Collections could not be loaded. Retry." }
    }
}

private struct WorkOrderManagement: View {
    @ObservedObject var session: Session
    let membership: String
    let order: OperationRow
    let done: () -> Void
    @State private var employees: [OperationRow] = []
    @State private var workers: [OperationRow] = []
    @State private var date = ""
    @State private var timezone = TimeZone.current.identifier
    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.red) }
            if busy { ProgressView() }
            Section("Schedule day for assigned employees") {
                TextField("Date YYYY-MM-DD",text:$date)
                TextField("Timezone",text:$timezone).textInputAutocapitalization(.never)
                TextField("Scheduling reason",text:$reason)
                Button("Save job day") { Task { await command("schedule",body:["version":order.value["version"] ?? 0,"action":"save","reason":reason,"appointment":["scheduledDate":date,"timezone":timezone,"shifts":workers.map { ["assignmentId":$0.id,"scheduledDate":date] }]]) } }
            }
            Section("Assign employee") {
                ForEach(employees) { employee in Button(employee.title) { Task { await command("workers",body:["employeeIds":[Int(employee.id) ?? 0]]) } } }
            }
            Section("Assigned employees and tasks") {
                ForEach(workers) { worker in
                    Text(worker.text("displayName")).font(.headline)
                    ForEach((order.value["tasks"] as? [[String:Any]] ?? []).map { OperationRow(value:$0) }) { task in
                        let assigned = (worker.value["assignedTaskIds"] as? [String] ?? []).contains(task.id)
                        Button("\(assigned ? "Unassign" : "Assign") \(task.title)") {
                            Task { await command("workers/\(worker.id)/tasks",method:"PATCH",body:[assigned ? "removeTaskId" : "addTaskId":task.id]) }
                        }
                    }
                    Button("Remove employee from job",role:.destructive) { Task { await command("workers/\(worker.id)",method:"DELETE") } }
                }
            }
        }.disabled(busy).navigationTitle("Job management")
         .toolbar { Button("Done") { done() } }
         .task { await load() }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let people = try await session.business { api,token in try await api.operation("employees",token:token,membership:membership) }
            guard let groups = people as? [String:Any] else { throw APIError.invalidResponse }
            employees = groups.values.flatMap { $0 as? [[String:Any]] ?? [] }.map { OperationRow(value:$0) }
            let result = try await session.business { api,token in try await api.operation("work-orders/\(order.id)/workers",token:token,membership:membership) }
            workers = try APIClient.operationRows(result)
        } catch { self.error = "Employee access or assignment list could not be loaded. Reopen to retry." }
    }
    private func command(_ action:String,method:String="POST",body:[String:Any]=[:]) async {
        busy = true; defer { busy = false }
        do {
            _ = try await session.business { api,token in try await api.operation("work-orders/\(order.id)/\(action)",token:token,membership:membership,method:method,body:body) }
            done()
        } catch { self.error = (error as? APIError)?.message ?? "Action was not confirmed. Your entries are preserved." }
    }
}

private struct InventoryHierarchyField: View {
    @ObservedObject var session: Session
    let membership: String
    let module: OperationalModule
    let level: String
    let parent: String
    @Binding var selection: String
    @State private var rows: [OperationRow] = []
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        VStack(alignment:.leading) {
            Picker(level.capitalized,selection:$selection) {
                Text("Unspecified").tag("")
                ForEach(rows) { Text($0.title).tag($0.id) }
            }.disabled(level != "trade" && parent.isEmpty)
            if failed { Button("Retry \(level) list") { retry += 1 } }
        }.task(id:parent+String(retry)) {
            rows = []; failed = false
            guard level == "trade" || !parent.isEmpty else { return }
            let type = module == .products ? "product" : module == .tools ? "tool" : module == .equipment ? "equipment" : "labor"
            do { rows = try await session.business { api,token in try APIClient.operationRows(await api.operation("inventory/categories/hierarchy/\(level)?itemType=\(type)"+(parent.isEmpty ? "" : "&parentId=\(parent)"),token:token,membership:membership)) } }
            catch { failed = true }
        }
    }
}

private struct NativeAICollectionView: View {
    @ObservedObject var session: Session
    let membership: String
    @State private var provider = "openai"
    @State private var model = ""
    @State private var key = ""
    @State private var customEndpoint = ""
    @State private var customID = UUID().uuidString.lowercased()
    @State private var prompt = ""
    @State private var settings: [String:Any] = ["provider":"openai","modelId":"","customProviders":[],"customModels":[]]
    @State private var version = 0
    @State private var ready = false
    @State private var collection: [String:Any]?
    @State private var preview: [[String:Any]] = []
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Form {
            if let message { Text(message) }
            Text("Uses your provider account and may incur provider charges. The key is kept only on this screen and sent over HTTPS for this request. Review every suggestion before saving.").font(.caption)
            Picker("Provider",selection:$provider) { ForEach(["openai","anthropic","google","deepseek","custom"],id:\.self) { Text($0.capitalized).tag($0) } }
            if provider == "custom" { TextField("Custom HTTPS endpoint",text:$customEndpoint).textInputAutocapitalization(.never).autocorrectionDisabled() }
            TextField("Provider model name",text:$model).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Temporary provider key",text:$key).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save provider preferences") { Task { await saveSettings() } }.disabled(!ready || busy)
            TextField("Describe the collection you need",text:$prompt,axis:.vertical)
            Button("Generate suggestions") { Task { await generate() } }.disabled(busy || !ready || key.isEmpty || model.isEmpty || prompt.isEmpty)
            if busy { ProgressView("Waiting for confirmation…") }
            if collection != nil {
                Section("Review collection") {
                    TextField("Name",text:Binding(get:{collection?["name"] as? String ?? ""},set:{collection?["name"] = $0}))
                    TextField("Description",text:Binding(get:{collection?["description"] as? String ?? ""},set:{collection?["description"] = $0}),axis:.vertical)
                    ForEach(preview.indices,id:\.self) { index in Text("\(preview[index]["name"] as? String ?? "Inventory") × \(String(describing:preview[index]["quantity"] ?? 0))") }
                    Button("Save reviewed collection") { Task { await save() } }.disabled(busy)
                }
            }
        }.navigationTitle("AI collections")
         .task { await load() }
         .onChange(of:provider) { _,_ in key = "" }
    }
    private func load() async {
        do {
            let result = try await session.business { api,token in try await api.operation("collection-ai-settings",token:token,membership:membership) }
            if let record = result as? [String:Any] {
                version = record["version"] as? Int ?? 0
                if let stored = record["settings"] as? [String:Any] { settings = stored; if let selected = stored["provider"] as? String,["openai","anthropic","google","deepseek","custom"].contains(selected) { provider = selected }; model = stored["modelId"] as? String ?? ""; if provider == "custom" {
                    customID = stored["activeCustomProviderId"] as? String ?? customID
                    customEndpoint = (stored["customProviders"] as? [[String:Any]])?.first { $0["id"] as? String == customID }?["baseUrl"] as? String ?? ""
                    let prefix = "custom:"+customID+":"; if model.hasPrefix(prefix) { model = String(model.dropFirst(prefix.count)) }
                } else if model.hasPrefix(provider+":") { model = String(model.dropFirst(provider.count+1)) } }
            }
            ready = true
        } catch { message = "Provider preferences could not be loaded. Reopen to retry." }
    }
    private func saveSettings() async {
        busy = true; defer { busy = false }
        settings["provider"] = provider; settings["modelId"] = (provider == "custom" ? "custom:"+customID : provider)+":"+model
        if provider == "custom" {
            var providers = settings["customProviders"] as? [[String:Any]] ?? []
            var definition = providers.first(where:{$0["id"] as? String == customID}) ?? ["id":customID,"label":"Custom provider"]
            definition["baseUrl"] = customEndpoint
            if let index=providers.firstIndex(where:{$0["id"] as? String == customID}) { providers[index]=definition } else { providers.append(definition) }
            settings["customProviders"]=providers; settings["activeCustomProviderId"]=customID
        }
        do {
            let result = try await session.business { api,token in try await api.operation("collection-ai-settings",token:token,membership:membership,method:"PUT",body:["version":version,"settings":settings]) }
            version = (result as? [String:Any])?["version"] as? Int ?? version; message = "Provider preferences saved. The key was not stored."
        } catch { message = "Preferences were not saved. Reload if they changed elsewhere." }
    }
    private func generate() async {
        busy = true; message = nil; defer { busy = false }
        do {
            let result: Any
            if provider == "custom" {
                let context = try await session.business { api,token in try await api.operation("native-collection-ai/inventory",token:token,membership:membership) }
                guard let inventory=context as? [String:Any] else { throw APIError.invalidResponse }
                result = try await session.business { api,_ in try await api.customCollection(endpoint:customEndpoint,providerKey:key,model:model,prompt:prompt,inventory:inventory) }
            } else { result = try await session.business { api,token in try await api.operation("native-collection-ai/generate",token:token,membership:membership,method:"POST",body:["provider":provider,"model":model,"prompt":prompt],providerKey:key) } }
            guard let object = result as? [String:Any],let proposal = object["collection"] as? [String:Any],let rows = object["preview"] as? [[String:Any]] else { throw APIError.invalidResponse }
            collection = proposal; preview = rows; requestID = UUID().uuidString.lowercased()
        } catch { message = "Generation did not complete. Your prompt and previous review are preserved. Check provider/model and retry." }
    }
    private func save() async {
        guard let collection else { return }; busy = true; defer { busy = false }
        do {
            _ = try await session.business { api,token in try await api.operation("native-collection-ai/save",token:token,membership:membership,method:"POST",body:["requestId":requestID,"collection":collection]) }
            self.collection = nil; preview = []; message = "Collection saved. Open Collections to edit quantities or import it into a draft."
        } catch { message = "Save was not confirmed. Your review is preserved; retry uses the same save request." }
    }
}


private struct NativePeopleSettings: View {
    @ObservedObject var session: Session
    let membership: String
    let settings: Bool
    @State private var path = "clients"
    @State private var employeeProfile = false
    @State private var rows: [OperationRow] = []
    @State private var editing: OperationRow?
    @State private var values: [String:String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var search = ""
    private var endpoint: String { settings ? (employeeProfile ? "account/employee-profile" : "profile") : path }
    private var fields: [String] {
        if settings && employeeProfile { return ["name","phoneMobile","phoneOther","address","address2","city","state","zipCode","emergencyContactName","emergencyContactPhone"] }
        if settings { return ["firstName","lastName","phone","company","companyAddress","currency","timezone"] }
        if path == "employees" { return ["name","email","phoneMobile","employeeRole","hireDate","address","city","state","zipCode","emergencyContactName","emergencyContactPhone","notes"] }
        return ["name","email","phoneMobile","companyName","billingAddress","billingCity","billingState","billingZipCode","notes"]
    }
    var body: some View {
        Form {
            if settings { Toggle("My employee profile",isOn:$employeeProfile).disabled(busy) }
            if !settings { Picker("People",selection:$path) { Text("Clients").tag("clients"); Text("Employees").tag("employees") }.disabled(busy) }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let message { Text(message) }
            if let row = editing {
                ForEach(fields,id: \.self) { key in
                    TextField(key.replacingOccurrences(of: "([a-z])([A-Z])",with:"$1 $2",options:.regularExpression).capitalized,text:Binding(get:{values[key] ?? ""},set:{values[key]=$0})).disabled(busy)
                }
                if path == "employees" && !settings && !row.id.isEmpty {
                    let active = row.value["isActive"] as? Bool ?? true
                    Text(active ? "Account access: Active" : "Account access: Suspended")
                    Button(active ? "Suspend employee" : "Reactivate employee") { Task { await saveAccess(row,!active) } }.disabled(busy)
                }
                Button("Save") { Task { await save(row) } }.disabled(busy)
                Button("Discard / reload") { Task { await load() } }.disabled(busy)
            } else {
                Button("Refresh / retry") { Task { await load() } }.disabled(busy)
                if !settings {
                    Button(path == "clients" ? "Create client" : "Create employee") { editing=OperationRow(value:[:]);values=[:];message=nil }.disabled(busy)
                    TextField("Search",text:$search)
                    ForEach(rows.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { row in
                        Button(row.title) { editing=row;values=Dictionary(uniqueKeysWithValues:fields.map{($0,row.text($0))});message=nil }
                    }
                    if rows.isEmpty && !busy && error == nil { Text("No people in this company.") }
                }
            }
        }.navigationTitle(settings ? "Profile and preferences" : "People").task(id:endpoint) { await load() }
    }
    private func load() async {
        busy=true;error=nil;rows=[];editing=nil
        defer {busy=false}
        do {
            let result=try await session.business { api,token in try await api.operation(endpoint,token:token,membership:membership) }
            guard let object=result as? [String:Any] else { throw APIError.invalidResponse }
            if settings { let row=OperationRow(value:employeeProfile ? object["profile"] as? [String:Any] ?? [:] : object);editing=row;values=Dictionary(uniqueKeysWithValues:fields.map{($0,row.text($0))}) }
            else { rows=object.values.compactMap{$0 as? [[String:Any]]}.flatMap{$0}.map{OperationRow(value:$0)}.sorted{$0.title<$1.title} }
        } catch { self.error=(error as? APIError)?.message ?? "Could not load. Retry." }
    }
    private func save(_ row: OperationRow) async {
        busy=true;error=nil;message=nil
        do {
            let changed=fields.filter{row.id.isEmpty || values[$0,default:""] != row.text($0)}
            let body=Dictionary(uniqueKeysWithValues:changed.map{($0,values[$0,default:""] as Any)})
            _=try await session.business { api,token in try await api.operation(endpoint + (!settings && !row.id.isEmpty ? "/"+row.id : ""),token:token,membership:membership,method:settings || !row.id.isEmpty ? "PATCH":"POST",body:body) }
            message="Saved";await load()
        } catch { self.error=(error as? APIError)?.message ?? "Save was not confirmed. Check before retrying." }
        busy=false
    }
    private func saveAccess(_ row: OperationRow,_ active: Bool) async {
        busy=true;error=nil
        do {
            _=try await session.business { api,token in try await api.operation("employees/"+row.id,token:token,membership:membership,method:"PATCH",body:["isActive":active]) }
            message="Account access updated";await load()
        } catch { self.error=(error as? APIError)?.message ?? "Change was not confirmed. Retry." }
        busy=false
    }
}


private struct NativeAccountLifecycle: View {
    @ObservedObject var session: Session
    let membership: String
    @State private var data: [String:Any] = [:]
    @State private var confirmation = ""
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            Button("Refresh / retry") { Task { await load() } }.disabled(busy)
            Section("Terms") {
                if let document=data["document"] as? [String:Any],let version=document["version"] as? String,let hash=document["sha256"] as? String {
                    Text("Version: \(version)")
                    if let address=document["url"] as? String,let url=URL(string:address),url.scheme == "https" { Link("Read terms",destination:url) }
                    if document["accepted"] as? Bool == true { Text("Accepted") }
                    else { Button("I have read and accept these terms") { Task { await action("account/terms-acceptance",["version":version,"sha256":hash,"accepted":true]) } }.disabled(busy) }
                } else { Text("Reviewed terms have not been published yet.") }
            }
            Section("Account deletion request") {
                Text(data["notice"] as? String ?? "Loading account request information…")
                ForEach((data["requests"] as? [[String:Any]] ?? []).map{OperationRow(value:$0)}) { row in
                    Text(row.text("status"));Text(row.text("createdAt"));Text(row.text("reviewMessage"))
                    if ["requested","under_review","action_required"].contains(row.text("status")),let version=row.value["version"] as? Int {
                        Button("Cancel request",role:.destructive) { Task { await action("account/deletion-requests/"+row.id+"/cancel",["version":version]) } }.disabled(busy)
                    }
                }
                TextField("Type REQUEST DELETION",text:$confirmation).textInputAutocapitalization(.characters)
                Button("Submit for review",role:.destructive) { Task { await action("account/deletion-requests",["requestId":requestID,"confirmation":confirmation]) } }.disabled(busy || confirmation != "REQUEST DELETION" || data.isEmpty)
            }
        }.navigationTitle("Account requests").task { await load() }
    }
    private func load() async {
        busy=true;error=nil;defer{busy=false}
        do { data=try await session.business { api,token in try await api.operation("account/lifecycle",token:token,membership:membership) } as? [String:Any] ?? [:] }
        catch { data=[:];self.error=(error as? APIError)?.message ?? "Unable to load. Retry." }
    }
    private func action(_ path: String,_ body: [String:Any]) async {
        busy=true;error=nil
        do {
            _=try await session.business { api,token in try await api.operation(path,token:token,membership:membership,method:"POST",body:body) }
            confirmation="";requestID=UUID().uuidString.lowercased();await load()
        } catch { self.error=(error as? APIError)?.message ?? "Request was not confirmed. Refresh status before retrying." }
        busy=false
    }
}


private struct NativeBusinessRecords: View {
    @ObservedObject var session: Session
    let membership: String
    let project: Bool
    @State private var rows: [OperationRow] = []
    @State private var clients: [OperationRow] = []
    @State private var selected: OperationRow?
    @State private var values: [String:String] = [:]
    @State private var clientID = ""
    @State private var status = "planning"
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    private var path: String { project ? "projects" : "finance-records" }
    private var projectKeys: [String] { ["name","startDate","estimatedEndDate","description","notes"] }
    private var addressKeys: [String] { ["address","address2","city","state","zipCode"] }
    private var financeKeys: [String] { ["date","estimate","poNumber","invoice","invoiceValue","payment","paymentMethod","paymentDate","serviceAddress","jobCompletionDate","completedFor","agent"] }
    private var fields: [String] { project ? projectKeys+addressKeys : financeKeys }
    var body: some View {
        Form {
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let message { Text(message) }
            if let row=selected {
                if project {
                    Picker("Client",selection:$clientID) { Text("Select client").tag("");ForEach(clients){Text($0.title).tag($0.id)} }.disabled(busy)
                    Picker("Status",selection:$status) { ForEach(["planning","active","on-hold","completed","invoiced","cancelled"],id: \.self){Text($0).tag($0)} }.disabled(busy)
                } else {
                    if let summary=row.value["paymentSummary"] as? [String:Any] { Text("Ledger: \(summary["paid"] ?? "") / \(summary["total"] ?? "") · \(summary["status"] ?? "")") }
                    Text("Manual record fields do not alter the invoice payment ledger. Record payments or refunds on the document.")
                }
                ForEach(fields,id: \.self){key in TextField(key.replacingOccurrences(of:"([a-z])([A-Z])",with:"$1 $2",options:.regularExpression).capitalized,text:Binding(get:{values[key,default:""]},set:{values[key]=$0})).disabled(busy)}
                Button("Save") { Task { await save(row) } }.disabled(busy)
                Button("Discard / reload") { Task { await load() } }.disabled(busy)
            } else {
                Button("Refresh / retry") { Task { await load() } }.disabled(busy)
                Button(project ? "Create project" : "Create manual record") { edit(OperationRow(value:project ? [:] : ["id":UUID().uuidString.lowercased(),"data":[:]])) }.disabled(busy)
                ForEach(rows) {row in Button(project ? row.title : ((row.value["data"] as? [String:Any])?["invoice"] as? String ?? row.id)) {edit(row)} }
                if rows.isEmpty && !busy && error == nil { Text("No records in this company.") }
            }
        }.navigationTitle(project ? "Projects" : "Finance").task { await load() }
    }
    private func edit(_ row: OperationRow) {
        selected=row;message=nil;clientID=row.text("clientId");status=row.text("status").isEmpty ? "planning" : row.text("status")
        let data=project ? row.value : row.value["data"] as? [String:Any] ?? [:]
        let address=row.value["serviceAddress"] as? [String:Any] ?? [:]
        values=Dictionary(uniqueKeysWithValues:fields.map{key in (key,OperationRow(value:project && addressKeys.contains(key) ? address : data).text(key))})
    }
    private func load() async {
        busy=true;error=nil;rows=[];selected=nil;defer{busy=false}
        do {
            rows=try await session.business { api,token in try APIClient.operationRows(await api.operation(path,token:token,membership:membership)) }
            if project { let result=try await session.business { api,token in try await api.operation("clients",token:token,membership:membership) };clients=(result as? [String:Any] ?? [:]).values.compactMap{$0 as? [[String:Any]]}.flatMap{$0}.map{OperationRow(value:$0)} }
        } catch { self.error=(error as? APIError)?.message ?? "Unable to load. Retry." }
    }
    private func save(_ row: OperationRow) async {
        busy=true;error=nil;message=nil
        do {
            var body: [String:Any]=[:];var target=path;var method="POST"
            if project {
                for key in projectKeys {body[key]=values[key,default:""]};body["serviceAddress"]=Dictionary(uniqueKeysWithValues:addressKeys.map{($0,values[$0,default:""])});body["clientId"]=clientID;body["status"]=status
                if !row.id.isEmpty { body["version"]=row.value["version"];target += "/"+row.id;method="PATCH" }
            } else {
                let data=Dictionary(uniqueKeysWithValues:financeKeys.map{($0,values[$0,default:""])})
                if let version=row.value["version"] {body=["version":version,"data":data];target += "/"+row.id;method="PUT"}
                else {body=["records":[["id":row.id,"data":data]]]}
            }
            _=try await session.business {api,token in try await api.operation(target,token:token,membership:membership,method:method,body:body)}
            message="Saved";await load()
        } catch { self.error=(error as? APIError)?.message ?? "Save was not confirmed. Reload before retrying." }
        busy=false
    }
}


private struct NativeInvitations: View {
    @ObservedObject var session: Session
    let membership: String
    @State private var positions: [OperationRow] = []
    @State private var invitations: [OperationRow] = []
    @State private var email = ""
    @State private var position = ""
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    var body: some View {
        Form {
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let message { Text(message) }
            Button("Refresh / retry") { Task { await load() } }.disabled(busy)
            TextField("Employee email",text:$email).textInputAutocapitalization(.never).keyboardType(.emailAddress).disabled(busy)
            Picker("Position",selection:$position) { Text("Select position").tag("");ForEach(positions){Text($0.title).tag($0.id)} }.disabled(busy)
            Button("Send invitation email") { Task { await action("employee-account-invitations",["requestId":requestID,"email":email.trimmingCharacters(in:.whitespacesAndNewlines),"positionId":position,"delivery":"email"]) } }.disabled(busy || email.isEmpty || position.isEmpty)
            ForEach(invitations) { row in
                Text(row.text("email"));Text("Delivery: "+row.text("deliveryStatus")+" · "+row.text("status"))
                if row.text("acceptedAt").isEmpty && row.text("revokedAt").isEmpty {
                    Button("Resend invitation") { Task { await action("employee-account-invitations/"+row.id+"/resend",[:]) } }.disabled(busy)
                    Button("Revoke invitation",role:.destructive) { Task { await action("employee-account-invitations/"+row.id+"/revoke",[:]) } }.disabled(busy)
                }
            }
        }.navigationTitle("Company invitations").task { await load() }
    }
    private func load() async {
        busy=true;error=nil;positions=[];invitations=[];defer{busy=false}
        do {
            let p=try await session.business {api,token in try await api.operation("account/positions",token:token,membership:membership)} as? [String:Any] ?? [:]
            positions=(p["positions"] as? [[String:Any]] ?? []).map{OperationRow(value:$0)}
            let i=try await session.business {api,token in try await api.operation("employee-account-invitations",token:token,membership:membership)} as? [String:Any] ?? [:]
            invitations=(i["invitations"] as? [[String:Any]] ?? []).map{OperationRow(value:$0)}
        } catch {self.error=(error as? APIError)?.message ?? "Unable to load. Retry."}
    }
    private func action(_ path:String,_ body:[String:Any]) async {
        busy=true;error=nil;message=nil
        do {
            let result=try await session.business {api,token in try await api.operation(path,token:token,membership:membership,method:"POST",body:body)} as? [String:Any] ?? [:]
            message=result["replayed"] as? Bool == true ? "Existing request found. Check delivery status; resend if needed." : "Request recorded. Check delivery status."
            email="";requestID=UUID().uuidString.lowercased();await load()
        }catch{self.error=(error as? APIError)?.message ?? "Delivery was not confirmed. Refresh status before retrying."}
        busy=false
    }
}
