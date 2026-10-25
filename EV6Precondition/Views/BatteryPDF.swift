import Charts
import PreconditionKit
import SwiftUI

/// The battery report as an A4 PDF, laid out like a spec sheet, to keep or send to a buyer.
@MainActor
enum BatteryPDF {
    static let caveat = "This report is built from data the battery management system shares over the OBD port, read with a consumer adapter. It is not an official battery health certificate or a manufacturer's capacity test; for that, ask a dealer. Capacity is estimated from the pack's size and its reported state of health."

    static let page = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 36
    static let gap: CGFloat = 14
    /// Text size the PDF lays out at, whatever the phone's text size is set to.
    static let typeSize = DynamicTypeSize.large

    /// `demo`: read from the demo car, so every page is stamped as simulated.
    static func make(_ analysis: BatteryAnalysis, history: [HealthPoint], car: String, miles: Bool, demo: Bool = false) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(demo ? "DEMO " : "")\(car) battery report \(f.string(from: analysis.report.takenAt)).pdf")
        var box = CGRect(origin: .zero, size: page)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        // Each section starts a new page; its cards then flow onto as many pages as they need.
        var summary: [AnyView] = [AnyView(GradeCard(analysis: analysis, car: car)), AnyView(ChecksCard(checks: analysis.checks))]
        if !analysis.report.findings.isEmpty { summary.append(AnyView(FindingsCard(findings: analysis.report.findings))) }
        var sections = [summary]
        if analysis.cellCount > 1 {
            var cells = [AnyView(Card("Cells (\(analysis.cellCount))") { CellsSection(analysis: analysis) })]
            // Only packs made of whole six-cell modules have a module map.
            if !analysis.modules.isEmpty {
                cells.append(AnyView(Card("Modules") { ModuleGrid(modules: analysis.modules, mean: analysis.meanVolts ?? 0) }))
            }
            sections.append(cells)
        }
        var details: [AnyView] = [AnyView(Card("Pack") { PackRows(analysis: analysis) })]
        if analysis.report.tyrePressuresPsi.contains(where: { $0 != nil }) {
            details.append(AnyView(Card("Tyres") { TyreGrid(pressures: analysis.report.tyrePressuresPsi, temps: analysis.report.tyreTempsC) }))
        }
        if history.filter({ $0.sohPercent != nil }).count >= 2 {
            details.append(AnyView(Card("History") { HealthHistory(history: history) }))
        }
        sections.append(details)

        let generated = Date()
        let room = page.height - 2 * margin - height(of: PageChrome(car: car, date: analysis.report.takenAt, generated: generated, number: 9, of: 9, demo: demo)) - 2 * gap
        let pages = sections.flatMap { paginate($0, room: room) }
        for (i, cards) in pages.enumerated() {
            let view = PageFrame(number: i + 1, of: pages.count, car: car, date: analysis.report.takenAt, generated: generated, demo: demo) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(cards.indices, id: \.self) { cards[$0] }
                }
            }
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

    /// Fills pages in order, moving a card to the next page when it would run past the caveat and footer.
    private static func paginate(_ cards: [AnyView], room: CGFloat) -> [[AnyView]] {
        var pages: [[AnyView]] = []
        var current: [AnyView] = []
        var used: CGFloat = 0
        for card in cards {
            let h = height(of: card)
            let needed = current.isEmpty ? h : used + gap + h
            if !current.isEmpty && needed > room {
                pages.append(current)
                current = [card]
                used = h
            } else {
                current.append(card)
                used = needed
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// Height of a view laid out at the page's content width, as it will be drawn in the PDF.
    private static func height(of view: some View) -> CGFloat {
        let width = page.width - 2 * margin
        let renderer = ImageRenderer(content: view
            .frame(width: width, alignment: .leading)
            .dynamicTypeSize(typeSize)
            .environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        var h: CGFloat = 0
        renderer.render { size, _ in h = size.height }
        return h
    }
}

/// White A4 with the header and footer.
private struct PageFrame<Content: View>: View {
    let number: Int
    let of: Int
    let car: String
    let date: Date
    let generated: Date
    let demo: Bool
    let content: Content

    init(number: Int, of: Int, car: String, date: Date, generated: Date, demo: Bool, @ViewBuilder content: () -> Content) {
        self.number = number
        self.of = of
        self.car = car
        self.date = date
        self.generated = generated
        self.demo = demo
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BatteryPDF.gap) {
            PageHeader(car: car, date: date, demo: demo)
            content
            Spacer(minLength: 0)
            PageFooter(generated: generated, number: number, of: of, demo: demo)
        }
        .padding(BatteryPDF.margin)
        .frame(width: BatteryPDF.page.width, height: BatteryPDF.page.height, alignment: .topLeading)
        .background(Color.white)
        .dynamicTypeSize(BatteryPDF.typeSize)
        .environment(\.colorScheme, .light)
        .foregroundStyle(Color.black)
    }
}

/// The header and footer alone, measured to work out how much room a page has for cards.
private struct PageChrome: View {
    let car: String
    let date: Date
    let generated: Date
    let number: Int
    let of: Int
    let demo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BatteryPDF.gap) {
            PageHeader(car: car, date: date, demo: demo)
            PageFooter(generated: generated, number: number, of: of, demo: demo)
        }
    }
}

private struct PageHeader: View {
    let car: String
    let date: Date
    let demo: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BATTERY REPORT").font(.system(size: 18, weight: .heavy)).tracking(3)
                Text("\(car) · read \(date.formatted(date: .long, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppInfo.name.uppercased()).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.red)
        }
        Rectangle().fill(Color.red).frame(height: 2)
        if demo {
            Text("DEMO DATA – not a real vehicle. Simulated readings from the app's demo car.")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct PageFooter: View {
    let generated: Date
    let number: Int
    let of: Int
    let demo: Bool

    var body: some View {
        Text((demo ? "DEMO – simulated data, not from a real vehicle. " : "") + BatteryPDF.caveat)
            .font(.system(size: 7.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Text("Generated \(generated.formatted(date: .abbreviated, time: .shortened))")
            Spacer()
            Text("Page \(number) of \(of)")
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
    }
}

private struct FindingsCard: View {
    let findings: [String]

    var body: some View {
        Card("In short") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(findings, id: \.self) { Text("• " + $0).font(.system(size: 11)) }
            }
        }
    }
}
