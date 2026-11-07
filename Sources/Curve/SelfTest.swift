import Foundation
import SwiftUI

/// `Curve --selftest`: the parser, the evaluator, the plotter's line breaks and the root finder.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        func calc(_ s: String, x: Double = 0, a: Double = 1, b: Double = 1, c: Double = 1) -> Double? {
            guard let node = try? Parser.parse(s) else { return nil }
            return node.evaluate(Variables(x: x, a: a, b: b, c: c))
        }
        func near(_ s: String, _ expected: Double, x: Double = 0, a: Double = 1) -> Bool {
            guard let v = calc(s, x: x, a: a) else { return false }
            return abs(v - expected) <= 1e-9 * max(1, abs(expected))
        }
        func rejects(_ s: String) -> Bool { (try? Parser.parse(s)) == nil }

        // Precedence and associativity.
        check("1 + 2 * 3", near("1 + 2 * 3", 7))
        check("(1 + 2) * 3", near("(1 + 2) * 3", 9))
        check("10 - 4 - 3 is left associative", near("10 - 4 - 3", 3))
        check("8 / 4 / 2 is left associative", near("8 / 4 / 2", 1))
        check("2^3^2 is right associative", near("2^3^2", 512))
        check("-x^2 is -(x^2)", near("-x^2", -9, x: 3))
        check("2^-1", near("2^-1", 0.5))
        check("unary chain", near("--3", 3) && near("-+-3", 3))
        check("decimals", near(".5 + 1.25", 1.75))

        // Implicit multiplication.
        check("2x", near("2x", 6, x: 3))
        check("3(x+1)", near("3(x+1)", 12, x: 3))
        check("(x+1)(x-1)", near("(x+1)(x-1)", 8, x: 3))
        check("2pi", near("2pi", 2 * .pi))
        check("x sin(x)", near("x sin(x)", 2 * sin(2), x: 2))
        check("2x^2 is 2(x^2)", near("2x^2", 18, x: 3))
        check("ax with a slider", near("ax + 1", 7, x: 3, a: 2))
        check("1/2x is (1/2)x", near("1/2x", 2, x: 4))

        // Functions and constants.
        check("sin cos tan", near("sin(pi/2) + cos(0) + tan(pi/4)", 3))
        check("asin acos atan", near("asin(1) + acos(1) + atan(1)", .pi / 2 + .pi / 4))
        check("sqrt abs", near("sqrt(16) + abs(-3)", 7))
        check("ln log exp", near("ln(e) + log(1000) + exp(0)", 5))
        check("floor ceil", near("floor(2.7) + ceil(2.1) + floor(-0.5)", 4))
        check("sin(x)^2 squares the sine", near("sin(x)^2", pow(sin(1.0), 2), x: 1))
        check("sin x without brackets", near("sin x", sin(0.5), x: 0.5))
        check("exp is not e times x", near("exp(1)", M_E))
        check("ex is e times x", near("ex", 2 * M_E, x: 2))
        check("|x| bars", near("|x - 5|", 2, x: 3) && near("2|x|", 6, x: -3))
        check("unicode operators", near("2\u{00D7}3 \u{2212} 6\u{00F7}2", 3) && near("x\u{00B2}", 9, x: 3))
        check("y = prefix", near("y = x + 1", 4, x: 3) && near("f(x) = 2x", 6, x: 3))
        check("cube root of a negative", near("(-8)^(1/3)", -2))
        check("sqrt of a negative is undefined", calc("sqrt(x)", x: -1)?.isNaN == true)
        check("1/0 is infinite", calc("1/x", x: 0)?.isInfinite == true)

        // Errors.
        check("empty is an error", rejects("") && rejects("   "))
        check("unknown name", rejects("q + 1") && rejects("sec(x)"))
        check("unbalanced brackets", rejects("(x + 1") && rejects("x + 1)") && rejects("|x"))
        check("dangling operator", rejects("x +") && rejects("* 2") && rejects("2 ^"))
        check("function needs an argument", rejects("sin") && rejects("sin()"))
        check("error message is readable", (try? Parser.parse("x + q")) == nil
              && { do { _ = try Parser.parse("x + q"); return false } catch let e as ParseError { return e.message.contains("q") } catch { return false } }())
        check("parameters are found", (try? Parser.parse("a x^2 + b"))?.parameters == [.a, .b])

        // Plotting breaks at asymptotes and jumps, and joins smooth curves.
        let viewport = Viewport(centerX: 0, centerY: 0, scale: 20.0 / 600)
        let size = CGSize(width: 600, height: 400)
        let vars = Variables()
        let sine = Plotter.polylines(try! Parser.parse("sin(x)"), vars: vars, viewport: viewport, size: size)
        check("sin(x) is one unbroken line", sine.count == 1)
        let tangent = Plotter.polylines(try! Parser.parse("tan(x)"), vars: vars, viewport: viewport, size: size)
        check("tan(x) breaks at each asymptote", tangent.count == 7)
        let shifted = Viewport(centerX: 0.3, centerY: 0, scale: 20.0 / 600)
        let steps = Plotter.polylines(try! Parser.parse("floor(x)"), vars: vars, viewport: shifted, size: CGSize(width: 600, height: 800))
        check("floor(x) breaks at each step", steps.count == 21)
        let reciprocal = Plotter.polylines(try! Parser.parse("1/x"), vars: vars, viewport: viewport, size: size)
        check("1/x has two branches", reciprocal.count == 2)
        let root = Plotter.polylines(try! Parser.parse("sqrt(x)"), vars: vars, viewport: viewport, size: size)
        check("sqrt(x) starts at the origin", root.count == 1 && abs((root.first?.first?.x ?? 0) - 300) < 0.1)

        // Roots and intersections.
        let sinRoots = Analysis.zeros(of: { sin($0) }, from: -10, to: 10, tolerance: 1e-6)
        check("sin has 7 roots in [-10, 10]", sinRoots.count == 7 && sinRoots.contains { abs($0 - .pi) < 1e-9 })
        let touching = Analysis.zeros(of: { ($0 - 1) * ($0 - 1) }, from: -5, to: 5, tolerance: 1e-6)
        check("touching root of (x-1)^2", touching.count == 1 && abs((touching.first ?? 0) - 1) < 1e-6)
        check("tan asymptotes are not roots",
              Analysis.zeros(of: { tan($0) }, from: 1, to: 2, tolerance: 1e-6).isEmpty)
        check("floor jumps are not roots",
              Analysis.zeros(of: { floor($0) - 0.5 }, from: -3, to: 3, tolerance: 1e-6).isEmpty)
        let line = try! Parser.parse("x"), parabola = try! Parser.parse("x^2 - 2")
        let points = Analysis.keyPoints([line, parabola], vars: vars, from: -5, to: 5, tolerance: 1e-6)
        let hits = points.filter { $0.kind == .intersection }.map(\.x).sorted()
        check("x meets x^2 - 2 at -1 and 2", hits.count == 2 && abs(hits[0] + 1) < 1e-9 && abs(hits[1] - 2) < 1e-9)
        check("x^2 - 2 roots are plus and minus sqrt 2",
              points.filter { $0.kind == .root && $0.curves == [1] }.map { abs(abs($0.x) - sqrt(2)) < 1e-9 } == [true, true])

        // Viewport and labels.
        var v = Viewport(centerX: 0, centerY: 0, scale: 0.1)
        v.zoom(by: 2, at: CGPoint(x: 100, y: 50), in: CGSize(width: 400, height: 300))
        check("zoom keeps the point under the pointer",
              abs(v.worldX(100, width: 400) + 10) < 1e-9 && abs(v.worldY(50, height: 300) - 10) < 1e-9 && v.scale == 0.05)
        check("grid steps are 1, 2, 5", Format.gridStep(scale: 0.01, minPoints: 90) == 1
              && Format.gridStep(scale: 0.015, minPoints: 90) == 2 && Format.gridStep(scale: 0.04, minPoints: 90) == 5)
        check("tick labels", Format.tick(0.5, step: 0.5) == "0.5" && Format.tick(-2, step: 1) == "\u{2212}2")
        check("value labels", Format.value(3.14159265) == "3.1416" && Format.value(2) == "2" && Format.value(.nan) == "undefined")

        // Saved state survives a round trip.
        let state = SavedState(functions: [GraphFunction(expression: "sin(x)", color: 2, isVisible: false)],
                               parameters: ["a": 0.5], viewport: v, showGrid: false, showPoints: true)
        let decoded = (try? JSONEncoder().encode(state)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        check("saved state round trip", decoded?.functions == state.functions && decoded?.viewport == v
              && decoded?.parameters["a"] == 0.5 && decoded?.showGrid == false)

        // Regressions found in review.
        check("(-8)^(2/3) is 4", near("(-8)^(2/3)", 4) && near("(-32)^0.2", -2))
        check("even roots of negatives stay undefined", calc("(-4)^(1/2)")?.isNaN == true && calc("(-4)^0.25")?.isNaN == true)
        check("tiny exponent of a negative does not trap", calc("(-2)^(0.00000000000000000001)")?.isFinite == true)
        let deep = String(repeating: "(", count: 20000) + "x" + String(repeating: ")", count: 20000)
        check("very deep nesting is refused, not a crash", rejects(deep) && rejects(String(repeating: "-", count: 50000) + "x"))
        check("a long but sane expression still parses", near(Array(repeating: "x", count: 150).joined(separator: "+"), 150, x: 1))
        check("2.3.4 is a bad number", rejects("2.3.4") && near("1.5", 1.5))
        check("multiples of a step", Format.multiples(of: 1, from: -2.5, to: 2.5) == [-2, -1, 0, 1, 2]
              && Format.multiples(of: 0.5, from: 0, to: 1) == [0, 0.5, 1])
        check("multiples never stall far from the origin",
              Format.multiples(of: 1e-7, from: 1e12, to: 1e12 + 1).isEmpty
              && Format.multiples(of: 1e-7, from: 1e12, to: 1e12 + 1e-5).count <= 1000)
        check("multiples of a bad step are empty", Format.multiples(of: 0, from: 0, to: 1).isEmpty
              && Format.multiples(of: .nan, from: 0, to: 1).isEmpty && Format.multiples(of: 1, from: .nan, to: 1).isEmpty)
        let broken = Viewport(centerX: .nan, centerY: .infinity, scale: 0).sanitized
        check("a damaged saved viewport is repaired", broken.centerX == 0 && broken.centerY == 0 && broken.scale > 0)
        var far = Viewport()
        far.pan(by: CGSize(width: 1e15, height: -1e15))
        check("panning stops at the edge of precision", abs(far.centerX) <= Viewport.maxCenter && abs(far.centerY) <= Viewport.maxCenter)
        var unchanged = Viewport()
        unchanged.zoom(by: 0, at: .zero, in: CGSize(width: 100, height: 100))
        unchanged.zoom(by: -2, at: .zero, in: CGSize(width: 100, height: 100))
        check("zoom ignores a zero or negative factor", unchanged == Viewport())
        MainActor.assumeIsolated {
            let model = CurveModel(functions: [GraphFunction(expression: "x", color: 0, isVisible: false),
                                               GraphFunction(expression: "x - 1", color: 1)], persists: false)
            let points = model.keyPoints(for: model.curves)
            check("key points name the function, not its place among visible curves",
                  points.count == 1 && points[0].curves == [1] && abs(points[0].x - 1) < 1e-9)
        }

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
