import AppKit
import CoreGraphics
import CoreText
import Foundation

struct ConsultationReport: Equatable {
    struct Section: Equatable {
        let title: String
        let content: String
    }

    let identifier: String
    let createdAt: Date
    let sections: [Section]

    static let sectionDefinitions: [(marker: String, title: String)] = [
        ("TOPIC", "生涯议题与所处阶段"),
        ("SUMMARY", "学生现状与现实约束"),
        ("NEEDS", "兴趣、优势与价值偏好"),
        ("RESOURCES", "教育与职业方向"),
        ("INSIGHTS", "选项比较与判断依据"),
        ("ACTIONS", "行动计划与复盘节点"),
        ("RISK", "风险与待核实信息"),
        ("SUPPORT", "支持资源与下一步")
    ]

    static let reportSystemPrompt = """
    你是哈妮丝生涯规划报告整理助手。请基于本轮完整对话生成面向学生的职业与生涯规划记录，不替学生作决定，不承诺升学、录取、实习或就业结果，不推测对话中未出现的事实。

    写作要求：
    - 使用客观、清晰、尊重学生自主性的简体中文。
    - 除非学生在本轮对话中明确自述姓名并要求写入报告，否则不得出现任何学生姓名，统一使用“学生”；不得从历史残留、示例、文件名、设备信息或上下文元数据推断身份。
    - 区分学生自述、分析判断、外部事实与待核实信息；测评结果只能作为探索线索，不能作为定论。
    - 对未明确的信息写“本轮对话中未明确提及”，不要编造。
    - 涉及招生政策、院校、专业、行业、岗位、薪资或就业数据时，记录来源与时间；本轮未核实时明确标为“待通过官方或可靠来源核实”。
    - 行动计划必须来自学生表达或本轮共同确认的内容；如未形成行动，明确写“本轮尚未形成具体行动计划”。
    - 如对话出现自伤、自杀、伤人或其他紧急危险，只客观记录已出现的信号，并在支持资源中明确建议立即联系当地急救、危机干预资源、学校心理老师、专业人员或可信赖的现实支持者。
    - 不写寒暄，不使用 Markdown 标题，不输出代码围栏。
    """

    static let reportRequest = """
    请整理本轮生涯规划报告。必须严格按以下 8 个标记和顺序输出，每个标记单独占一行，标记之间填写对应内容，不得增删或改写标记：
    <<<TOPIC>>>
    <<<SUMMARY>>>
    <<<NEEDS>>>
    <<<RESOURCES>>>
    <<<INSIGHTS>>>
    <<<ACTIONS>>>
    <<<RISK>>>
    <<<SUPPORT>>>
    """

    static func parseGeneratedText(_ text: String, createdAt: Date = Date()) throws -> ConsultationReport {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var sections: [Section] = []

        for (index, definition) in sectionDefinitions.enumerated() {
            let marker = "<<<\(definition.marker)>>>"
            guard let markerRange = normalized.range(of: marker) else {
                throw ConsultationReportError.invalidGeneratedFormat
            }
            let contentStart = markerRange.upperBound
            let contentEnd: String.Index
            if index + 1 < sectionDefinitions.count {
                let nextMarker = "<<<\(sectionDefinitions[index + 1].marker)>>>"
                guard let nextRange = normalized.range(
                    of: nextMarker,
                    range: contentStart..<normalized.endIndex
                ) else {
                    throw ConsultationReportError.invalidGeneratedFormat
                }
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = normalized.endIndex
            }
            let content = normalized[contentStart..<contentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(Section(
                title: definition.title,
                content: content.isEmpty ? "本轮对话中未明确提及。" : content
            ))
        }

        return ConsultationReport(
            identifier: String(UUID().uuidString.prefix(8)).uppercased(),
            createdAt: createdAt,
            sections: sections
        )
    }
}

enum ConsultationReportError: LocalizedError, Equatable {
    case noConversation
    case invalidGeneratedFormat
    case cannotCreateOutputDirectory
    case cannotCreatePDF

    var errorDescription: String? {
        switch self {
        case .noConversation:
            return "本轮生涯规划还没有可用于生成报告的对话。"
        case .invalidGeneratedFormat:
            return "职业咨询模型返回的报告格式不完整，请重试。"
        case .cannotCreateOutputDirectory:
            return "无法创建生涯规划报告保存目录。"
        case .cannotCreatePDF:
            return "无法生成生涯规划报告 PDF。"
        }
    }
}

enum ConsultationReportPDFRenderer {
    private static let pageRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    private static let contentRect = CGRect(x: 56, y: 68, width: 483.28, height: 700)

    static func defaultOutputURL(for report: ConsultationReport) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ConsultationReportError.cannotCreateOutputDirectory
        }
        let directory = documents.appendingPathComponent("哈妮丝生涯规划报告", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConsultationReportError.cannotCreateOutputDirectory
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("哈妮丝生涯规划报告-\(formatter.string(from: report.createdAt)).pdf")
    }

    @discardableResult
    static func render(_ report: ConsultationReport, to outputURL: URL? = nil) throws -> URL {
        let url = try outputURL ?? defaultOutputURL(for: report)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ConsultationReportError.cannotCreatePDF
        }
        var mediaBox = pageRect
        let metadata = [
            kCGPDFContextTitle as String: "哈妮丝生涯规划报告",
            kCGPDFContextCreator as String: "哈妮丝职业咨询猫"
        ] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw ConsultationReportError.cannotCreatePDF
        }

        let attributed = makeAttributedReport(report)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        var pageNumber = 1
        while location < CFAttributedStringGetLength(attributed) {
            context.beginPDFPage(nil)
            drawPageChrome(in: context, report: report, pageNumber: pageNumber)
            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.endPDFPage()
                throw ConsultationReportError.cannotCreatePDF
            }
            location += visible.length
            context.endPDFPage()
            pageNumber += 1
        }
        context.closePDF()

        guard FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0
        else { throw ConsultationReportError.cannotCreatePDF }
        return url
    }

    private static func makeAttributedReport(_ report: ConsultationReport) -> CFAttributedString {
        let result = NSMutableAttributedString()
        let titleStyle = paragraphStyle(spacing: 8, lineHeight: 30)
        let subtitleStyle = paragraphStyle(spacing: 18, lineHeight: 17)
        let sectionStyle = paragraphStyle(spacing: 7, lineHeight: 22)
        let bodyStyle = paragraphStyle(spacing: 14, lineHeight: 17)

        result.append(NSAttributedString(
            string: "哈妮丝生涯规划报告\n",
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: pdfFont(size: 24, emphasized: true),
                .foregroundColor: NSColor(calibratedRed: 0.22, green: 0.31, blue: 0.42, alpha: 1),
                .paragraphStyle: titleStyle
            ]
        ))

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 HH:mm"
        result.append(NSAttributedString(
            string: "报告编号：\(report.identifier)    生成时间：\(dateFormatter.string(from: report.createdAt))\n\n",
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: pdfFont(size: 10),
                .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
                .paragraphStyle: subtitleStyle
            ]
        ))

        for (index, section) in report.sections.enumerated() {
            result.append(NSAttributedString(
                string: "\(index + 1). \(section.title)\n",
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: pdfFont(size: 14, emphasized: true),
                    .foregroundColor: NSColor(calibratedRed: 0.23, green: 0.39, blue: 0.56, alpha: 1),
                    .paragraphStyle: sectionStyle
                ]
            ))
            result.append(NSAttributedString(
                string: section.content + "\n\n",
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: pdfFont(size: 10.5),
                    .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1),
                    .paragraphStyle: bodyStyle
                ]
            ))
        }

        result.append(NSAttributedString(
            string: "重要说明\n本报告由 AI 根据本轮对话自动整理，仅用于学生的生涯探索与行动复盘，不构成升学、录取、实习或就业保证，也不能替代学校官方信息、持证升学指导、劳动法律意见或心理医疗服务。涉及重大教育与职业决定时，请与家长、学校及相关专业人员核实。",
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: pdfFont(size: 9.5, emphasized: true),
                .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.22, alpha: 1),
                .paragraphStyle: bodyStyle
            ]
        ))
        return result
    }

    private static func paragraphStyle(spacing: CGFloat, lineHeight: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func pdfFont(size: CGFloat, emphasized: Bool = false) -> CTFont {
        CTFontCreateWithName(
            (emphasized ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString,
            size,
            nil
        )
    }

    private static func drawPageChrome(in context: CGContext, report: ConsultationReport, pageNumber: Int) {
        context.saveGState()
        context.setFillColor(NSColor(calibratedRed: 0.36, green: 0.60, blue: 0.78, alpha: 1).cgColor)
        context.fill(CGRect(x: 56, y: 790, width: 483.28, height: 3))
        let gray = NSColor(calibratedWhite: 0.42, alpha: 1)
        drawLine("哈妮丝 · 职业咨询猫", at: CGPoint(x: 56, y: 804), size: 9, color: gray, in: context)
        drawLine("第 \(pageNumber) 页 · 报告编号 \(report.identifier)", at: CGPoint(x: 378, y: 34), size: 8.5, color: gray, in: context)
        context.restoreGState()
    }

    private static func drawLine(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: pdfFont(size: size),
                .foregroundColor: color
            ]
        ))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
