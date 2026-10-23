import Charts
import PreconditionKit
import SwiftUI

/// The battery report as an A4 PDF, laid out like a spec sheet, to keep or send to a buyer.
@MainActor
enum BatteryPDF {
    static let caveat = "This report is built from data the battery management system shares over the OBD port, read with a consumer adapter. It is not an official battery health certificate or a manufacturer's capacity test; for that, ask a dealer. Capacity is estimated from the pack's size and its reported state of health."

    static let page = CGSize(width: 595, height: 842)

    static func make(_ analysis: BatteryAnalysis, history: [HealthPoint], car: String, miles: Bool) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(car) battery report \(f.string(from: analysis.report.takenAt)).pdf")
        var box = CGRect(origin: .zero, size: page)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        var pages: [AnyView] = [AnyView(SummaryPage(analysis: analysis, car: car))]
        if analysis.cellCount > 1 { pages.append(AnyView(CellsPage(analysis: analysis, car: car))) }
        pages.append(AnyView(DetailsPage(analysis: analysis, history: history, car: car)))
        for (i, content) in pages.enumerated() {
            let view = PageFrame(number: i + 1, of: pages.count, car: car, date: analysis.report.takenAt) { content }
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(page)
            renderer.render { _, draw in
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        return url
    }
}

/// White A4 with the header and footer.
private struct PageFrame<Content: View>: View {
    let number: Int
    let of: Int
    let car: String
    let date: Date
    let content: Content

    init(number: Int, of: Int, car: String, date: Date, @ViewBuilder content: () -> Content) {
        self.number = number
        self.of = of
        self.car = car
        self.date = date
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BATTERY REPORT").font(.system(size: 18, weight: .heavy)).tracking(3)
                    Text("\(car) · read \(date.formatted(date: .long, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(AppInfo.name.uppercased()).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.red)
            }
            Rectangle().fill(Color.red).frame(height: 2)
            content
            Spacer(minLength: 0)
            Text(BatteryPDF.caveat)
                .font(.system(size: 7.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Generated \(Date().formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Text("Page \(number) of \(of)")
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: BatteryPDF.page.width, height: BatteryPDF.page.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(Color.black)
    }
}

private struct SummaryPage: View {
    let analysis: BatteryAnalysis
    let car: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GradeCard(analysis: analysis, car: car)
            ChecksCard(checks: analysis.checks)
            if !analysis.report.findings.isEmpty {
                Card("In short") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(analysis.report.findings, id: \.self) { Text("• " + $0).font(.system(size: 11)) }
                    }
                }
            }
        }
    }
}

private struct CellsPage: View {
    let analysis: BatteryAnalysis
    let car: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card("Cells (\(analysis.cellCount))") { CellsSection(analysis: analysis) }
            Card("Modules") { ModuleGrid(modules: analysis.modules, mean: analysis.meanVolts ?? 0) }
        }
    }
}

private struct DetailsPage: View {
    let analysis: BatteryAnalysis
    let history: [HealthPoint]
    let car: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card("Pack") { PackRows(analysis: analysis) }
            if analysis.report.tyrePressuresPsi.contains(where: { $0 != nil }) {
                Card("Tyres") { TyreGrid(pressures: analysis.report.tyrePressuresPsi, temps: analysis.report.tyreTempsC) }
            }
            if history.filter({ $0.sohPercent != nil }).count >= 2 {
                Card("History") { HealthHistory(history: history) }
            }
        }
    }
}
