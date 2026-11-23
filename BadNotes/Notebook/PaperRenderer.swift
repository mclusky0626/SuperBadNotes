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
        CoverArt.draw(cover, title: title, in: context, rect: rect)
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

    /// 화이트보드: 아주 큰 빈 페이지 한 장 (점 무늬는 앱이 화면에만 그림 → 파일이 가벼움)
    static func boardPDF(name: String) -> Data {
        let side = PaperSpec.boardSide
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: name,
            kCGPDFContextCreator as String: "BadNotes",
            kCGPDFContextKeywords as String: ["BadNotes", PaperSpec.boardKeyword],
        ]
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: side, height: side), format: format).pdfData { context in
            context.beginPage()
        }
    }

    /// 표지 한 장짜리 PDF (표지 바꾸기)
    static func coverPDF(_ cover: CoverStyle, title: String, size: CGSize) -> Data {
        let rect = CGRect(origin: .zero, size: size)
        return UIGraphicsPDFRenderer(bounds: rect).pdfData { context in
            context.beginPage()
            drawCover(cover, title: title, in: context.cgContext, rect: rect)
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
