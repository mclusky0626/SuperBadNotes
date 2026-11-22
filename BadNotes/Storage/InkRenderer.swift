//
//  InkRenderer.swift
//  BadNotes
//
//  PKStroke → 벡터 경로. 직접 필기 모드의 화면과 PDF에 넣는 모양을 같은 코드로 그림
//  (그래서 화면에 보이는 그대로 다른 앱에서도 보임).
//  - 화면: 곡선으로 부드럽게 (타일마다 다시 그리므로 샘플링 결과 SampledStroke를 캐시해서 씀)
//  - PDF: 직선 연결 (파일 크기 아낌)
//  공통:
//  - 굵기가 변하는 획: 굵기가 같은 구간끼리 끊어서 둥근 끝 선으로 그림
//  - 반투명 잉크(형광펜 등): 획 전체를 경로 하나로 한 번에 칠해서 겹친 부분이 진해지지 않게
//    (투명 레이어는 PDFKit이 저장하면서 깨뜨려서 못 씀)
//  - 픽셀 지우개로 지운 부분: 획의 마스크로 잘라 냄
//

import PencilKit
import UIKit

/// 획을 구분하는 값. 같은 획이면 같은 키 → 샘플링 결과를 다시 계산하지 않음
nonisolated struct StrokeKey: Hashable, Sendable {
    private let created: Double
    private let seed: UInt32
    private let count: Int
    private let transform: [CGFloat]
    private let ink: String
    private let color: [CGFloat]
    private let mask: [CGFloat]

    init(_ stroke: PKStroke) {
        created = stroke.path.creationDate.timeIntervalSinceReferenceDate
        seed = stroke.randomSeed
        count = stroke.path.count
        let t = stroke.transform
        transform = [t.a, t.b, t.c, t.d, t.tx, t.ty]
        ink = stroke.ink.inkType.rawValue
        color = InkRenderer.resolvedColor(stroke.ink.color).components ?? []
        if let m = stroke.mask?.bounds {
            mask = [m.minX, m.minY, m.width, m.height]
        } else {
            mask = []
        }
    }
}

/// 그리기 좋게 미리 계산해 둔 획 (만든 뒤에는 읽기만 해서 어느 스레드에서든 씀)
nonisolated struct SampledStroke: @unchecked Sendable {
    struct Point {
        var location: CGPoint
        var width: CGFloat
    }

    enum MaskSpace {
        case none, path, drawing
    }

    let key: StrokeKey
    /// 경로 좌표 (transform 적용 전)
    let points: [Point]
    let transform: CGAffineTransform
    let mask: CGPath?
    let maskSpace: MaskSpace
    /// 불투명 색. 투명도는 alpha로 따로
    let color: CGColor
    let alpha: CGFloat
    let blend: CGBlendMode
    let meanWidth: CGFloat
    /// 그림 좌표(페이지 캔버스)에서 차지하는 영역
    let bounds: CGRect

    var translucent: Bool { alpha < 0.999 || blend != .normal }

    /// 그림 좌표로 옮긴 점들 (지우개, 올가미 계산용)
    func drawingPoints(stride step: Int = 1) -> [CGPoint] {
        Swift.stride(from: 0, to: points.count, by: max(1, step)).map { points[$0].location.applying(transform) }
    }

    /// 변환 때문에 굵기가 몇 배가 되는지
    var widthScale: CGFloat {
        sqrt(abs(transform.a * transform.d - transform.b * transform.c))
    }
}

nonisolated enum InkRenderer {
    /// PDF 종이는 항상 흰색이라 잉크 색은 라이트 모드 기준으로 고정
    private static let lightTraits = UITraitCollection(userInterfaceStyle: .light)

    static func resolvedColor(_ color: UIColor) -> CGColor {
        color.resolvedColor(with: lightTraits).cgColor
    }

    // MARK: PDF에 넣는 모양

    static func draw(_ drawing: PKDrawing, in context: CGContext, transform: CGAffineTransform) {
        context.saveGState()
        context.concatenate(transform)
        for stroke in drawing.strokes {
            draw(sample(stroke), in: context, smooth: false)
        }
        context.restoreGState()
    }

    // MARK: 샘플링

    static func sample(_ stroke: PKStroke, key: StrokeKey? = nil) -> SampledStroke {
        let inkType = stroke.ink.inkType
        let nominal = max(0.3, stroke.path.first.map { renderWidth($0, inkType, direction: 0) } ?? 1)
        let step = min(1.0, max(0.3, nominal * 0.3))

        let raw = Array(stroke.path.interpolatedPoints(by: .distance(step)))
        var points: [SampledStroke.Point] = []
        points.reserveCapacity(raw.count)
        var opacitySum: CGFloat = 0
        var widthSum: CGFloat = 0
        for (i, p) in raw.enumerated() {
            // 납작한 펜촉(만년필·형광펜)은 진행 방향에 따라 굵기가 달라서 앞뒤 점으로 방향을 구함
            let prev = raw[max(0, i - 1)].location
            let next = raw[min(raw.count - 1, i + 1)].location
            let w = renderWidth(p, inkType, direction: atan2(next.y - prev.y, next.x - prev.x))
            points.append(.init(location: p.location, width: w))
            opacitySum += p.opacity
            widthSum += w
        }

        let color = resolvedColor(stroke.ink.color)
        let look = look(for: inkType, colorAlpha: color.alpha)
        let count = CGFloat(max(1, points.count))
        let alpha = min(1, max(0, color.alpha * (points.isEmpty ? 1 : opacitySum / count) * look.alpha))

        var maskPath: CGPath?
        var maskSpace = SampledStroke.MaskSpace.none
        if let mask = stroke.mask {
            // 마스크가 경로 좌표인지 변환 후 좌표인지 문서에 명확하지 않아서 겹치는 쪽을 고름
            let maskBounds = mask.bounds
            let drawn = stroke.renderBounds
            if maskBounds.intersects(drawn.applying(stroke.transform.inverted())) {
                maskPath = mask.cgPath
                maskSpace = .path
            } else if maskBounds.intersects(drawn) {
                maskPath = mask.cgPath
                maskSpace = .drawing
            }
        }

        return SampledStroke(
            key: key ?? StrokeKey(stroke),
            points: points,
            transform: stroke.transform,
            mask: maskPath,
            maskSpace: maskSpace,
            color: color.copy(alpha: 1) ?? color,
            alpha: alpha,
            blend: look.blend,
            meanWidth: points.isEmpty ? nominal : widthSum / count,
            bounds: stroke.renderBounds.insetBy(dx: -1, dy: -1)
        )
    }

    // MARK: 그리기

    /// - smooth: 곡선으로 부드럽게 (화면용)
    /// - alphaMultiplier: 사라지는 효과용
    /// - offset: 올가미로 옮기는 중일 때
    static func draw(_ s: SampledStroke, in context: CGContext, smooth: Bool,
                     alphaMultiplier: CGFloat = 1, offset: CGVector = .zero) {
        guard !s.points.isEmpty else { return }
        let alpha = s.alpha * alphaMultiplier
        guard alpha > 0.01 else { return }

        context.saveGState()
        if offset != .zero {
            context.translateBy(x: offset.dx, y: offset.dy)
        }
        switch s.maskSpace {
        case .none:
            context.concatenate(s.transform)
        case .path:
            context.concatenate(s.transform)
            if let mask = s.mask { context.addPath(mask); context.clip() }
        case .drawing:
            if let mask = s.mask { context.addPath(mask); context.clip() }
            context.concatenate(s.transform)
        }
        context.setStrokeColor(s.color)
        context.setFillColor(s.color)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if alpha < 0.999 || s.blend != .normal {
            context.setAlpha(alpha)
            context.setBlendMode(s.blend)
            strokeSinglePath(s.points, width: s.meanWidth, smooth: smooth, in: context)
        } else {
            strokeRuns(s.points, smooth: smooth, in: context)
        }
        context.restoreGState()
    }

    // MARK: - 내부

    private struct Look {
        var alpha: CGFloat
        var blend: CGBlendMode
    }

    private static func look(for ink: PKInk.InkType, colorAlpha: CGFloat) -> Look {
        switch ink {
        case .marker: Look(alpha: 0.55, blend: .multiply)
        case .watercolor: Look(alpha: 0.5, blend: .multiply)
        case .pencil: Look(alpha: 0.85, blend: .normal)
        case .crayon: Look(alpha: 0.9, blend: .normal)
        default:
            // 반투명 색으로 그은 볼펜·펜 = BadNotes 형광펜 → 곱하기로 칠해서 밑의 글자가 또렷하게
            colorAlpha < 0.95 ? Look(alpha: 1, blend: .multiply) : Look(alpha: 1, blend: .normal)
        }
    }

    /// PencilKit이 점 크기(size)를 실제로 그리는 굵기.
    /// PencilKit 렌더러로 잉크마다 직접 그려서 잰 값에 맞춤 (그래야 레이어 모드와 직접 필기 모드가 똑같이 보임).
    /// - 펜·볼펜: 2 × (크기 − 2). 크기 2 이하는 안 보임
    /// - 만년필: 납작한 펜촉. 긴 쪽 (크기 − 2), 짧은 쪽은 그 1/4, 펜촉 방향 = azimuth
    /// - 형광펜: 납작한 펜촉. 세로 획 1.41 × 크기 − 0.3, 가로 획 0.54 × 크기 − 0.4 (iOS에서 잰 값)
    /// - 연필·수채·크레용: 크기에 비례
    /// direction: 획이 나아가는 방향 (라디안)
    static func renderWidth(_ point: PKStrokePoint, _ ink: PKInk.InkType, direction: CGFloat) -> CGFloat {
        let s = point.size.width
        switch ink {
        case .pen, .monoline:
            return max(0, 2 * (s - 2))
        case .fountainPen:
            let long = max(0, s - 2)
            return chisel(long: long, short: long * 0.25, nib: point.azimuth, direction: direction)
        case .marker:
            return chisel(long: max(0, s * 0.705 - 0.15), short: max(0, s * 0.27 - 0.2),
                          nib: point.azimuth, direction: direction)
        case .pencil:
            return s * 1.65
        case .watercolor:
            return s * 1.63
        case .crayon:
            return s * 1.3
        default:
            return s
        }
    }

    /// 원하는 굵기로 보이게 하려면 PencilKit 점 크기를 얼마로 해야 하는지 (renderWidth의 반대.
    /// 납작한 펜촉은 가로 획 기준)
    static func pencilKitSize(forWidth width: CGFloat, _ ink: PKInk.InkType) -> CGFloat {
        switch ink {
        case .pen, .monoline, .fountainPen: width / 2 + 2
        case .marker: (width + 0.4) / 0.54
        case .pencil: width / 1.65
        case .watercolor: width / 1.63
        case .crayon: width / 1.3
        default: width
        }
    }

    /// 납작한 펜촉(타원)을 진행 방향의 수직으로 투영한 굵기
    private static func chisel(long a: CGFloat, short b: CGFloat, nib: CGFloat, direction: CGFloat) -> CGFloat {
        let t = direction - nib
        return 2 * sqrt(pow(a * sin(t), 2) + pow(b * cos(t), 2))
    }

    /// 콕 찍은 점처럼 거의 길이가 없는 획이면 원으로 칠하고 true
    private static func fillIfDot(_ points: [SampledStroke.Point], width: CGFloat, in context: CGContext) -> Bool {
        guard let first = points.first else { return true }
        var length: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            length += hypot(b.location.x - a.location.x, b.location.y - a.location.y)
            if length >= 0.25 { return false }
        }
        let w = max(0.3, width)
        context.fillEllipse(in: CGRect(x: first.location.x - w / 2, y: first.location.y - w / 2, width: w, height: w))
        return true
    }

    /// 굵기 하나로 획 전체를 한 번에 그림 (반투명 잉크용)
    private static func strokeSinglePath(_ points: [SampledStroke.Point], width: CGFloat, smooth: Bool, in context: CGContext) {
        guard !fillIfDot(points, width: width, in: context) else { return }
        context.setLineWidth(max(0.1, width))
        addPolyline(points, 0...(points.count - 1), smooth: smooth, in: context)
        context.strokePath()
    }

    /// 굵기가 같은 구간끼리 이어서 그림. 굵기가 바뀌는 점에서 끊고 새로 시작 (둥근 끝이라 이음새 안 보임)
    private static func strokeRuns(_ points: [SampledStroke.Point], smooth: Bool, in context: CGContext) {
        guard let first = points.first, !fillIfDot(points, width: first.width, in: context) else { return }
        var start = 0
        while start < points.count - 1 {
            let width = quantize(points[start].width)
            var end = start + 1
            while end < points.count - 1, quantize(points[end].width) == width {
                end += 1
            }
            context.setLineWidth(width)
            addPolyline(points, start...end, smooth: smooth, in: context)
            context.strokePath()
            start = end
        }
    }

    /// smooth면 점 사이 중점을 지나는 2차 곡선 (확대해도 꺾인 데가 안 보임)
    private static func addPolyline(_ points: [SampledStroke.Point], _ range: ClosedRange<Int>, smooth: Bool,
                                    in context: CGContext) {
        let a = range.lowerBound, b = range.upperBound
        context.move(to: points[a].location)
        guard b > a else { return }
        if !smooth || b - a < 2 {
            for i in (a + 1)...b { context.addLine(to: points[i].location) }
            return
        }
        for i in (a + 1)..<b {
            let p = points[i].location, n = points[i + 1].location
            context.addQuadCurve(to: CGPoint(x: (p.x + n.x) / 2, y: (p.y + n.y) / 2), control: p)
        }
        context.addLine(to: points[b].location)
    }

    private static func quantize(_ width: CGFloat) -> CGFloat {
        max(0.1, (width * 10).rounded() / 10)
    }
}
