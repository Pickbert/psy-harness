import PDFKit
import XCTest
@testable import DesktopPet

final class ConsultationReportTests: XCTestCase {
    func testReportPromptDoesNotInferStudentIdentity() {
        XCTAssertTrue(ConsultationReport.reportSystemPrompt.contains("不得出现任何学生姓名"))
        XCTAssertTrue(ConsultationReport.reportSystemPrompt.contains("统一使用“学生”"))
        XCTAssertTrue(ConsultationReport.reportSystemPrompt.contains("不得从历史残留"))
    }

    func testReportTemplateIncludesRequiredConsultationSummarySections() {
        let titles = ConsultationReport.sectionDefinitions.map(\.title)
        XCTAssertTrue(titles.contains("谈话目标"))
        XCTAssertTrue(titles.contains("咨询过程主要内容"))
        XCTAssertTrue(titles.contains("行动计划"))
        XCTAssertTrue(titles.contains("行动的监督"))
        XCTAssertTrue(ConsultationReport.reportSystemPrompt.contains("本轮尚未形成具体的行动监督安排"))
        XCTAssertTrue(ConsultationReport.reportRequest.contains("<<<SUPERVISION>>>"))
        XCTAssertFalse(titles.contains("风险与待核实信息"))
        XCTAssertFalse(ConsultationReport.reportRequest.contains("<<<RISK>>>"))
        XCTAssertFalse(ConsultationReport.reportSystemPrompt.contains("待通过官方或可靠来源核实"))
    }

    func testParsesEveryStandardSectionInFixedOrder() throws {
        let generated = """
        <<<TOPIC>>>
        专业选择与职业方向探索
        <<<SUMMARY>>>
        学生正在比较计算机与工业设计，计划半年内确定申请方向。
        <<<NEEDS>>>
        喜欢解决实际问题，重视创造性与稳定成长。
        <<<RESOURCES>>>
        已了解两类专业课程，并有编程和绘画项目经验。
        <<<INSIGHTS>>>
        需要用真实项目体验比较两种方向，而不是只比较专业名称。
        <<<ACTIONS>>>
        两周内各完成一个小型体验项目，并记录投入感和困难。
        <<<SUPERVISION>>>
        学生每周日自行检查项目进度，两周后根据项目记录复盘并调整方向。
        <<<SUPPORT>>>
        可邀请老师、家长和相关专业在读学生提供反馈。
        """

        let report = try ConsultationReport.parseGeneratedText(
            generated,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(report.sections.map(\.title), ConsultationReport.sectionDefinitions.map(\.title))
        XCTAssertEqual(report.sections.first?.content, "专业选择与职业方向探索")
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
        XCTAssertTrue(text.contains("哈妮丝生涯规划报告"))
        XCTAssertTrue(text.contains("谈话目标"))
        XCTAssertTrue(text.contains("咨询过程主要内容"))
        XCTAssertTrue(text.contains("行动计划"))
        XCTAssertTrue(text.contains("行动的监督"))
        XCTAssertTrue(text.contains("不构成升学、录取、实习或就业保证"))
    }
}
