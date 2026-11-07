import Foundation

enum Samples {
    /// What a new user sees on first launch: requests that really work against httpbin.org.
    static var starter: Workspace {
        let env = RequestEnvironment(name: "httpbin", variables: [Pair(key: "base", value: "https://httpbin.org")])
        let examples = RequestCollection(name: "Examples", requests: [
            APIRequest(name: "Get with params", method: .GET, url: "{{base}}/get",
                       params: [Pair(key: "page", value: "2"), Pair(key: "q", value: "mac apps")]),
            APIRequest(name: "Post JSON", method: .POST, url: "{{base}}/post",
                       headers: [Pair(key: "Accept", value: "application/json")],
                       bodyKind: .json, body: "{\n  \"name\": \"Ada\",\n  \"admin\": true\n}"),
            APIRequest(name: "Post a form", method: .POST, url: "{{base}}/post", bodyKind: .form,
                       form: [Pair(key: "city", value: "Athens"), Pair(key: "zip", value: "16674")]),
            APIRequest(name: "Teapot", method: .GET, url: "{{base}}/status/418"),
        ])
        return Workspace(collections: [examples], environments: [env], activeEnvironment: env.id)
    }

    /// Fixed data for the website screenshot.
    @MainActor static var demo: Store {
        let staging = RequestEnvironment(name: "Staging", variables: [
            Pair(key: "base", value: "https://api.acme.dev/v2"), Pair(key: "token", value: "sk_test_4f9a21"),
        ])
        let production = RequestEnvironment(name: "Production", variables: [Pair(key: "base", value: "https://api.acme.com/v2")])
        let list = APIRequest(name: "List users", method: .GET, url: "{{base}}/users",
                              params: [Pair(key: "page", value: "2"), Pair(key: "per_page", value: "3"),
                                       Pair(key: "sort", value: "-created")],
                              headers: [Pair(key: "Authorization", value: "Bearer {{token}}"), Pair(key: "Accept", value: "application/json")])
        let create = APIRequest(name: "Create user", method: .POST, url: "{{base}}/users",
                                headers: [Pair(key: "Authorization", value: "Bearer {{token}}"), Pair(key: "Idempotency-Key", value: "7f3c-21aa")],
                                bodyKind: .json, body: """
            {
              "name": "Grace Hopper",
              "email": "grace@acme.dev",
              "role": "admin",
              "teams": ["compilers", "navy"],
              "notify": true,
              "quota": 2048,
              "address": {
                "city": "Arlington",
                "country": "US"
              },
              "manager": null
            }
            """)
        let users = RequestCollection(name: "Acme API", requests: [
            list,
            create,
            APIRequest(name: "Update profile", method: .PATCH, url: "{{base}}/users/42", bodyKind: .json, body: "{ \"bio\": \"Hi\" }"),
            APIRequest(name: "Delete session", method: .DELETE, url: "{{base}}/sessions/current"),
        ])
        let webhooks = RequestCollection(name: "Webhooks", requests: [
            APIRequest(name: "Ping endpoint", method: .HEAD, url: "https://hooks.acme.dev/ping"),
            APIRequest(name: "Replay event", method: .PUT, url: "{{base}}/events/evt_81/replay"),
        ])
        let ws = Workspace(collections: [users, webhooks], environments: [staging, production], activeEnvironment: staging.id)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let history = [
            HistoryEntry(date: now.addingTimeInterval(-60), request: list, url: "https://api.acme.dev/v2/users?page=1", status: 200, duration: 0.131, size: 1280),
            HistoryEntry(date: now.addingTimeInterval(-600), request: users.requests[1], url: "https://api.acme.dev/v2/users", status: 201, duration: 0.212, size: 214),
            HistoryEntry(date: now.addingTimeInterval(-1800), request: users.requests[2], url: "https://api.acme.dev/v2/users/42", status: 422, duration: 0.098, size: 96),
        ]
        let store = Store(workspace: ws, history: history, persists: false)
        store.selection = .request(create.id)
        store.editorTab = .body
        let body = """
        {"id":43,"object":"user","name":"Grace Hopper","email":"grace@acme.dev","role":"admin","teams":["compilers","navy"],"notify":true,"quota":2048,"verified":false,"address":{"city":"Arlington","country":"US"},"manager":null,"created_at":"2026-10-26T09:14:20Z","links":{"self":"/v2/users/43","teams":"/v2/users/43/teams"}}
        """
        let result = HTTPResult(status: 201, headers: [
            Header(name: "Cache-Control", value: "no-cache"), Header(name: "Content-Length", value: "\(body.utf8.count)"),
            Header(name: "Content-Type", value: "application/json; charset=utf-8"), Header(name: "Date", value: "Mon, 26 Oct 2026 09:14:20 GMT"),
            Header(name: "Server", value: "nginx"), Header(name: "X-Request-Id", value: "req_7d1c0f"),
        ], body: Data(body.utf8), duration: 0.186, url: "https://api.acme.dev/v2/users")
        store.responses[.request(create.id)] = .done(result)
        return store
    }
}
