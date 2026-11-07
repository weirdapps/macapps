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
    /// The latest send per item; a superseded or cancelled send never writes its outcome.
    private var sendIDs: [SidebarItem: UUID] = [:]
    /// The window's undo manager, set by the view, for deletes in the sidebar.
    weak var undoManager: UndoManager?

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
        let ws = loadOrSetAside(Workspace.self, Storage.url(app: "Request", file: "workspace.json")) ?? Samples.starter
        let history = loadOrSetAside([HistoryEntry].self, Storage.url(app: "Request", file: "history.json")) ?? []
        return Store(workspace: ws, history: history, persists: true)
    }

    /// Decodes `url`. A file that exists but cannot be read is renamed with an `.unreadable` suffix
    /// rather than overwritten by the next save, so the user's requests are never silently lost.
    nonisolated static func loadOrSetAside<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingPathExtension().appendingPathExtension("\(stamp).unreadable.json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
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

    /// Ends an inline rename; a blank name becomes "Untitled Collection".
    func finishRename() {
        if let id = renaming, let i = workspace.collections.firstIndex(where: { $0.id == id }),
           workspace.collections[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
            workspace.collections[i].name = "Untitled Collection"
        }
        renaming = nil
    }

    /// Lets Edit > Undo bring back what a delete removed.
    private func registerUndo(_ name: String) {
        let ws = workspace, hist = history, sel = selection
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.workspace = ws
                store.history = hist
                store.selection = sel
            }
        }
        undoManager?.setActionName(name)
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
        registerUndo("Delete Request")
        for c in workspace.collections.indices {
            workspace.collections[c].requests.removeAll { $0.id == id }
        }
        responses[.request(id)] = nil
        if selection == .request(id) { selection = workspace.collections.lazy.flatMap(\.requests).first.map { .request($0.id) } }
    }

    func deleteCollection(_ id: UUID) {
        registerUndo("Delete Collection")
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
            registerUndo("Remove from History")
            history.removeAll { $0.id == id }
            selection = nil
        case nil: break
        }
    }

    func clearHistory() {
        registerUndo("Clear History")
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
        if let problem = built.sendProblem {
            responses[item] = .failed(problem)
            return
        }
        guard let urlRequest = built.urlRequest else {
            responses[item] = .failed(BuildError.invalidURL(built.url).localizedDescription)
            return
        }
        let sendID = UUID()
        sendIDs[item] = sendID
        responses[item] = .loading
        sendTasks[item] = Task { [weak self] in
            let start = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let elapsed = Date().timeIntervalSince(start)
                let http = response as? HTTPURLResponse
                let headers = (http?.allHeaderFields ?? [:]).map { Header(name: "\($0.key)", value: "\($0.value)") }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
                let status = http?.statusCode ?? 0, url = response.url?.absoluteString ?? built.url
                // Decoding and re-indenting a big body happens off the main thread.
                let result = await Task.detached(priority: .userInitiated) {
                    HTTPResult(status: status, headers: headers, body: data, duration: elapsed, url: url)
                }.value
                self?.finish(item, sendID: sendID, request: request, built: built, state: .done(result))
            } catch is CancellationError {
                self?.finish(item, sendID: sendID, request: request, built: built, state: nil)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(item, sendID: sendID, request: request, built: built, state: nil)
            } catch {
                self?.finish(item, sendID: sendID, request: request, built: built, state: .failed(error.localizedDescription))
            }
        }
    }

    /// Records the outcome of send `sendID`, unless a newer send or a cancel replaced it. A nil state means cancelled.
    private func finish(_ item: SidebarItem, sendID: UUID, request: APIRequest, built: BuiltRequest, state: ResponseState?) {
        guard sendIDs[item] == sendID else { return }
        sendIDs[item] = nil
        sendTasks[item] = nil
        guard let state else {
            responses[item] = .idle
            return
        }
        responses[item] = state
        var entry = HistoryEntry(date: Date(), request: request, url: built.url, status: nil, duration: 0, size: 0)
        if case .done(let r) = state {
            entry.status = r.status
            entry.duration = r.duration
            entry.size = r.body.count
        }
        history = History.adding(entry, to: history)
        responses[.history(entry.id)] = state
        // Bodies of entries that fell off the end of the history are no longer needed.
        let kept = Set(history.map(\.id))
        for key in responses.keys {
            if case .history(let id) = key, !kept.contains(id) { responses[key] = nil }
        }
    }

    func cancel() {
        guard let item = selection else { return }
        sendIDs[item] = nil
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
        let text = (responseTab == .pretty ? r.pretty : nil) ?? r.text ?? ""
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
