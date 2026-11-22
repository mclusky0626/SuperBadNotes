//
//  InkRenderer.swift
//  BadNotes
//
//  PKDrawing → 벡터 경로. PDF에 들어가는 "보이는 모양"을 그림.
//  BadNotes 안에서는 PencilKit이 직접 그리므로, 이건 다른 앱에서 보이는 모습용.
//  - 굵기가 변하는 획: 굵기가 같은 구간끼리 끊어서 둥근 끝 선으로 그림
//  - 반투명 잉크(형광펜 등): 획 전체를 경로 하나로 한 번에 칠해서 겹친 부분이 진해지지 않게
//    (투명 레이어는 PDFKit이 저장하면서 깨뜨려서 못 씀)
//  - 픽셀 지우개로 지운 부분: 획의 마스크로 잘라 냄
//  - 연필 질감 같은 건 투명도로 근사
//

import PencilKit
import UIKit

nonisolated enum InkRenderer {
    /// PDF 종이는 항상 흰색이라 잉크 색은 라이트 모드 기준으로 고정
    private static let lightTraits = UITraitCollection(userInterfaceStyle: .light)

    static func draw(_ drawing: PKDrawing, in context: CGContext, transform: CGAffineTransform) {
        context.saveGState()
        context.concatenate(transform)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in drawing.strokes {
            draw(stroke, in: context)
        }
        context.restoreGState()
    }

    static func draw(_ stroke: PKStroke, in context: CGContext) {
        let inkType = stroke.ink.inkType
        let nominal = max(0.3, stroke.path.first.map { tipWidth($0, inkType) } ?? 1)
        let step = min(1.5, max(0.4, nominal * 0.35))
        let points = Array(stroke.path.interpolatedPoints(by: .distance(step)))
        guard !points.isEmpty else { return }

        let color = stroke.ink.color.resolvedColor(with: lightTraits).cgColor
        let look = look(for: inkType)
        let meanOpacity = points.reduce(0) { $0 + $1.opacity } / CGFloat(points.count)
        let alpha = min(1, max(0, color.alpha * meanOpacity * look.alpha))
        guard alpha > 0.01 else { return }
        let opaque = color.copy(alpha: 1) ?? color

        context.saveGState()
        applyTransformAndMask(stroke, in: context)
        context.setStrokeColor(opaque)
        context.setFillColor(opaque)

        if alpha < 0.999 || look.blend != .normal {
            // 반투명: 투명 레이어는 쓰면 안 됨. PDFKit이 appearance를 저장할 때 레이어(Form XObject)를
            // 리소스에서 빠뜨려서 다른 앱에서 통째로 안 보임 (자체 점검으로 확인).
            // 대신 획 전체를 경로 하나로 한 번에 칠함 → 겹친 부분도 한 번만 칠해져서 진해지지 않음
            context.setAlpha(alpha)
            context.setBlendMode(look.blend)
            let meanWidth = points.reduce(0) { $0 + tipWidth($1, inkType) } / CGFloat(points.count)
            strokeSinglePath(points, width: meanWidth, in: context)
        } else {
            strokeRun(points, inkType, in: context)
        }
        context.restoreGState()
    }

    // MARK: - 내부

    private struct Look {
        var alpha: CGFloat
        var blend: CGBlendMode
    }

    private static func look(for ink: PKInk.InkType) -> Look {
        switch ink {
        case .marker: Look(alpha: 0.55, blend: .multiply)
        case .watercolor: Look(alpha: 0.5, blend: .multiply)
        case .pencil: Look(alpha: 0.85, blend: .normal)
        case .crayon: Look(alpha: 0.9, blend: .normal)
        default: Look(alpha: 1, blend: .normal)
        }
    }

    private static func tipWidth(_ point: PKStrokePoint, _ ink: PKInk.InkType) -> CGFloat {
        switch ink {
        case .marker: max(point.size.width, point.size.height)
        case .fountainPen: (point.size.width + point.size.height) / 2
        default: point.size.width
        }
    }

    /// 획의 변환을 적용하고, 지운 부분이 있으면 마스크로 자름.
    /// 마스크가 경로 좌표인지 변환 후 좌표인지 문서에 명확하지 않아서 겹치는 쪽을 고름.
    private static func applyTransformAndMask(_ stroke: PKStroke, in context: CGContext) {
        guard let mask = stroke.mask else {
            context.concatenate(stroke.transform)
            return
        }
        let maskBounds = mask.bounds
        let drawn = stroke.renderBounds
        let inverse = stroke.transform.inverted()
        if maskBounds.intersects(drawn.applying(inverse)) {
            context.concatenate(stroke.transform)
            context.addPath(mask.cgPath)
            context.clip()
        } else if maskBounds.intersects(drawn) {
            context.addPath(mask.cgPath)
            context.clip()
            context.concatenate(stroke.transform)
        } else {
            // 판단이 안 되면 안 자르고 그림 (안 보이는 것보다 낫다)
            context.concatenate(stroke.transform)
        }
    }

    /// 콕 찍은 점처럼 거의 길이가 없는 획이면 원으로 칠하고 true
    private static func fillIfDot(_ points: [PKStrokePoint], width: CGFloat, in context: CGContext) -> Bool {
        guard let first = points.first else { return true }
        var length: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            length += hypot(b.location.x - a.location.x, b.location.y - a.location.y)
        }
        guard points.count == 1 || length < 0.25 else { return false }
        let w = max(0.3, width)
        context.fillEllipse(in: CGRect(x: first.location.x - w / 2, y: first.location.y - w / 2, width: w, height: w))
        return true
    }

    /// 굵기 하나로 획 전체를 한 번에 그림 (반투명 잉크용)
    private static func strokeSinglePath(_ points: [PKStrokePoint], width: CGFloat, in context: CGContext) {
        guard let first = points.first, !fillIfDot(points, width: width, in: context) else { return }
        context.setLineWidth(max(0.1, width))
        context.move(to: first.location)
        for point in points.dropFirst() {
            context.addLine(to: point.location)
        }
        context.strokePath()
    }

    /// 굵기가 같은 구간끼리 이어서 그림. 굵기가 바뀌는 점에서 끊고 새로 시작 (둥근 끝이라 이음새 안 보임)
    private static func strokeRun(_ points: [PKStrokePoint], _ ink: PKInk.InkType, in context: CGContext) {
        guard let first = points.first, !fillIfDot(points, width: tipWidth(first, ink), in: context) else { return }

        var width = quantize(tipWidth(first, ink))
        context.setLineWidth(width)
        context.move(to: first.location)
        for point in points.dropFirst() {
            context.addLine(to: point.location)
            let w = quantize(tipWidth(point, ink))
            if w != width {
                context.strokePath()
                width = w
                context.setLineWidth(width)
                context.move(to: point.location)
            }
        }
        context.strokePath()
    }

    private static func quantize(_ width: CGFloat) -> CGFloat {
        max(0.1, (width * 10).rounded() / 10)
    }
}
