//
//  PaperRenderer.swift
//  BadNotes
//
//  종이·표지를 코드로 그림 (이미지 파일 없음). 같은 코드로
//  - 새 노트북 PDF (표지 + 첫 장), 덧붙일 종이 한 장 PDF
//  - 새 노트북 화면의 미리보기
//  를 만듦. 좌표는 UIKit 기준 (위쪽이 원점).
//

import UIKit

nonisolated enum PaperRenderer {
    // MARK: 종이

    /// lineScale: 미리보기처럼 작게 줄여 그릴 때 선이 사라지지 않게 굵게
    static func drawPaper(_ spec: PaperSpec, in context: CGContext, rect: CGRect, lineScale: CGFloat = 1) {
        context.saveGState()
        context.setFillColor(spec.tone.paper.cgColor)
        context.fill(rect)
        context.setStrokeColor(spec.tone.line.cgColor)
        context.setFillColor(spec.tone.line.cgColor)

        switch spec.template {
        case .blank:
            break
        case .dotted:
            let step: CGFloat = 20, radius: CGFloat = 0.9 * min(lineScale, 3)
            var y = rect.minY + step
            while y < rect.maxY - 4 {
                var x = rect.minX + step
                while x < rect.maxX - 4 {
                    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step
            }
        case .grid:
            let step: CGFloat = 20
            context.setLineWidth(0.5 * lineScale)
            var x = rect.minX + step
            while x < rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += step
            }
            var y = rect.minY + step
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += step
            }
            context.strokePath()
        case .ruledNarrow, .ruledWide:
            let narrow = spec.template == .ruledNarrow
            let step: CGFloat = narrow ? 22 : 32
            var y = rect.minY + (narrow ? 66 : 80)
            context.setLineWidth(0.6 * lineScale)
            while y < rect.maxY - 30 {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += step
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: 표지

    static func drawCover(_ cover: CoverStyle, title: String?, in context: CGContext, rect: CGRect) {
        let (base, detail) = cover.colors
        let w = rect.width, h = rect.height
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        context.saveGState()
        context.setFillColor(base.cgColor)
        context.fill(rect)

        switch cover {
        case .stripes:
            context.setStrokeColor(detail.withAlphaComponent(0.16).cgColor)
            context.setLineWidth(w * 0.035)
            var x = -h
            while x < w {
                context.move(to: CGPoint(x: rect.minX + x, y: rect.minY))
                context.addLine(to: CGPoint(x: rect.minX + x + h, y: rect.maxY))
                x += w * 0.11
            }
            context.strokePath()
        case .waves:
            context.setStrokeColor(detail.withAlphaComponent(0.22).cgColor)
            context.setLineWidth(max(1, w * 0.006))
            for row in 0..<14 {
                let y0 = rect.minY + h * (0.06 + 0.068 * CGFloat(row))
                context.move(to: CGPoint(x: rect.minX, y: y0))
                var x: CGFloat = 0
                while x <= w {
                    context.addLine(to: CGPoint(x: rect.minX + x, y: y0 + sin(x / w * .pi * 4 + CGFloat(row)) * h * 0.012))
                    x += 4
                }
            }
            context.strokePath()
        case .dots:
            context.setFillColor(detail.withAlphaComponent(0.3).cgColor)
            let step = w * 0.09, radius = w * 0.016
            var row = 0
            var y = rect.minY + step / 2
            while y < rect.maxY {
                var x = rect.minX + (row % 2 == 0 ? step / 2 : step)
                while x < rect.maxX {
                    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step * 0.87
                row += 1
            }
        case .linen:
            context.setStrokeColor(detail.withAlphaComponent(0.07).cgColor)
            context.setLineWidth(0.6)
            var x = rect.minX
            while x < rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += 3
            }
            var y = rect.minY
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += 3
            }
            context.strokePath()
        default:
            // 단색 표지: 위는 살짝 밝게, 아래는 살짝 어둡게.
            // PDF 그라데이션은 투명도를 못 담아서(불투명 흑백으로 칠해짐) 섞은 색을 직접 계산해서 씀
            linearGradient([mixed(base, .white, 0.1), mixed(base, .black, 0.12)], in: context,
                           from: CGPoint(x: rect.midX, y: rect.minY), to: CGPoint(x: rect.midX, y: rect.maxY))
        }

        // 책등 그림자 (역시 섞은 색으로)
        context.saveGState()
        context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: w * 0.06, height: h))
        linearGradient([mixed(base, .black, 0.28), base.cgColor], in: context,
                       from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.minX + w * 0.06, y: rect.midY))
        context.restoreGState()

        // 제목 라벨
        if let title, !title.isEmpty {
            let label = CGRect(x: rect.minX + w * 0.16, y: rect.minY + h * 0.18, width: w * 0.68, height: h * 0.11)
            detail.withAlphaComponent(0.93).setFill()
            UIBezierPath(roundedRect: label, cornerRadius: w * 0.02).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let font = UIFont.systemFont(ofSize: min(w * 0.055, label.height * 0.42), weight: .semibold)
            let text = NSAttributedString(string: title, attributes: [
                .font: font, .foregroundColor: base, .paragraphStyle: paragraph,
            ])
            let textHeight = font.lineHeight
            text.draw(in: CGRect(x: label.minX + 8, y: label.midY - textHeight / 2,
                                 width: label.width - 16, height: textHeight))
        }
        context.restoreGState()
    }

    /// 불투명한 두 색 사이 그라데이션
    private static func linearGradient(_ colors: [CGColor], in context: CGContext, from start: CGPoint, to end: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                        locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// color에 other를 amount만큼 섞은 불투명 색
    private static func mixed(_ color: UIColor, _ other: UIColor, _ amount: CGFloat) -> CGColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return CGColor(srgbRed: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    // MARK: PDF

    /// 덧붙일 종이 한 장
    static func pagePDF(_ spec: PaperSpec) -> Data {
        let rect = CGRect(origin: .zero, size: spec.pageSize)
        return UIGraphicsPDFRenderer(bounds: rect).pdfData { context in
            context.beginPage()
            drawPaper(spec, in: context.cgContext, rect: rect)
        }
    }

    /// 새 노트북: (표지) + 종이 한 장. 종이 정보는 PDF 키워드에
    static func notebookPDF(name: String, cover: CoverStyle?, paper: PaperSpec) -> Data {
        let rect = CGRect(origin: .zero, size: paper.pageSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: name,
            kCGPDFContextCreator as String: "BadNotes",
            kCGPDFContextKeywords as String: ["BadNotes", paper.keyword] + (cover.map { ["\(PaperSpec.coverPrefix)\($0.rawValue)"] } ?? []),
        ]
        return UIGraphicsPDFRenderer(bounds: rect, format: format).pdfData { context in
            if let cover {
                context.beginPage()
                drawCover(cover, title: name, in: context.cgContext, rect: rect)
            }
            context.beginPage()
            drawPaper(paper, in: context.cgContext, rect: rect)
        }
    }
}

/// 새 노트북 화면 미리보기 (그린 그림은 기억해 둠)
enum PaperPreviews {
    private static var cache: [String: UIImage] = [:]

    static func paper(_ spec: PaperSpec, height: CGFloat) -> UIImage {
        let key = "p|\(spec.keyword)|\(Int(height))"
        if let hit = cache[key] { return hit }
        let lineScale = max(1, 1.1 * spec.pageSize.height / height)
        let image = render(page: spec.pageSize, height: height) { context, rect in
            PaperRenderer.drawPaper(spec, in: context, rect: rect, lineScale: lineScale)
        }
        cache[key] = image
        return image
    }

    static func cover(_ style: CoverStyle, title: String, page: CGSize, height: CGFloat) -> UIImage {
        let key = "c|\(style.rawValue)|\(title)|\(Int(page.width))x\(Int(page.height))|\(Int(height))"
        if let hit = cache[key] { return hit }
        let image = render(page: page, height: height) { context, rect in
            PaperRenderer.drawCover(style, title: title, in: context, rect: rect)
        }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = image
        return image
    }

    private static func render(page: CGSize, height: CGFloat, draw: (CGContext, CGRect) -> Void) -> UIImage {
        let scale = height / page.height
        let size = CGSize(width: page.width * scale, height: height)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.scaleBy(x: scale, y: scale)
            draw(context.cgContext, CGRect(origin: .zero, size: page))
        }
    }
}
