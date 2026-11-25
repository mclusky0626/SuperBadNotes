//
//  StrokeEditing.swift
//  BadNotes
//
//  필기 고치기 계산: 지우개(획째/부분), 올가미 선택, 옮기기, 복제, 색 바꾸기.
//  전부 페이지 캔버스 좌표 기준.
//

import PencilKit
import UIKit

nonisolated enum StrokeEditing {
    // MARK: 지우개

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 한 입력 이벤트 안의 실제 펜슬 위치를 연결한 지우개 자국 (페이지 좌표).
    struct Sweep {
        let path: CGPath
        let bounds: CGRect
        let radius: CGFloat

        init(from start: CGPoint, through points: [CGPoint], radius: CGFloat) {
            self.radius = radius
            let trail = CGMutablePath()
            trail.move(to: start)
            for point in points where point != trail.currentPoint { trail.addLine(to: point) }
            if trail.isEmpty || trail.boundingBoxOfPath.size == .zero {
                path = CGPath(ellipseIn: CGRect(origin: start, size: .zero).insetBy(dx: -radius, dy: -radius), transform: nil)
            } else {
                path = trail.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
            }
            bounds = path.boundingBoxOfPath
        }

        func bite(in s: SampledStroke) -> CGPath? {
            guard s.bounds.intersects(bounds) else { return nil }
            if s.transform.isIdentity { return path }
            var inverse = s.transform.inverted()
            return path.copy(using: &inverse)
        }
    }

    /// 획이 실제로 칠하는 모양 (경로 좌표, 가장 굵은 곳 기준). 지우개 판정에 씀 — 가운데 점만 보면
    /// 가운데를 지운 뒤 양옆에 남은 가는 조각이 영영 안 지워졌음
    private static let outlineCache = NSCache<NSNumber, CGPath>()

    static func inkOutline(_ s: SampledStroke) -> CGPath {
        if let glass = s.glassOutline { return glass }
        if case let .fountain(outline) = s.imprint { return outline }
        let id = NSNumber(value: s.key.outlineKey.hashValue)
        if let hit = outlineCache.object(forKey: id) { return hit }
        // 화면에 그리는 것과 같은 곡선 + 넉넉한 굵기 (Apple 렌더러·곡선 바깥으로 삐져나온 잉크까지 덮게)
        let scale = max(s.widthScale, 0.01)
        let width = max(0.5, s.points.map(\.width).max() ?? s.meanWidth) * 1.15 + 1.5 / scale
        let outline = GlassInk.outline(centerline: InkRenderer.centerline(s.points, smooth: true), width: width)
        outlineCache.setObject(outline, forKey: id)
        return outline
    }

    /// 지금 보이는 잉크 모양 (마스크로 지운 곳 뺌), 경로 좌표
    private static func visibleInk(_ s: SampledStroke) -> CGPath {
        let outline = inkOutline(s)
        guard let mask = s.mask else { return outline }
        switch s.maskSpace {
        case .none: return outline
        case .path: return outline.intersection(mask)
        case .drawing:
            var inverse = s.transform.inverted()
            return outline.intersection(mask.copy(using: &inverse) ?? mask)
        }
    }

    static func touches(_ s: SampledStroke, sweep: Sweep) -> Bool {
        guard let bite = sweep.bite(in: s) else { return false }
        return visibleInk(s).intersects(bite)
    }

    static func touches(_ s: SampledStroke, from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Bool {
        touches(s, sweep: Sweep(from: a, through: [b], radius: radius))
    }

    static func erase(_ stroke: PKStroke, sampled: SampledStroke, from a: CGPoint, to b: CGPoint,
                      radius: CGFloat) -> [PKStroke]? {
        erase(stroke, sampled: sampled, sweep: Sweep(from: a, through: [b], radius: radius))
    }

    /// nil이면 안 닿았고, 빈 배열이면 획 전체를 지웠다.
    static func erase(_ stroke: PKStroke, sampled: SampledStroke, sweep: Sweep) -> [PKStroke]? {
        guard let bite = sweep.bite(in: sampled) else { return nil }
        let radius = sweep.radius / max(sampled.widthScale, 0.01)
        let outline = inkOutline(sampled)
        guard outline.intersects(bite) else { return nil }
        var inverse = stroke.transform.inverted()
        let visible: CGPath
        if let mask = stroke.mask?.cgPath, sampled.maskSpace != .drawing {
            visible = mask
        } else if let mask = stroke.mask?.cgPath {
            // 예전 방식(그림 좌표) 마스크면 경로 좌표로 옮김
            visible = mask.copy(using: &inverse) ?? mask
        } else {
            let margin = max(24, radius * 2)
            let area = sampled.bounds.applying(inverse).insetBy(dx: -margin, dy: -margin)
            visible = CGPath(rect: area, transform: nil)
        }
        if sampled.mask != nil, !visible.intersection(bite).intersects(outline) { return nil }
        var remaining = visible.subtracting(bite)
        let pieces = outline.intersection(remaining).componentsSeparated()
        // 지우개 자국 가까이에 남은 작은 조각(부스러기)은 같이 지움
        let crumb = max(3, radius * 0.9)
        let near = bite.boundingBoxOfPath.insetBy(dx: -radius, dy: -radius)
        let crumbs = CGMutablePath()
        var leftover = CGRect.null
        for piece in pieces {
            let box = piece.boundingBoxOfPath
            if box.width < crumb, box.height < crumb, box.intersects(near) {
                crumbs.addRect(box.insetBy(dx: -0.75, dy: -0.75))
            } else {
                leftover = leftover.union(box)
            }
        }
        guard !leftover.isNull, min(leftover.width, leftover.height) > 0.35 else { return [] }
        if !crumbs.isEmpty { remaining = remaining.subtracting(crumbs) }
        return [PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform,
                         mask: UIBezierPath(cgPath: remaining), randomSeed: stroke.randomSeed)]
    }

    /// 형광펜 획인지 (BadNotes 형광펜 = 반투명 볼펜, PencilKit 형광펜 = 마커)
    static func isHighlighter(_ stroke: PKStroke) -> Bool {
        if stroke.ink.inkType == .marker { return true }
        // 저장했다 열면 PencilKit이 볼펜(monoline)을 펜(pen)으로 바꿔 놓아서 둘 다 봄
        return (stroke.ink.inkType == .monoline || stroke.ink.inkType == .pen) && stroke.ink.color.cgColor.alpha < 0.95
    }

    /// 픽셀 지우개로 이미 지워진(마스크 밖) 점인지
    private static func isVisible(_ s: SampledStroke, pathPoint: CGPoint, drawingPoint: CGPoint) -> Bool {
        guard let mask = s.mask else { return true }
        switch s.maskSpace {
        case .none: return true
        case .path: return mask.contains(pathPoint)
        case .drawing: return mask.contains(drawingPoint)
        }
    }

    // MARK: 올가미

    /// 올가미 안에 절반 넘게 들어간 획들의 번호
    static func select(_ strokes: [SampledStroke], lasso: CGPath) -> [Int] {
        let box = lasso.boundingBox
        var result: [Int] = []
        for (index, s) in strokes.enumerated() where box.intersects(s.bounds) {
            let samples = s.drawingPoints(stride: max(1, s.points.count / 24))
            guard !samples.isEmpty else { continue }
            let inside = samples.filter { lasso.contains($0) }.count
            if Double(inside) / Double(samples.count) >= 0.5 {
                result.append(index)
            }
        }
        return result
    }

    static func translated(_ stroke: PKStroke, by offset: CGVector) -> PKStroke {
        var moved = stroke
        moved.transform = stroke.transform.concatenating(CGAffineTransform(translationX: offset.dx, y: offset.dy))
        return moved
    }

    /// 같은 종이 결로 복제하면서도 두 획을 따로 편집할 수 있게, 복제본에 새 생성 시각을 줌.
    static func duplicated(_ stroke: PKStroke, by offset: CGVector) -> PKStroke {
        let path = PKStrokePath(controlPoints: Array(stroke.path), creationDate: Date())
        return PKStroke(ink: stroke.ink, path: path,
                        transform: stroke.transform.concatenating(CGAffineTransform(translationX: offset.dx, y: offset.dy)),
                        mask: stroke.mask, randomSeed: stroke.randomSeed)
    }

    static func recolored(_ stroke: PKStroke, to color: UIColor) -> PKStroke {
        PKStroke(ink: PKInk(stroke.ink.inkType, color: color), path: stroke.path,
                 transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }
}
