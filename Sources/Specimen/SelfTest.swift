import AppKit
import CoreText
import Foundation

/// `Specimen --selftest`: checks classification, filtering, pinning, glyph coverage and preference round trips.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }

        // Classification from class bits.
        check("old style serif bits", FontCatalog.category(name: "X", classBits: 1 << 28) == .serif)
        check("slab serif bits", FontCatalog.category(name: "X", classBits: 5 << 28) == .serif)
        check("sans bits", FontCatalog.category(name: "X", classBits: 8 << 28) == .sans)
        check("script bits", FontCatalog.category(name: "X", classBits: 10 << 28) == .script)
        check("symbolic bits", FontCatalog.category(name: "X", classBits: 12 << 28) == .symbol)
        check("bits win over name", FontCatalog.category(name: "Fancy Sans", classBits: 2 << 28) == .serif)

        // Classification from names when the bits are unset.
        check("PT Sans is sans", FontCatalog.category(name: "PT Sans", classBits: 0) == .sans)
        check("Noto Sans Serif-less name", FontCatalog.category(name: "Noto Serif", classBits: 0) == .serif)
        check("sans checked before serif", FontCatalog.category(name: "Source Sans Serif", classBits: 0) == .sans)
        check("Snell Roundhand is script", FontCatalog.category(name: "Snell Roundhand", classBits: 0) == .script)
        check("Zapf Dingbats is symbol", FontCatalog.category(name: "Zapf Dingbats", classBits: 0) == .symbol)
        check("unknown is display", FontCatalog.category(name: "Phosphate", classBits: 0) == .other)
        check("mono by name", FontCatalog.isMonospacedName("JetBrains Mono") && !FontCatalog.isMonospacedName("Avenir"))

        // Filtering.
        let families = [
            FontFamily(name: "Helvetica Neue", category: .sans),
            FontFamily(name: "Didot", category: .serif),
            FontFamily(name: "Menlo", category: .sans, isMonospaced: true),
            FontFamily(name: "Zapfino", category: .script),
            FontFamily(name: "Café Display", category: .other),
        ]
        let all = { (f: FontFilter, q: String, fav: Set<String>) in FontCatalog.filter(families, search: q, filter: f, favourites: fav).map(\.name) }
        check("search is case insensitive", all(.all, "helv", []) == ["Helvetica Neue"])
        check("search ignores accents", all(.all, "cafe", []) == ["Café Display"])
        check("search trims spaces", all(.all, "  didot ", []) == ["Didot"])
        check("favourites filter", all(.favourites, "", ["Didot", "Zapfino"]) == ["Didot", "Zapfino"])
        check("monospaced filter", all(.monospaced, "", []) == ["Menlo"])
        check("serif filter", all(.serif, "", []) == ["Didot"])
        check("sans filter", all(.sans, "", []) == ["Helvetica Neue", "Menlo"])
        check("script filter", all(.script, "", []) == ["Zapfino"])
        check("filter and search combine", all(.sans, "men", []) == ["Menlo"])

        // Pinning and sizes.
        let model = FontModel(prefs: SpecimenPrefs(), families: families, persists: false)
        for f in families.prefix(4) { model.togglePin(f.name) }
        check("four pins accepted", model.pinned.count == 4)
        check("fifth pin refused", !model.togglePin("Café Display") && model.pinned.count == 4)
        model.togglePin("Didot")
        check("unpin removes", model.pinned == ["Helvetica Neue", "Menlo", "Zapfino"])
        model.toggleFavourite("Didot")
        model.toggleFavourite("Menlo")
        model.toggleFavourite("Didot")
        check("favourite toggles", model.favourites == ["Menlo"])
        model.size = 158
        model.adjustSize(by: 8)
        check("size clamps high", model.size == FontCatalog.sizeRange.upperBound)
        model.size = 10
        model.adjustSize(by: -4)
        check("size clamps low", model.size == FontCatalog.sizeRange.lowerBound)
        model.sampleText = "   "
        check("blank sample falls back", model.effectiveSample == FontCatalog.defaultSample)
        check("waterfall runs 12 to 96 ascending",
              FontCatalog.waterfallSizes.first == 12 && FontCatalog.waterfallSizes.last == 96 && FontCatalog.waterfallSizes == FontCatalog.waterfallSizes.sorted())

        // Preferences survive a round trip.
        let prefs = SpecimenPrefs(sampleText: "Hamburgefonstiv", size: 48, darkSample: true, favourites: ["Didot"], pinned: ["Menlo", "Didot"])
        let decoded = (try? JSONEncoder().encode(prefs)).flatMap { try? JSONDecoder().decode(SpecimenPrefs.self, from: $0) }
        check("prefs round trip", decoded == prefs)

        // Real fonts on this Mac.
        let installed = FontCatalog.installedFamilies()
        check("installed families found", installed.count > 20)
        check("hidden families excluded", !installed.contains { $0.hasPrefix(".") })
        check("Helvetica installed", installed.contains("Helvetica"))
        let real = FontCatalog.classify(["Menlo", "Helvetica", "Zapf Dingbats"])
        check("Menlo is monospaced", real[0].isMonospaced)
        check("Helvetica is not monospaced", !real[1].isMonospaced)
        check("Helvetica previews its name", real[1].canPreviewName)
        check("Zapf Dingbats does not preview its name", !real[2].canPreviewName)
        let styles = FontCatalog.styles(of: "Helvetica")
        check("Helvetica has styles", styles.count >= 4)
        check("Helvetica regular style", FontCatalog.regularStyle(in: styles)?.postScriptName == "Helvetica")

        // Glyph coverage.
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let glyphs = FontCatalog.glyphScalars(for: helvetica)
        check("glyph grid covers Latin", glyphs.contains("A") && glyphs.contains("z") && glyphs.count > 150)
        check("glyph grid skips spaces and controls", !glyphs.contains(" ") && !glyphs.contains("\u{7}") && !glyphs.contains("\u{A0}"))
        check("glyph grid respects limit", FontCatalog.glyphScalars(for: helvetica, limit: 50).count == 50)
        check("code label", FontCatalog.codeLabel("A") == "U+0041" && FontCatalog.codeLabel("\u{1F600}") == "U+1F600")

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
