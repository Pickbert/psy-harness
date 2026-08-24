import PDFKit
import XCTest
@testable import DesktopPet

final class ConsultationReportTests: XCTestCase {
    func testReportPromptDoesNotInferVisitorIdentity() {
        XCTAssertTrue(ConsultationReport.reportSystemPrompt.contains("不得出现任何来访者姓名"))
        XCTAssertTrue(ConsultationReport.reportSystemPrompt.contains("统一使用“来访者”"))
        XCTAssertTrue(ConsultationReport.reportSystemPrompt.contains("不得从历史残留"))
    }

    func testParsesEveryStandardSectionInFixedOrder() throws {
        let generated = """
        <<<TOPIC>>>
        工作压力与休息冲突
        <<<SUMMARY>>>
        来访者感到疲惫，同时担心停下来会落后。
        <<<NEEDS>>>
        希望获得安全感和可持续的节奏。
        <<<RESOURCES>>>
        已有稳定同事支持，也曾成功安排过短休息。
        <<<INSIGHTS>>>
        把休息视为维持长期状态的一部分。
        <<<ACTIONS>>>
        明天下午安排十分钟离开屏幕。
        <<<RISK>>>
        本轮未见明确紧急风险信号；此项不是诊断结论。
        <<<SUPPORT>>>
        如困扰持续影响睡眠和工作，可考虑寻求专业支持。
        """

        let report = try ConsultationReport.parseGeneratedText(
            generated,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(report.sections.map(\.title), ConsultationReport.sectionDefinitions.map(\.title))
        XCTAssertEqual(report.sections.first?.content, "工作压力与休息冲突")
        XCTAssertEqual(report.sections.count, 8)
    }

    func testRejectsMissingStandardSection() {
        XCTAssertThrowsError(try ConsultationReport.parseGeneratedText("<<<TOPIC>>>\n只有主题")) { error in
            XCTAssertEqual(error as? ConsultationReportError, .invalidGeneratedFormat)
        }
    }

    func testRendersReadablePDFWithDisclaimer() throws {
        let sections = ConsultationReport.sectionDefinitions.map {
            ConsultationReport.Section(title: $0.title, content: "这是“\($0.title)”的测试内容，用于检查中文换行与固定模板。")
        }
        let report = ConsultationReport(
            identifier: "QA2026",
            createdAt: Date(timeIntervalSince1970: 0),
            sections: sections
        )
        let directory = URL(fileURLWithPath: "/private/tmp/PsyPet-ConsultationReportTests", isDirectory: true)
        let output = directory.appendingPathComponent("consultation-report.pdf")

        try ConsultationReportPDFRenderer.render(report, to: output)

        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("哈妮丝心理咨询报告"))
        XCTAssertTrue(text.contains("本轮咨询主题"))
        XCTAssertTrue(text.contains("不构成心理或医学诊断"))
    }
}
