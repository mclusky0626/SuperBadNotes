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

    private static func segmentBounds(_ a: CGPoint, _ b: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -radius, dy: -radius)
    }

    /// 지우개가 지나간 선분(a→b, 반지름 radius)이 획에 닿는지
    static func touches(_ s: SampledStroke, from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Bool {
        let area = segmentBounds(a, b, radius: radius)
        guard s.bounds.intersects(area) else { return false }
        let scale = s.widthScale
        for point in s.points {
            let q = point.location.applying(s.transform)
            if distance(q, toSegment: a, b) <= radius + point.width * scale / 2 {
                return isVisible(s, pathPoint: point.location, drawingPoint: q)
            }
        }
        return false
    }

    /// 부분 지우개: 획 모양(경로·굵기·질감)은 그대로 두고, 보이는 영역(마스크)에서 지우개 자국만 뺌.
    /// 예전처럼 점을 다시 찍어 새 획을 만들면 곡선이 다시 계산돼서 남은 부분 모양이 변했음.
    /// 안 닿았으면 nil, 남은 게 없으면 빈 배열
    static func erase(_ stroke: PKStroke, sampled: SampledStroke, from a: CGPoint, to b: CGPoint,
                      radius: CGFloat) -> [PKStroke]? {
        guard touches(sampled, from: a, to: b, radius: radius) else { return nil }
        // 지우개 자국(그림 좌표) → 획의 경로 좌표 (PencilKit 마스크는 경로 좌표)
        let trail = CGMutablePath()
        trail.move(to: a)
        trail.addLine(to: b == a ? CGPoint(x: a.x + 0.01, y: a.y) : b)
        var inverse = stroke.transform.inverted()
        guard let bite = trail.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
            .copy(using: &inverse) else { return nil }

        let visible: CGPath
        if let mask = stroke.mask?.cgPath, sampled.maskSpace != .drawing {
            visible = mask
        } else if let mask = stroke.mask?.cgPath {
            // 예전 방식(그림 좌표) 마스크면 경로 좌표로 옮김
            var t = inverse
            visible = mask.copy(using: &t) ?? mask
        } else {
            let margin = max(24, radius * 2)
            let area = stroke.renderBounds.applying(inverse).insetBy(dx: -margin, dy: -margin)
            visible = CGPath(rect: area, transform: nil)
        }
        let remaining = visible.subtracting(bite)
        // 남은 부분 중 획이 지나가는 곳이 하나도 없으면 획째 지움
        guard !remaining.isEmpty,
              sampled.points.contains(where: { remaining.contains($0.location) }) else { return [] }
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

    /// 복제본은 새 획이라 씨앗값을 바꿔야 원본과 구분됨
    static func duplicated(_ stroke: PKStroke, by offset: CGVector) -> PKStroke {
        PKStroke(ink: stroke.ink, path: stroke.path,
                 transform: stroke.transform.concatenating(CGAffineTransform(translationX: offset.dx, y: offset.dy)),
                 mask: stroke.mask,
                 // 유리펜 표시는 지킴
                 randomSeed: GlassInk.isGlass(stroke) ? GlassInk.seed(strength: Double(GlassInk.strength(stroke.randomSeed)))
                     : (InkOrigin.isBadNotes(stroke.randomSeed) ? InkOrigin.badNotesSeed() : UInt32.random(in: 1...UInt32.max)))
    }

    static func recolored(_ stroke: PKStroke, to color: UIColor) -> PKStroke {
        PKStroke(ink: PKInk(stroke.ink.inkType, color: color), path: stroke.path,
                 transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }
}
