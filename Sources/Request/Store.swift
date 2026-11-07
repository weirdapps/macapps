import AppKit
import Kit
import SwiftUI

enum SidebarItem: Hashable {
    case request(UUID)
    case history(UUID)
}

enum EditorTab: String, CaseIterable { case params = "Params", headers = "Headers", body = "Body" }
enum ResponseTab: String, CaseIterable { case pretty = "Pretty", raw = "Raw", headers = "Headers" }

enum ResponseState: Equatable {
    case idle
    case loading
    case done(HTTPResult)
    case failed(String)
}

@MainActor
final class Store: ObservableObject {
    @Published var workspace: Workspace { didSet { scheduleSave() } }
    @Published var history: [HistoryEntry] { didSet { scheduleSave() } }
    @Published var selection: SidebarItem?
    @Published var responses: [SidebarItem: ResponseState] = [:]
    @Published var editorTab: EditorTab = .params
    @Published var responseTab: ResponseTab = .pretty
    @Published var showEnvironments = false
    @Published var renaming: UUID?
    @Published var savedResponse: URL?
    @Published var copied = false

    private let persists: Bool
    private var saveTask: Task<Void, Never>?
    private var sendTasks: [SidebarItem: Task<Void, Never>] = [:]

    init(workspace: Workspace, history: [HistoryEntry], persists: Bool) {
        self.workspace = workspace
        self.history = history
        self.persists = persists
        selection = workspace.collections.first?.requests.first.map { .request($0.id) }
        if persists {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveNow() }
            }
        }
    }

    /// The user's saved workspace and history, or the starter examples on first launch.
    static func load() -> Store {
        let ws = Storage.load(Workspace.self, app: "Request", file: "workspace.json") ?? Samples.starter
        let history = Storage.load([HistoryEntry].self, app: "Request", file: "history.json") ?? []
        return Store(workspace: ws, history: history, persists: true)
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard persists else { return }
        Storage.save(workspace, app: "Request", file: "workspace.json")
        Storage.save(history, app: "Request", file: "history.json")
    }

    // MARK: Environment

    var activeEnvironment: RequestEnvironment? {
        workspace.environments.first { $0.id == workspace.activeEnvironment }
    }

    var variables: [String: String] { activeEnvironment?.values ?? [:] }

    // MARK: Current request

    var current: APIRequest? {
        switch selection {
        case .request(let id): workspace.collections.lazy.flatMap(\.requests).first { $0.id == id }
        case .history(let id): history.first { $0.id == id }?.request
        case nil: nil
        }
    }

    var currentCollection: RequestCollection? {
        guard case .request(let id) = selection else { return nil }
        return workspace.collections.first { $0.requests.contains { $0.id == id } }
    }

    var currentHistory: HistoryEntry? {
        guard case .history(let id) = selection else { return nil }
        return history.first { $0.id == id }
    }

    /// A binding to the selected request, saved or from history.
    var currentBinding: Binding<APIRequest> {
        Binding(get: { self.current ?? APIRequest() }, set: { self.setCurrent($0) })
    }

    private func setCurrent(_ r: APIRequest) {
        switch selection {
        case .request(let id):
            for c in workspace.collections.indices {
                if let i = workspace.collections[c].requests.firstIndex(where: { $0.id == id }) {
                    if workspace.collections[c].requests[i] != r { workspace.collections[c].requests[i] = r }
                    return
                }
            }
        case .history(let id):
            if let i = history.firstIndex(where: { $0.id == id }), history[i].request != r { history[i].request = r }
        case nil: break
        }
    }

    var currentResponse: ResponseState { selection.flatMap { responses[$0] } ?? .idle }

    var built: Result<BuiltRequest, Error>? {
        guard let r = current else { return nil }
        return Result { try Builder.build(r, vars: variables) }
    }

    // MARK: Collections

    func newRequest(in collectionID: UUID? = nil) {
        var r = APIRequest()
        r.name = "New Request"
        if workspace.collections.isEmpty { workspace.collections.append(RequestCollection(name: "My Requests")) }
        let target = collectionID ?? currentCollection?.id ?? workspace.collections[0].id
        guard let c = workspace.collections.firstIndex(where: { $0.id == target }) else { return }
        workspace.collections[c].requests.append(r)
        selection = .request(r.id)
        editorTab = .params
    }

    func newCollection() {
        let c = RequestCollection(name: "New Collection")
        workspace.collections.append(c)
        renaming = c.id
    }

    func duplicate() {
        guard var r = current else { return }
        r.id = UUID()
        if case .request = selection { r.name += " Copy" }
        let target = currentCollection?.id ?? workspace.collections.first?.id
        if target == nil { workspace.collections.append(RequestCollection(name: "My Requests")) }
        guard let c = workspace.collections.firstIndex(where: { $0.id == (target ?? workspace.collections[0].id) }) else { return }
        let at = workspace.collections[c].requests.firstIndex { $0.id == current?.id }.map { $0 + 1 } ?? workspace.collections[c].requests.count
        workspace.collections[c].requests.insert(r, at: at)
        selection = .request(r.id)
    }

    /// Copies a history entry into the first collection (or the one named) as a saved request.
    func saveToCollection(_ collectionID: UUID? = nil) {
        guard let entry = currentHistory else { return }
        var r = entry.request
        r.id = UUID()
        if workspace.collections.isEmpty { workspace.collections.append(RequestCollection(name: "My Requests")) }
        let c = workspace.collections.firstIndex { $0.id == collectionID } ?? 0
        workspace.collections[c].requests.append(r)
        responses[.request(r.id)] = responses[.history(entry.id)]
        selection = .request(r.id)
    }

    func deleteRequest(_ id: UUID) {
        for c in workspace.collections.indices {
            workspace.collections[c].requests.removeAll { $0.id == id }
        }
        responses[.request(id)] = nil
        if selection == .request(id) { selection = workspace.collections.lazy.flatMap(\.requests).first.map { .request($0.id) } }
    }

    func deleteCollection(_ id: UUID) {
        let ids = workspace.collections.first { $0.id == id }?.requests.map(\.id) ?? []
        workspace.collections.removeAll { $0.id == id }
        if case .request(let s) = selection, ids.contains(s) { selection = nil }
    }

    func move(_ requestID: UUID, to collectionID: UUID) {
        guard let r = workspace.collections.lazy.flatMap(\.requests).first(where: { $0.id == requestID }),
              let dest = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        for c in workspace.collections.indices { workspace.collections[c].requests.removeAll { $0.id == requestID } }
        workspace.collections[dest].requests.append(r)
    }

    func deleteSelected() {
        switch selection {
        case .request(let id): deleteRequest(id)
        case .history(let id):
            history.removeAll { $0.id == id }
            selection = nil
        case nil: break
        }
    }

    func clearHistory() {
        if case .history = selection { selection = nil }
        history = []
    }

    // MARK: Sending

    var isSending: Bool { currentResponse == .loading }

    func send() {
        guard let item = selection, let request = current else { return }
        sendTasks[item]?.cancel()
        let built: BuiltRequest
        do { built = try Builder.build(request, vars: variables) } catch {
            responses[item] = .failed(error.localizedDescription)
            return
        }
        guard let urlRequest = built.urlRequest else {
            responses[item] = .failed(BuildError.invalidURL(built.url).localizedDescription)
            return
        }
        responses[item] = .loading
        sendTasks[item] = Task { [weak self] in
            let start = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let elapsed = Date().timeIntervalSince(start)
                let http = response as? HTTPURLResponse
                let headers = (http?.allHeaderFields ?? [:]).map { Header(name: "\($0.key)", value: "\($0.value)") }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
                let result = HTTPResult(status: http?.statusCode ?? 0, headers: headers, body: data, duration: elapsed,
                                        url: response.url?.absoluteString ?? built.url)
                self?.finish(item, request: request, built: built, state: .done(result))
            } catch is CancellationError {
                self?.responses[item] = .idle
            } catch let error as URLError where error.code == .cancelled {
                self?.responses[item] = .idle
            } catch {
                self?.finish(item, request: request, built: built, state: .failed(error.localizedDescription))
            }
        }
    }

    private func finish(_ item: SidebarItem, request: APIRequest, built: BuiltRequest, state: ResponseState) {
        responses[item] = state
        sendTasks[item] = nil
        var entry = HistoryEntry(date: Date(), request: request, url: built.url, status: nil, duration: 0, size: 0)
        if case .done(let r) = state {
            entry.status = r.status
            entry.duration = r.duration
            entry.size = r.body.count
        }
        history = History.adding(entry, to: history)
        responses[.history(entry.id)] = state
    }

    func cancel() {
        guard let item = selection else { return }
        sendTasks[item]?.cancel()
        sendTasks[item] = nil
        responses[item] = .idle
    }

    // MARK: Output

    func copyCurl() {
        guard case .success(let b)? = built, !Desktop.isSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Curl.command(b), forType: .string)
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.snappy) { self.copied = false }
        }
    }

    func copyBody() {
        guard case .done(let r) = currentResponse, !Desktop.isSnapshot else { return }
        NSPasteboard.general.clearContents()
        let text = (responseTab == .pretty ? r.text.flatMap(JSONFormat.pretty) : nil) ?? r.text ?? ""
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveResponse() {
        guard case .done(let r) = currentResponse else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = r.suggestedFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try r.body.write(to: url, options: .atomic)
            withAnimation(.snappy) { savedResponse = url }
            Task {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.snappy) { if self.savedResponse == url { self.savedResponse = nil } }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func formatBody() {
        guard let r = current, r.bodyKind == .json, let pretty = JSONFormat.pretty(r.body) else { return }
        currentBinding.wrappedValue.body = pretty
    }

    var canFormatBody: Bool {
        guard let r = current, r.bodyKind == .json else { return false }
        return JSONFormat.pretty(r.body) != nil
    }
}
