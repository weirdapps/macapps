import AppKit
import CryptoKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusPopover!
    let model = TokenModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "key.viewfinder", accessibilityLabel: "Token") {
            TokenView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

struct DecodedJWT: Equatable {
    var header: [String: AnyHashable]
    var payload: [String: AnyHashable]
    var headerJSON: String
    var payloadJSON: String
    var signingInput: String
    var signature: Data

    var algorithm: String { header["alg"] as? String ?? "none" }
}

struct JWTError: Error, Equatable {
    let message: String
}

enum Verification: Equatable {
    case valid, invalid, needsSecret, unsupported(String), unsigned
}

enum JWT {
    static func base64URL(_ s: Substring) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard b.count % 4 != 1 else { return nil }
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }

    static func base64URLString(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String) -> Result<DecodedJWT, JWTError> {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 5 { return .failure(JWTError(message: "This is an encrypted token (JWE). Its contents cannot be read without the key.")) }
        guard parts.count == 3 else { return .failure(JWTError(message: "A JWT has three parts separated by dots; this has \(parts.count).")) }
        func json(_ part: Substring, _ name: String) -> Result<([String: AnyHashable], String), JWTError> {
            guard let data = base64URL(part) else { return .failure(JWTError(message: "The \(name) is not valid Base64URL.")) }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dict = object as? [String: AnyHashable] else {
                return .failure(JWTError(message: "The \(name) is not a JSON object."))
            }
            let pretty = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return .success((dict, pretty))
        }
        let header: ([String: AnyHashable], String), payload: ([String: AnyHashable], String)
        switch json(parts[0], "header") { case .success(let v): header = v; case .failure(let e): return .failure(e) }
        switch json(parts[1], "payload") { case .success(let v): payload = v; case .failure(let e): return .failure(e) }
        guard let signature = parts[2].isEmpty ? Data() : base64URL(parts[2]) else {
            return .failure(JWTError(message: "The signature is not valid Base64URL."))
        }
        return .success(DecodedJWT(header: header.0, payload: payload.0, headerJSON: header.1, payloadJSON: payload.1,
                                   signingInput: "\(parts[0]).\(parts[1])", signature: signature))
    }

    static func hmac(_ alg: String, key: Data, message: Data) -> Data? {
        let k = SymmetricKey(data: key)
        switch alg {
        case "HS256": return Data(HMAC<SHA256>.authenticationCode(for: message, using: k))
        case "HS384": return Data(HMAC<SHA384>.authenticationCode(for: message, using: k))
        case "HS512": return Data(HMAC<SHA512>.authenticationCode(for: message, using: k))
        default: return nil
        }
    }

    /// Checks an HMAC signature. The secret is UTF-8 text, or Base64 / Base64URL bytes when `secretIsBase64`.
    static func verify(_ jwt: DecodedJWT, secret: String, secretIsBase64: Bool) -> Verification {
        let alg = jwt.algorithm
        if alg.lowercased() == "none" { return .unsigned }
        guard alg.hasPrefix("HS") else { return .unsupported(alg) }
        guard !secret.isEmpty else { return .needsSecret }
        let key: Data
        if secretIsBase64 {
            guard let k = base64URL(Substring(secret.trimmingCharacters(in: .whitespacesAndNewlines))) else { return .invalid }
            key = k
        } else {
            key = Data(secret.utf8)
        }
        guard let mac = hmac(alg, key: key, message: Data(jwt.signingInput.utf8)) else { return .unsupported(alg) }
        // Constant time comparison.
        guard mac.count == jwt.signature.count else { return .invalid }
        return zip(mac, jwt.signature).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 ? .valid : .invalid
    }

    struct Claim: Equatable {
        var key: String
        var label: String
        var date: Date
    }

    static func timeClaims(_ payload: [String: AnyHashable]) -> [Claim] {
        [("iat", "Issued"), ("nbf", "Not before"), ("exp", "Expires")].compactMap { key, label in
            guard let n = payload[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return Claim(key: key, label: label, date: Date(timeIntervalSince1970: n.doubleValue))
        }
    }

    enum Lifetime: Equatable { case none, active(Date), expired(Date), notYet(Date) }

    static func lifetime(_ payload: [String: AnyHashable], now: Date) -> Lifetime {
        let claims = timeClaims(payload)
        if let nbf = claims.first(where: { $0.key == "nbf" })?.date, nbf > now { return .notYet(nbf) }
        guard let exp = claims.first(where: { $0.key == "exp" })?.date else { return .none }
        return exp <= now ? .expired(exp) : .active(exp)
    }

    /// "in 3 hours", "2 days ago".
    static func relative(_ date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now), a = abs(delta)
        if a < 1 { return "now" }
        let units: [(Double, String)] = [(365.2425 * 86400, "year"), (30.436875 * 86400, "month"), (86400, "day"), (3600, "hour"), (60, "minute"), (1, "second")]
        let (size, name) = units.first { a >= $0.0 }!
        let n = Int(a / size)
        let phrase = "\(n) \(name)\(n == 1 ? "" : "s")"
        return delta < 0 ? "\(phrase) ago" : "in \(phrase)"
    }
}

@MainActor
final class TokenModel: ObservableObject {
    @Published var token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    // The secret is kept in memory only, never written to disk.
    @Published var secret = "your-256-bit-secret"
    @Published var secretIsBase64 = false
    @Published var showHeader = false
    @Published private(set) var now = Date()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    var decoded: Result<DecodedJWT, JWTError>? {
        token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : JWT.decode(token)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

struct TokenView: View {
    @EnvironmentObject var model: TokenModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Token").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Label("Decoded on this Mac", systemImage: "lock.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            VStack(spacing: 10) {
                TokenInput()
                switch model.decoded {
                case .success(let jwt)?:
                    LifetimeBar(jwt: jwt)
                    JSONPanes(jwt: jwt)
                    VerifyPane(jwt: jwt)
                case .failure(let e)?:
                    Label(e.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                case nil:
                    VStack(spacing: 8) {
                        Image(systemName: "key.viewfinder").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("Paste a JWT to read its header and claims\nand check its signature.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Token") {
                Button("Paste Token") { model.token = NSPasteboard.general.string(forType: .string) ?? "" }
                Button("Clear Token and Secret") { model.token = ""; model.secret = "" }
            }
        }
        .frame(width: 400)
    }
}

struct TokenInput: View {
    @EnvironmentObject var model: TokenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Encoded").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                PaneButton("doc.on.clipboard", "Paste") { model.token = NSPasteboard.general.string(forType: .string) ?? "" }
                PaneButton("xmark", "Clear") { model.token = "" }
            }
            ZStack(alignment: .topLeading) {
                // Coloured copy of the token behind a transparent editor, so the three parts read at a glance.
                Text(Self.colored(model.token))
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                TextEditor(text: $model.token)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.clear)
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(height: 72)
            .clipped()
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }

    static let partColors: [Color] = [Color(red: 0.93, green: 0.27, blue: 0.45), Color(red: 0.6, green: 0.3, blue: 0.95), Color(red: 0.05, green: 0.65, blue: 0.85)]

    static func colored(_ token: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in token.split(separator: ".", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out += AttributedString(".") }
            var a = AttributedString(part)
            a.foregroundColor = partColors[min(i, 2)]
            out += a
        }
        return out
    }
}

struct LifetimeBar: View {
    @EnvironmentObject var model: TokenModel
    let jwt: DecodedJWT

    var body: some View {
        let life = JWT.lifetime(jwt.payload, now: model.now)
        let (symbol, text, color): (String, String, Color) = switch life {
        case .none: ("infinity", "No expiry claim", .secondary)
        case .active(let d): ("checkmark.circle.fill", "Expires \(JWT.relative(d, now: model.now))", .green)
        case .expired(let d): ("xmark.circle.fill", "Expired \(JWT.relative(d, now: model.now))", .red)
        case .notYet(let d): ("clock.fill", "Not valid until \(JWT.relative(d, now: model.now))", .orange)
        }
        VStack(spacing: 6) {
            HStack {
                Label(text, systemImage: symbol).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(color)
                    .contentTransition(.numericText())
                Spacer()
                Text(jwt.algorithm).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
            }
            ForEach(JWT.timeClaims(jwt.payload), id: \.key) { claim in
                HStack {
                    Text(claim.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    Text(claim.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute().second()))
                        .font(.system(size: 11.5, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text(JWT.relative(claim.date, now: model.now)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
    }
}

struct JSONPanes: View {
    @EnvironmentObject var model: TokenModel
    let jwt: DecodedJWT
    @State private var copied = false

    var body: some View {
        let text = model.showHeader ? jwt.headerJSON : jwt.payloadJSON
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ForEach([false, true], id: \.self) { header in
                    let selected = model.showHeader == header
                    Button { withAnimation(.snappy) { model.showHeader = header } } label: {
                        Text(header ? "Header" : "Payload")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(selected ? .white : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 3.5)
                            .background(Capsule().fill(selected ? AnyShapeStyle(TokenInput.partColors[header ? 0 : 1]) : AnyShapeStyle(.quaternary.opacity(0.4))))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                PaneButton(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy JSON") {
                    model.copy(text)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                }
            }
            ScrollView {
                Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(9)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }
}

struct VerifyPane: View {
    @EnvironmentObject var model: TokenModel
    let jwt: DecodedJWT

    var body: some View {
        let result = JWT.verify(jwt, secret: model.secret, secretIsBase64: model.secretIsBase64)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("HMAC secret", text: $model.secret)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                Toggle("Base64", isOn: $model.secretIsBase64).toggleStyle(.checkbox).font(.system(size: 11))
            }
            let (symbol, text, color): (String, String, Color) = switch result {
            case .valid: ("checkmark.seal.fill", "Signature verified", .green)
            case .invalid: ("xmark.seal.fill", "Signature does not match this secret", .red)
            case .needsSecret: ("key", "Enter the secret to check the \(jwt.algorithm) signature", .secondary)
            case .unsupported(let alg): ("info.circle", "\(alg) uses a public key; only HS256, HS384 and HS512 can be checked here", .secondary)
            case .unsigned: ("exclamationmark.triangle.fill", "Unsigned token (alg none): anyone could have written it", .orange)
            }
            Label(text, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .animation(.snappy, value: result)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct PaneButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ title: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(.quaternary.opacity(hovering ? 0.8 : 0.4)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

// MARK: - Icon

//: a key whose blade is three coloured segments, the three parts of a token

func appIcon() -> NSBitmapImageRep {
    render(0xFDA4AF, 0x7E22CE) { ctx in
        ctx.translateBy(x: 500, y: 520)
        ctx.rotate(by: -35 * .pi / 180)
        let hole = CGRect(x: -275, y: -62, width: 124, height: 124)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 34, alpha: 0.35)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // Bow, with the hole punched out.
        ctx.addEllipse(in: CGRect(x: -380, y: -165, width: 330, height: 330))
        ctx.addEllipse(in: hole)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath(using: .evenOdd)
        // Shaft in three coloured parts, like header, payload and signature.
        let colors: [UInt32] = [0xFB7185, 0xA855F7, 0x22D3EE]
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(rgb(c).cgColor)
            ctx.addPath(roundedRect(CGRect(x: -70 + CGFloat(i) * 142, y: -48, width: 132, height: 96), 26))
            ctx.fillPath()
        }
        // Bit with two teeth.
        ctx.setFillColor(rgb(0x22D3EE).cgColor)
        ctx.addPath(roundedRect(CGRect(x: 240, y: -150, width: 64, height: 140), 20))
        ctx.addPath(roundedRect(CGRect(x: 310, y: -118, width: 52, height: 108), 18))
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // A highlight across the bow.
        ctx.setStrokeColor(rgb(0xFCE7F3, 0.9).cgColor)
        ctx.setLineWidth(18)
        ctx.setLineCap(.round)
        ctx.addArc(center: CGPoint(x: -215, y: 0), radius: 128, startAngle: .pi * 0.62, endAngle: .pi * 0.92, clockwise: false)
        ctx.strokePath()
    }
}
