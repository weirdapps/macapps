import Foundation

/// Removes tracking parameters from every link in a piece of text. Used by Plain.
public enum LinkCleaner {
    /// Parameter names removed on every site.
    static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid", "wt_mc",
        "li_fat_id", "ref_src", "ref_url", "spm", "scm", "_ga", "_gl", "ncid", "cmpid", "srsltid",
    ]
    /// Parameter name prefixes removed on every site.
    static let prefixes = ["utm_", "pk_", "mtm_", "hmb_", "ga_"]
    /// Parameters removed only on the hosts that use them for sharing attribution.
    static let perHost: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp"],
        "youtu.be": ["si", "feature"],
        "open.spotify.com": ["si", "context"],
        "twitter.com": ["s", "t"],
        "x.com": ["s", "t"],
        "instagram.com": ["igshid", "igsh", "img_index"],
        "amazon.com": ["ref", "ref_", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_p", "pf_rd_r", "psc", "content-id"],
        "linkedin.com": ["trk", "trackingId", "lipi", "rcm"],
    ]

    public struct Result: Equatable {
        public let text: String
        public let removed: Int
    }

    public static func clean(_ text: String) -> Result {
        guard text.contains("://"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return Result(text: text, removed: 0)
        }
        var output = text
        var removed = 0
        let ns = text as NSString
        // Replace from the end so earlier ranges stay valid.
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let original = ns.substring(with: match.range)
            guard original.contains("?"), let (cleaned, count) = cleanURL(original), count > 0 else { continue }
            removed += count
            output = (output as NSString).replacingCharacters(in: match.range, with: cleaned)
        }
        return Result(text: output, removed: removed)
    }

    static func cleanURL(_ string: String) -> (String, Int)? {
        guard var components = URLComponents(string: string), let items = components.queryItems, !items.isEmpty else { return nil }
        let host = (components.host ?? "").lowercased()
        let hostRules = perHost.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !(exact.contains(name) || hostRules.contains(item.name) || prefixes.contains { name.hasPrefix($0) })
        }
        let count = items.count - kept.count
        guard count > 0 else { return (string, 0) }
        components.queryItems = kept.isEmpty ? nil : kept
        return (components.string ?? string, count)
    }
}
