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
        ("TOPIC", "本轮咨询主题"),
        ("SUMMARY", "情绪与事实摘要"),
        ("NEEDS", "核心需要与价值"),
        ("RESOURCES", "已有资源与支持"),
        ("INSIGHTS", "本轮关键洞察"),
        ("ACTIONS", "约定的下一步"),
        ("RISK", "风险关注"),
        ("SUPPORT", "专业支持建议")
    ]

    static let reportSystemPrompt = """
    你是哈妮丝心理咨询报告整理助手。请基于本轮完整对话生成支持性咨询记录，不进行心理或医学诊断，不给来访者贴标签，不推测对话中未出现的事实。

    写作要求：
    - 使用温和、客观、尊重自主性的简体中文。
    - 除非来访者在本轮对话中明确自述姓名并要求写入报告，否则不得出现任何来访者姓名，统一使用“来访者”；不得从历史残留、示例、文件名、设备信息或上下文元数据推断身份。
    - 区分事实、感受、解释、需要、资源与行动。
    - 对未明确的信息写“本轮对话中未明确提及”，不要编造。
    - 风险关注只能描述对话中出现的信号并标明“非诊断结论”。若出现明确自伤、自杀、伤人或其他紧急危险，专业支持建议必须明确写出立即联系当地急救、危机干预资源、专业人员或可信赖的身边人。
    - 下一步必须来自对话中来访者表达或共同确认的内容；如未形成行动，明确写“本轮尚未形成具体行动约定”。
    - 不写寒暄，不使用 Markdown 标题，不输出代码围栏。
    """

    static let reportRequest = """
    请整理本轮咨询报告。必须严格按以下 8 个标记和顺序输出，每个标记单独占一行，标记之间填写对应内容，不得增删或改写标记：
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
            return "本轮咨询还没有可用于生成报告的对话。"
        case .invalidGeneratedFormat:
            return "咨询模型返回的报告格式不完整，请重试。"
        case .cannotCreateOutputDirectory:
            return "无法创建咨询报告保存目录。"
        case .cannotCreatePDF:
            return "无法生成咨询报告 PDF。"
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
        let directory = documents.appendingPathComponent("哈妮丝咨询报告", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConsultationReportError.cannotCreateOutputDirectory
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("哈妮丝心理咨询报告-\(formatter.string(from: report.createdAt)).pdf")
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
            kCGPDFContextTitle as String: "哈妮丝心理咨询报告",
            kCGPDFContextCreator as String: "哈妮丝心理咨询猫"
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
            string: "哈妮丝心理咨询报告\n",
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
            string: "重要说明\n本报告由 AI 根据本轮对话自动整理，仅用于个人回顾与自我梳理，不构成心理或医学诊断，也不能替代持证心理咨询、医疗服务或紧急援助。如存在现实危险或紧急风险，请立即联系当地急救、危机干预资源、专业人员或可信赖的身边人。",
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
        drawLine("哈妮丝 · 心理咨询猫", at: CGPoint(x: 56, y: 804), size: 9, color: gray, in: context)
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
