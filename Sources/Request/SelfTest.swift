import Foundation

/// `Request --selftest`: variable substitution, request building, curl export, JSON formatting and persistence. No network.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func build(_ r: APIRequest, _ vars: [String: String] = [:]) -> BuiltRequest? {
        try? Builder.build(r, vars: vars)
    }

    static func run() -> Int32 {
        let vars = ["base": "https://api.test", "id": "42", "token": "abc", "host": "{{base}}/v1"]

        // Variables.
        check(Template.names(in: "{{base}}/u/{{ id }}/{{base}}") == ["base", "id"], "names in order without duplicates")
        check(Template.resolve("{{base}}/users/{{id}}", vars) == "https://api.test/users/42", "simple substitution")
        check(Template.resolve("{{ base }}", vars) == "https://api.test", "spaces inside braces")
        check(Template.resolve("{{host}}/me", vars) == "https://api.test/v1/me", "variable that refers to another")
        check(Template.resolve("{{nope}}/x", vars) == "{{nope}}/x", "unknown variable stays as typed")
        check(Template.unresolved(in: "{{base}} {{nope}} {{host}}", vars) == ["nope"], "unresolved names")
        check(Template.resolve("{{a}}", ["a": "{{a}}"]) == "{{a}}", "self reference terminates")
        check(Template.resolve("no braces {here}", vars) == "no braces {here}", "single braces untouched")
        let env = RequestEnvironment(name: "e", variables: [Pair(key: "a", value: "1"), Pair(enabled: false, key: "b", value: "2"),
                                                            Pair(key: " a ", value: "3")])
        check(env.values == ["a": "3"], "disabled skipped, later duplicate wins")

        // Building.
        var r = APIRequest(method: .GET, url: "{{base}}/search",
                           params: [Pair(key: "q", value: "mac apps & more"), Pair(enabled: false, key: "x", value: "1"), Pair(key: "id", value: "{{id}}")])
        check(build(r, vars)?.url == "https://api.test/search?q=mac%20apps%20%26%20more&id=42", "params encoded and appended")
        r.url = "{{base}}/search?lang=en"
        check(build(r, vars)?.url == "https://api.test/search?lang=en&q=mac%20apps%20%26%20more&id=42", "params merge with an existing query")
        r.url = "{{base}}/page#top"
        r.params = [Pair(key: "a", value: "1")]
        check(build(r, vars)?.url == "https://api.test/page?a=1#top", "params go before the fragment")
        check(build(APIRequest(url: "localhost:3000/health"))?.url == "http://localhost:3000/health", "missing scheme becomes http")
        check((try? Builder.build(APIRequest(url: "  "), vars: [:])) == nil, "empty URL is rejected")
        do {
            _ = try Builder.build(APIRequest(url: "ftp://files.test/a"), vars: [:])
            check(false, "ftp is rejected")
        } catch { check(error as? BuildError == .invalidURL("ftp://files.test/a"), "ftp is rejected") }
        check((try? Builder.build(APIRequest(url: "{{missing}}/x"), vars: [:])) == nil, "unresolved host is rejected")

        var post = APIRequest(method: .POST, url: "{{base}}/users",
                              headers: [Pair(key: "Authorization", value: "Bearer {{token}}"), Pair(enabled: false, key: "X-Off", value: "1")],
                              bodyKind: .json, body: "{\"id\": {{id}}}")
        let built = build(post, vars)
        check(built?.headers == [Header(name: "Authorization", value: "Bearer abc"), Header(name: "Content-Type", value: "application/json")],
              "headers resolved, disabled dropped, JSON content type added")
        check(built?.body == "{\"id\": 42}", "variables in the body")
        post.headers.append(Pair(key: "content-type", value: "application/vnd.api+json"))
        check(build(post, vars)?.headers.filter { $0.name.lowercased() == "content-type" }.count == 1, "own content type is kept")
        let form = APIRequest(method: .POST, url: "x.test/f", bodyKind: .form,
                              form: [Pair(key: "name", value: "Ada Lovelace"), Pair(key: "note", value: "a&b=c")])
        check(build(form)?.body == "name=Ada+Lovelace&note=a%26b%3Dc", "form encoding")
        check(build(form)?.headers.last?.value == "application/x-www-form-urlencoded", "form content type")
        check(build(APIRequest(method: .POST, url: "x.test", bodyKind: .none, body: "ignored"))?.body == nil, "no body for None")
        check(build(r, vars)?.urlRequest?.httpMethod == "GET", "URLRequest method")

        // curl.
        check(Curl.quote("it's") == "'it'\\''s'", "single quote escaping")
        check(Curl.command(BuiltRequest(method: .GET, url: "https://a.test/x?y=1", headers: [], body: nil)) == "curl 'https://a.test/x?y=1'",
              "plain GET")
        let curlPost = Curl.command(build(post, vars)!)
        check(curlPost == """
        curl 'https://api.test/users' \\
          -H 'Authorization: Bearer abc' \\
          -H 'content-type: application/vnd.api+json' \\
          --data-raw '{"id": 42}'
        """, "POST with headers and body")
        check(Curl.command(BuiltRequest(method: .GET, url: "https://a.test", headers: [], body: "{}")).contains("-X GET"), "GET with a body keeps -X GET")
        check(Curl.command(BuiltRequest(method: .HEAD, url: "https://a.test", headers: [], body: nil)) == "curl --head 'https://a.test'",
              "HEAD uses --head")
        check(Curl.command(BuiltRequest(method: .DELETE, url: "https://a.test/1", headers: [], body: nil)).contains("-X DELETE"), "DELETE sets -X")
        check(Curl.command(BuiltRequest(method: .POST, url: "https://a.test", headers: [], body: "a'b")).hasSuffix("--data-raw 'a'\\''b'"),
              "quotes inside the body")

        // JSON.
        check(JSONFormat.validate("{\"a\": [1, 2]}") == nil, "valid JSON")
        check(JSONFormat.validate("") == nil, "empty is fine")
        check(JSONFormat.validate("{\"a\": }") != nil, "invalid JSON has a reason")
        check(JSONFormat.pretty("{\"z\":1,\"a\":{\"b\":[1,true,null]}}") == "{\n  \"z\": 1,\n  \"a\": {\n    \"b\": [\n      1,\n      true,\n      null\n    ]\n  }\n}",
              "pretty keeps key order")
        check(JSONFormat.pretty("{ \"a\" : { } , \"b\":[ ] }") == "{\n  \"a\": {},\n  \"b\": []\n}", "empty containers stay inline")
        check(JSONFormat.pretty("{\"s\":\"a \\\"{,}\\\" b: [\"}") == "{\n  \"s\": \"a \\\"{,}\\\" b: [\"\n}", "strings with escapes and brackets")
        check(JSONFormat.pretty("{oops") == nil, "pretty refuses invalid JSON")
        check(JSONFormat.pretty("1.50e3") == "1.50e3", "number spelling kept")
        let kinds = JSONFormat.tokens("{\"k\": \"v\", \"n\": -1.5, \"t\": false}").filter { $0.kind != .space && $0.kind != .punctuation }.map(\.kind)
        check(kinds == [.key, .string, .key, .number, .key, .literal], "token kinds")
        check(JSONFormat.tokens("[\"a\"]").map(\.text).joined() == "[\"a\"]", "tokens cover the text")

        // Response helpers.
        check(Format.reason(404) == "Not Found" && Format.reason(201) == "Created", "reason phrases")
        check(Format.duration(0.1424) == "142 ms" && Format.duration(1.5) == "1.50 s", "durations")
        check(Format.size(512) == "512 B", "small sizes")
        let res = HTTPResult(status: 200, headers: [Header(name: "Content-Type", value: "application/json")], body: Data("[]".utf8), duration: 0, url: "")
        check(res.isJSON && res.suggestedFileName == "response.json", "JSON response detection")
        check(HTTPResult(status: 200, headers: [], body: Data("{\"a\":1}".utf8), duration: 0, url: "").isJSON, "JSON sniffed without a content type")

        // History and persistence.
        var list: [HistoryEntry] = []
        for i in 0..<(History.limit + 5) {
            list = History.adding(HistoryEntry(date: Date(), request: APIRequest(name: "\(i)"), url: "", status: 200, duration: 0, size: 0), to: list)
        }
        check(list.count == History.limit && list.first?.request.name == "\(History.limit + 4)", "history is capped, newest first")
        let ws = Samples.starter
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("request-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        if let data = try? JSONEncoder().encode(ws), (try? data.write(to: file)) != nil,
           let back = try? JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file)) {
            check(back == ws, "workspace round trip")
        } else {
            check(false, "workspace round trip")
        }
        check(ws.environments.first.map { Template.resolve(ws.collections[0].requests[0].url, $0.values) } == "https://httpbin.org/get", "starter resolves")

        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
