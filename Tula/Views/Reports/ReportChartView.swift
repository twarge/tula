import Charts
import ERPNextKit
import SwiftUI

/// Native rendering of a report's chart payload (`query_report.run` returns
/// Frappe Charts config; we map it onto Swift Charts).
struct ReportChartView: View {
    let chart: ReportChart

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let series: String
        let value: Double
    }

    private var points: [Point] {
        var points: [Point] = []
        for (seriesIndex, dataset) in chart.datasets.enumerated() {
            let series = dataset.name ?? "Series \(seriesIndex + 1)"
            for (index, value) in dataset.values.enumerated()
            where index < chart.labels.count {
                points.append(
                    Point(
                        id: seriesIndex * 10_000 + index,
                        label: chart.labels[index],
                        series: series,
                        value: value))
            }
        }
        return points
    }

    private var isPie: Bool {
        ["pie", "percentage", "donut"].contains(chart.type)
    }

    var body: some View {
        Chart(isPie ? Array(points.prefix(chart.labels.count)) : points) { point in
            if isPie {
                SectorMark(
                    angle: .value("Value", point.value),
                    innerRadius: .ratio(chart.type == "donut" ? 0.6 : 0),
                    angularInset: 1)
                    .foregroundStyle(by: .value("Label", point.label))
            } else if chart.type == "line" {
                LineMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .symbol(by: .value("Series", point.series))
            } else {
                BarMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .position(by: .value("Series", point.series))
            }
        }
        .chartLegend(chart.datasets.count > 1 || isPie ? .visible : .hidden)
        .frame(height: 200)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
