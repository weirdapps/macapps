import AppKit
import Charts
import Kit
import SwiftUI

/// One plotted value: a row of one series.
struct PlotPoint: Identifiable {
    var id: String { "\(series)|\(row)" }
    var series: String
    var row: Int
    var label: String
    var x: Double
    var value: Double
}

extension PlotChart {
    var points: [PlotPoint] {
        let labels = table.labels, xs = table.xValues
        return table.series.flatMap { s in
            s.values.enumerated().compactMap { row, value in
                value.map { PlotPoint(series: s.name, row: row, label: labels[row], x: xs[row], value: $0) }
            }
        }
    }

    /// Pie slices: the first series, positive values only.
    var slices: [PlotPoint] {
        let labels = table.labels
        guard let first = table.series.first else { return [] }
        return first.values.enumerated().compactMap { row, value in
            guard let value, value > 0 else { return nil }
            return PlotPoint(series: first.name, row: row, label: labels[row], x: Double(row), value: value)
        }
    }

    /// The names the colour scale maps: series, or slice labels for a pie.
    var legendNames: [String] { kind == .pie ? slices.map(\.label) : table.series.map(\.name) }

    var isPlottable: Bool { kind == .pie ? !slices.isEmpty : !points.isEmpty }
}

/// The chart with its title, as shown in the window and exported to images.
struct ChartCanvas: View {
    let chart: PlotChart
    var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !chart.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(chart.title)
                    .font(.system(size: exporting ? 24 : 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            PlotChartView(chart: chart)
        }
        .padding(exporting ? 32 : 22)
    }
}

struct PlotChartView: View {
    let chart: PlotChart

    var body: some View {
        Group {
            switch chart.kind {
            case .pie: PieChart(chart: chart)
            case .scatter: ScatterChart(chart: chart)
            default: CategoryChart(chart: chart)
            }
        }
        .chartForegroundStyleScale(domain: chart.legendNames, range: chart.palette.colors(chart.legendNames.count))
        .chartLegend(chart.showLegend ? .visible : .hidden)
        .animation(.snappy, value: chart.kind)
    }
}

private struct ValueLabel: View {
    let value: Double
    var inside = false

    var body: some View {
        Text(Number.short(value))
            .font(.system(size: 10, weight: inside ? .semibold : .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(inside ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
    }
}

/// Line, bar, stacked bar and area: labels along x, in row order.
struct CategoryChart: View {
    let chart: PlotChart

    var body: some View {
        let x = chart.xLabel.isEmpty ? "Label" : chart.xLabel
        let y = chart.yLabel.isEmpty ? "Value" : chart.yLabel
        let values = chart.showValues
        Chart(chart.points) { p in
            switch chart.kind {
            case .line:
                LineMark(x: .value(x, p.label), y: .value(y, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                PointMark(x: .value(x, p.label), y: .value(y, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .symbolSize(28)
                    .annotation(position: .top, spacing: 4) { if values { ValueLabel(value: p.value) } }
            case .area:
                AreaMark(x: .value(x, p.label), y: .value(y, p.value), stacking: .unstacked)
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                    .opacity(0.22)
                LineMark(x: .value(x, p.label), y: .value(y, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .annotation(position: .top, spacing: 4) { if values { ValueLabel(value: p.value) } }
            case .stacked:
                BarMark(x: .value(x, p.label), y: .value(y, p.value), width: .ratio(0.62))
                    .foregroundStyle(by: .value("Series", p.series))
                    .annotation(position: .overlay) { if values { ValueLabel(value: p.value, inside: true) } }
            default:
                BarMark(x: .value(x, p.label), y: .value(y, p.value), width: .ratio(0.86))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series), axis: .horizontal, span: .ratio(0.78))
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 3) { if values { ValueLabel(value: p.value) } }
            }
        }
        .chartXScale(domain: chart.table.labels)
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxisLabel(chart.xLabel, alignment: .center)
        .chartYAxisLabel(chart.yLabel, position: .leading, alignment: .center)
    }
}

struct ScatterChart: View {
    let chart: PlotChart

    var body: some View {
        let x = chart.xLabel.isEmpty ? "X" : chart.xLabel
        let y = chart.yLabel.isEmpty ? "Y" : chart.yLabel
        let values = chart.showValues
        Chart(chart.points) { p in
            PointMark(x: .value(x, p.x), y: .value(y, p.value))
                .foregroundStyle(by: .value("Series", p.series))
                .symbol(by: .value("Series", p.series))
                .symbolSize(70)
                .annotation(position: .top, spacing: 3) { if values { ValueLabel(value: p.value) } }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxisLabel(chart.xLabel, alignment: .center)
        .chartYAxisLabel(chart.yLabel, position: .leading, alignment: .center)
    }
}

struct PieChart: View {
    let chart: PlotChart

    var body: some View {
        let slices = chart.slices
        let total = slices.reduce(0) { $0 + $1.value }
        let values = chart.showValues
        Chart(slices) { p in
            SectorMark(angle: .value("Value", p.value), angularInset: 1.5)
                .foregroundStyle(by: .value("Label", p.label))
                .cornerRadius(5)
                .annotation(position: .overlay) {
                    if values, p.value / total >= 0.06 {
                        Text((p.value / total).formatted(.percent.precision(.fractionLength(0...1))))
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                }
        }
        .chartLegend(position: .trailing, alignment: .center, spacing: 24)
        .padding(.horizontal, 8)
    }
}

// MARK: - Export

@MainActor
enum Exporter {
    /// Exported charts are 960 by 600 points, on white, in light mode, at the chosen scale.
    static let size = CGSize(width: 960, height: 600)

    private static func renderer(_ chart: PlotChart) -> ImageRenderer<some View> {
        ImageRenderer(content: ChartCanvas(chart: chart, exporting: true)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light))
    }

    static func image(_ chart: PlotChart, scale: CGFloat) -> NSBitmapImageRep? {
        let r = renderer(chart)
        r.scale = scale
        guard let cg = r.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        return rep
    }

    static func png(_ chart: PlotChart, scale: CGFloat) -> Data? {
        image(chart, scale: scale)?.representation(using: .png, properties: [:])
    }

    /// A vector PDF of the chart, one page the size of the chart.
    static func pdf(_ chart: PlotChart) -> Data {
        let data = NSMutableData()
        renderer(chart).render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return data as Data
    }

    static func copy(_ chart: PlotChart) -> Bool {
        guard let rep = image(chart, scale: 2), let png = rep.representation(using: .png, properties: [:]) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        return true
    }

    static func fileName(_ chart: PlotChart) -> String {
        let name = chart.title.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Chart" : name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// A save panel for PNG (with a scale choice) or PDF, then writes the file and offers Show in Finder.
    static func export(_ chart: PlotChart, pdf: Bool, model: PlotModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : .png]
        panel.nameFieldStringValue = fileName(chart) + (pdf ? ".pdf" : ".png")
        panel.canCreateDirectories = true
        panel.message = pdf ? "Export as a vector PDF" : "Export as a PNG image"
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        if !pdf {
            popup.addItems(withTitles: ["1x (960 × 600)", "2x (1920 × 1200)", "3x (2880 × 1800)"])
            popup.selectItem(at: 1)
            let label = NSTextField(labelWithString: "Scale:")
            let stack = NSStackView(views: [label, popup])
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
            panel.accessoryView = stack
        }
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let data = pdf ? Exporter.pdf(chart) : Exporter.png(chart, scale: CGFloat(popup.indexOfSelectedItem + 1))
            do {
                guard let data else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
                model.show(Toast(message: "Exported \(url.lastPathComponent)", url: url))
            } catch {
                model.show(Toast(message: "Could not export: \(error.localizedDescription)"))
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }
}
