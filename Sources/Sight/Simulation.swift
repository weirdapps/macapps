import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The colour science: Machado, Oliveira and Fernandes (2009), "A Physiologically-based Model for Simulation
// of Color Vision Deficiency". Each deficiency is a 3x3 matrix applied to linear RGB, tabulated by severity.

/// A row-major 3x3 matrix on linear RGB.
struct Matrix3: Equatable, Sendable {
    var m: [Float]

    init(_ m: [Float]) {
        precondition(m.count == 9)
        self.m = m
    }

    static let identity = Matrix3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Every row of the luminance weights: what is left when no cone class tells colours apart.
    static let luminance = Matrix3([0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722])

    func lerp(to other: Matrix3, _ t: Float) -> Matrix3 {
        Matrix3(zip(m, other.m).map { $0 + ($1 - $0) * t })
    }

    func apply(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        (m[0] * r + m[1] * g + m[2] * b, m[3] * r + m[4] * g + m[5] * b, m[6] * r + m[7] * g + m[8] * b)
    }

    func rowSum(_ row: Int) -> Float { m[row * 3] + m[row * 3 + 1] + m[row * 3 + 2] }
}

enum Machado {
    /// Severity 0.0, 0.1, ... 1.0. Index 0 is normal vision.
    static let protan: [Matrix3] = [
        .identity,
        Matrix3([0.856167, 0.182038, -0.038205, 0.029342, 0.955115, 0.015544, -0.002880, -0.001563, 1.004443]),
        Matrix3([0.734766, 0.334872, -0.069637, 0.051840, 0.919198, 0.028963, -0.004928, -0.004209, 1.009137]),
        Matrix3([0.630323, 0.465641, -0.095964, 0.069181, 0.890046, 0.040773, -0.006308, -0.007724, 1.014032]),
        Matrix3([0.539009, 0.579343, -0.118352, 0.082546, 0.866121, 0.051332, -0.007136, -0.011959, 1.019095]),
        Matrix3([0.458064, 0.679578, -0.137642, 0.092785, 0.846313, 0.060902, -0.007494, -0.016807, 1.024301]),
        Matrix3([0.385450, 0.769005, -0.154455, 0.100526, 0.829802, 0.069673, -0.007442, -0.022190, 1.029632]),
        Matrix3([0.319627, 0.849633, -0.169261, 0.106241, 0.815969, 0.077790, -0.007025, -0.028051, 1.035076]),
        Matrix3([0.259411, 0.923008, -0.182420, 0.110296, 0.804340, 0.085364, -0.006276, -0.034346, 1.040622]),
        Matrix3([0.203876, 0.990338, -0.194214, 0.112975, 0.794542, 0.092483, -0.005222, -0.041043, 1.046265]),
        Matrix3([0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998]),
    ]

    static let deutan: [Matrix3] = [
        .identity,
        Matrix3([0.866435, 0.177704, -0.044139, 0.049567, 0.939063, 0.011370, -0.003453, 0.007233, 0.996220]),
        Matrix3([0.760729, 0.319078, -0.079807, 0.090568, 0.889315, 0.020117, -0.006027, 0.013325, 0.992702]),
        Matrix3([0.675425, 0.433850, -0.109275, 0.125303, 0.847755, 0.026942, -0.007950, 0.018572, 0.989378]),
        Matrix3([0.605511, 0.528560, -0.134071, 0.155318, 0.812366, 0.032316, -0.009376, 0.023176, 0.986200]),
        Matrix3([0.547494, 0.607765, -0.155259, 0.181692, 0.781742, 0.036566, -0.010410, 0.027275, 0.983136]),
        Matrix3([0.498864, 0.674741, -0.173604, 0.205199, 0.754872, 0.039929, -0.011131, 0.030969, 0.980162]),
        Matrix3([0.457771, 0.731899, -0.189670, 0.226409, 0.731012, 0.042579, -0.011595, 0.034333, 0.977261]),
        Matrix3([0.422823, 0.781057, -0.203881, 0.245752, 0.709602, 0.044646, -0.011843, 0.037423, 0.974421]),
        Matrix3([0.392952, 0.823610, -0.216562, 0.263559, 0.690210, 0.046232, -0.011910, 0.040281, 0.971630]),
        Matrix3([0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881]),
    ]

    static let tritan: [Matrix3] = [
        .identity,
        Matrix3([0.926670, 0.092514, -0.019184, 0.021191, 0.964503, 0.014306, 0.008437, 0.054813, 0.936750]),
        Matrix3([0.895720, 0.133330, -0.029050, 0.029997, 0.945400, 0.024603, 0.013027, 0.104707, 0.882266]),
        Matrix3([0.905871, 0.127791, -0.033662, 0.026856, 0.941251, 0.031893, 0.013410, 0.148296, 0.838294]),
        Matrix3([0.948035, 0.089490, -0.037526, 0.014364, 0.946792, 0.038844, 0.010853, 0.193991, 0.795156]),
        Matrix3([1.017277, 0.027029, -0.044306, -0.006113, 0.958479, 0.047634, 0.006379, 0.248708, 0.744913]),
        Matrix3([1.104996, -0.046633, -0.058363, -0.032137, 0.971635, 0.060503, 0.001336, 0.317922, 0.680742]),
        Matrix3([1.193214, -0.109812, -0.083402, -0.058496, 0.979410, 0.079086, -0.002346, 0.403492, 0.598854]),
        Matrix3([1.257728, -0.139648, -0.118081, -0.078003, 0.975409, 0.102594, -0.003316, 0.501214, 0.502102]),
        Matrix3([1.278864, -0.125333, -0.153531, -0.084748, 0.957674, 0.127074, -0.000989, 0.601151, 0.399838]),
        Matrix3([1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900]),
    ]

    /// The matrix at any severity in 0...1, interpolated between the tabulated tenths.
    static func matrix(_ table: [Matrix3], severity: Double) -> Matrix3 {
        let s = min(max(severity, 0), 1) * 10
        let i = min(Int(s.rounded(.down)), 9)
        return table[i].lerp(to: table[i + 1], Float(s - Double(i)))
    }
}

enum Simulation: String, CaseIterable, Identifiable, Sendable {
    case protanopia, deuteranopia, tritanopia, protanomaly, deuteranomaly, tritanomaly, achromatopsia

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    enum Group: String, CaseIterable {
        case dichromacy = "Dichromacy"
        case anomalous = "Anomalous trichromacy"
        case monochromacy = "Monochromacy"
    }

    var group: Group {
        switch self {
        case .protanopia, .deuteranopia, .tritanopia: .dichromacy
        case .protanomaly, .deuteranomaly, .tritanomaly: .anomalous
        case .achromatopsia: .monochromacy
        }
    }

    /// Anomalous trichromacy comes in degrees; the severity slider applies to these.
    var isAnomalous: Bool { group == .anomalous }

    var cones: String {
        switch self {
        case .protanopia: "No red cones"
        case .deuteranopia: "No green cones"
        case .tritanopia: "No blue cones"
        case .protanomaly: "Weak red cones"
        case .deuteranomaly: "Weak green cones"
        case .tritanomaly: "Weak blue cones"
        case .achromatopsia: "No colour vision"
        }
    }

    /// Approximate prevalence, from the usual population studies of European descent.
    var prevalence: String {
        switch self {
        case .protanopia: "1% of men"
        case .deuteranopia: "1% of men"
        case .tritanopia: "Very rare"
        case .protanomaly: "1% of men"
        case .deuteranomaly: "5% of men"
        case .tritanomaly: "Very rare"
        case .achromatopsia: "1 in 30,000"
        }
    }

    func matrix(severity: Double) -> Matrix3 {
        switch self {
        case .protanopia: Machado.protan[10]
        case .deuteranopia: Machado.deutan[10]
        case .tritanopia: Machado.tritan[10]
        case .protanomaly: Machado.matrix(Machado.protan, severity: severity)
        case .deuteranomaly: Machado.matrix(Machado.deutan, severity: severity)
        case .tritanomaly: Machado.matrix(Machado.tritan, severity: severity)
        case .achromatopsia: .luminance
        }
    }

    func next(by step: Int) -> Simulation {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + step + all.count) % all.count]
    }
}

/// The sRGB transfer function, as lookup tables so a whole image converts quickly.
enum SRGB {
    static func decode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    static let toLinear: [Float] = (0..<256).map { decode(Float($0) / 255) }
    static let steps = 16383
    static let toByte: [UInt8] = (0...steps).map { UInt8((encode(Float($0) / Float(steps)) * 255).rounded()) }

    static func byte(_ linear: Float) -> UInt8 {
        toByte[Int((min(max(linear, 0), 1) * Float(steps)).rounded())]
    }

    /// One colour through a matrix, in 8-bit sRGB.
    static func simulate(_ rgb: (UInt8, UInt8, UInt8), _ matrix: Matrix3) -> (UInt8, UInt8, UInt8) {
        let (r, g, b) = matrix.apply(toLinear[Int(rgb.0)], toLinear[Int(rgb.1)], toLinear[Int(rgb.2)])
        return (byte(r), byte(g), byte(b))
    }
}

/// An 8-bit sRGB image with straight (not premultiplied) alpha.
struct Bitmap: Sendable, Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    /// Draws `image` into sRGB, scaled down so its longest side is at most `maxSide`.
    init?(_ image: CGImage, maxSide: Int? = nil) {
        var w = image.width, h = image.height
        if let maxSide, max(w, h) > maxSide {
            let scale = Double(maxSide) / Double(max(w, h))
            w = max(1, Int((Double(w) * scale).rounded()))
            h = max(1, Int((Double(h) * scale).rounded()))
        }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Undo the premultiplication so colour maths sees the real colours of translucent pixels.
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] != 255 && data[i + 3] != 0 {
            let a = Int(data[i + 3])
            for c in 0..<3 { data[i + c] = UInt8(min(255, (Int(data[i + c]) * 255 + a / 2) / a)) }
        }
        self.init(width: w, height: h, pixels: data)
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Every pixel through `matrix` in linear light, alpha untouched. Splits the work across cores.
    func simulated(_ matrix: Matrix3) -> Bitmap {
        if matrix == .identity { return self }
        var out = pixels
        let count = width * height
        let chunks = max(1, min(count / 32768, 64))
        let m = matrix.m
        SRGB.toLinear.withUnsafeBufferPointer { lin in
            SRGB.toByte.withUnsafeBufferPointer { enc in
                pixels.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        let steps = Float(SRGB.steps)
                        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                            let start = count * chunk / chunks, end = count * (chunk + 1) / chunks
                            for p in start..<end {
                                let i = p * 4
                                let r = lin[Int(src[i])], g = lin[Int(src[i + 1])], b = lin[Int(src[i + 2])]
                                let o = (m[0] * r + m[1] * g + m[2] * b, m[3] * r + m[4] * g + m[5] * b, m[6] * r + m[7] * g + m[8] * b)
                                dst[i] = enc[Int((min(max(o.0, 0), 1) * steps).rounded())]
                                dst[i + 1] = enc[Int((min(max(o.1, 0), 1) * steps).rounded())]
                                dst[i + 2] = enc[Int((min(max(o.2, 0), 1) * steps).rounded())]
                            }
                        }
                    }
                }
            }
        }
        return Bitmap(width: width, height: height, pixels: out)
    }
}

enum ImageFile {
    /// Decodes an image file the right way up, up to 8192 px on its longest side.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source)
    }

    static func load(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source)
    }

    private static func decode(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8192,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

/// The largest size with `content`'s aspect ratio that fits inside `bounds`.
func fitted(_ content: CGSize, in bounds: CGSize) -> CGSize {
    guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / content.width, bounds.height / content.height)
    return CGSize(width: (content.width * scale).rounded(), height: (content.height * scale).rounded())
}

/// The hue of an 8-bit colour in degrees, for the self-test.
func hue(_ c: (UInt8, UInt8, UInt8)) -> Double {
    let r = Double(c.0) / 255, g = Double(c.1) / 255, b = Double(c.2) / 255
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    guard d > 0 else { return 0 }
    var h: Double
    if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    h *= 60
    return h < 0 ? h + 360 : h
}
