//
//  GlassInk.swift
//  BadNotes
//
//  Liquid Glass 잉크: 유리펜 획과 유리 글자.
//  모양(윤곽)을 받아서 유리처럼 그림 — 비치는 몸통 + 위쪽 안 테두리 빛 + 아래쪽 안 그늘 + 바깥 빛 테두리 + 그림자.
//  전부 벡터라 확대해도 선명하고, 같은 코드로 PDF에도 넣음 (PDF는 그라데이션·그림자 대신 면과 선으로).
//  화면에서는 이 밑에 진짜 Liquid Glass(UIGlassEffect)를 같은 모양으로 오려 깔아서 종이가 굴절돼 보임.
//
//  유리펜 획 표시: PKStroke.randomSeed 위 16비트를 0x6A55로, 다음 8비트에 진하기를 넣음.
//  (볼펜 잉크는 씨앗값을 그리는 데 안 써서 모양에는 영향이 없고, PKDrawing에 그대로 저장됨)
//

import UIKit
import PencilKit

nonisolated enum GlassInk {
    private static let tagMask: UInt32 = 0xFFFF_0000
    private static let tag: UInt32 = 0x6A55_0000

    /// 유리펜 획 씨앗값. salt는 같은 값이 겹치지 않게 (임시 획은 0)
    static func seed(strength: Double, salt: UInt32 = UInt32.random(in: 0...255)) -> UInt32 {
        let level = UInt32(min(255, max(0, (strength * 255).rounded())))
        return tag | (level << 8) | (salt & 0xFF)
    }

    static func isGlass(_ seed: UInt32) -> Bool { seed & tagMask == tag }

    static func isGlass(_ stroke: PKStroke) -> Bool { isGlass(stroke.randomSeed) }

    /// 0(거의 투명) ~ 1(진한 색 유리)
    static func strength(_ seed: UInt32) -> CGFloat { CGFloat((seed >> 8) & 0xFF) / 255 }

    /// 획 가운데선 → 일정한 굵기의 둥근 윤곽 (겹친 곳은 합쳐서 테두리가 깨끗하게)
    static func outline(centerline: CGPath, width: CGFloat) -> CGPath {
        centerline.copy(strokingWithWidth: max(0.5, width), lineCap: .round, lineJoin: .round, miterLimit: 4).normalized()
    }

    /// 윤곽을 유리처럼 그림. thickness = 획 굵기 (글자면 글자 크기의 1/8쯤): 빛·그늘 테두리 두께 기준
    static func draw(outline: CGPath, tint: CGColor, strength: CGFloat, thickness: CGFloat, forPDF: Bool,
                     in context: CGContext) {
        let t = max(1, thickness)
        let tintColor = UIColor(cgColor: tint)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        tintColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let deep = UIColor(hue: hue, saturation: min(1, saturation * 1.1), brightness: brightness * 0.55, alpha: 1)
        let bodyAlpha = 0.12 + strength * 0.62

        context.saveGState()
        // 1. 그림자 (종이에서 살짝 떠 있음)
        if forPDF {
            context.saveGState()
            context.translateBy(x: 0, y: t * 0.14)
            context.addPath(outline)
            context.setFillColor(UIColor(white: 0, alpha: 0.07).cgColor)
            context.fillPath()
            context.restoreGState()
        } else {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: t * 0.16), blur: t * 0.45,
                              color: UIColor(white: 0, alpha: 0.22).cgColor)
            context.addPath(outline)
            context.setFillColor(tintColor.withAlphaComponent(bodyAlpha * 0.6).cgColor)
            context.fillPath()
            context.restoreGState()
        }

        // 2. 몸통: 비치는 색 + 하얀 기
        context.addPath(outline)
        context.setFillColor(UIColor(white: 1, alpha: 0.16).cgColor)
        context.fillPath()
        context.addPath(outline)
        context.setFillColor(tintColor.withAlphaComponent(bodyAlpha).cgColor)
        context.fillPath()

        // 3. 안쪽 빛과 그늘: 윤곽 안으로 잘라서, 위아래로 민 테두리를 그음 → 위는 반짝, 아래는 깊게
        context.saveGState()
        context.addPath(outline)
        context.clip()
        if !forPDF {
            // 위에서 아래로 옅어지는 반사광
            let box = outline.boundingBoxOfPath
            let colors = [UIColor(white: 1, alpha: 0.42).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY),
                                           end: CGPoint(x: box.midX, y: box.minY + max(t, min(box.height * 0.6, t * 3))),
                                           options: [])
            }
        }
        context.saveGState()
        context.translateBy(x: 0, y: -t * 0.22)
        context.addPath(outline)
        context.setStrokeColor(deep.withAlphaComponent(0.32).cgColor)
        context.setLineWidth(t * 0.34)
        context.strokePath()
        context.restoreGState()
        context.saveGState()
        context.translateBy(x: -t * 0.04, y: t * 0.2)
        context.addPath(outline)
        context.setStrokeColor(UIColor(white: 1, alpha: 0.85).cgColor)
        context.setLineWidth(t * 0.22)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
        context.restoreGState()

        // 4. 바깥 테두리: 얇은 빛 + 더 얇은 색 선
        context.addPath(outline)
        context.setStrokeColor(UIColor(white: 1, alpha: 0.7).cgColor)
        context.setLineWidth(max(0.5, t * 0.07))
        context.setLineJoin(.round)
        context.strokePath()
        context.addPath(outline)
        context.setStrokeColor(deep.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(max(0.3, t * 0.03))
        context.strokePath()
        context.restoreGState()
    }
}

/// 누가 그은 획인지: BadNotes 필기 도구로 그은 획은 씨앗값 위 16비트에 0x6A54 (유리펜은 0x6A55).
/// 표시가 없는 획(Apple 필기 도구로 그은 것, 예전 파일)은 BadNotes 도구 모드에서도 Apple 렌더러로 그려서 똑같이 보이게 함
nonisolated enum InkOrigin {
    static let tag: UInt32 = 0x6A54_0000

    static func badNotesSeed(salt: UInt32 = UInt32.random(in: 1...0xFFFF)) -> UInt32 {
        tag | (salt & 0xFFFF)
    }

    static func isBadNotes(_ seed: UInt32) -> Bool {
        seed & 0xFFFF_0000 == tag || GlassInk.isGlass(seed) || BrushProfile(seed: seed) != nil
    }
}

/// 유리 글자: 글자 모양(글리프 윤곽)을 꺼냄. ElementRenderer와 같은 줄바꿈으로
nonisolated enum GlyphOutline {
    static func path(text: String, attributes: [NSAttributedString.Key: Any], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard !text.isEmpty, rect.width > 1 else { return path }
        let tall: CGFloat = 100_000
        let string = NSAttributedString(string: text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: tall), transform: nil), nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return path }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        // 코어텍스트는 위가 +y → 뒤집어서 rect 안(위가 원점)으로
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.minY + tall)
        for (line, origin) in zip(lines, origins) {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let fontValue = attrs[kCTFontAttributeName] else { continue }
                let font = fontValue as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for (glyph, position) in zip(glyphs, positions) {
                    guard let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                    let place = CGAffineTransform(translationX: origin.x + position.x, y: origin.y + position.y)
                        .concatenating(flip)
                    path.addPath(glyphPath, transform: place)
                }
            }
        }
        return path
    }
}
