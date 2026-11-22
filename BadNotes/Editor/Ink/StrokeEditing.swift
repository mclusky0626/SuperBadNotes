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

    /// 부분 지우개: 지우개가 닿은 부분을 잘라 낸 새 획들. 안 닿았으면 nil, 다 지워졌으면 빈 배열
    static func erase(_ stroke: PKStroke, sampled: SampledStroke, from a: CGPoint, to b: CGPoint,
                      radius: CGFloat) -> [PKStroke]? {
        guard touches(sampled, from: a, to: b, radius: radius) else { return nil }
        let t = stroke.transform
        let scale = sampled.widthScale
        let rotation = atan2(t.b, t.a)

        var runs: [[PKStrokePoint]] = []
        var current: [PKStrokePoint] = []
        var previous: CGPoint?
        for p in stroke.path.interpolatedPoints(by: .distance(1.0)) {
            let location = p.location.applying(t)
            let direction = previous.map { atan2(p.location.y - $0.y, p.location.x - $0.x) } ?? 0
            previous = p.location
            let width = InkRenderer.renderWidth(p, stroke.ink.inkType, direction: direction) * scale
            let gone = distance(location, toSegment: a, b) <= radius + width / 2
                || !isVisible(sampled, pathPoint: p.location, drawingPoint: location)
            if gone {
                if current.count >= 2 { runs.append(current) }
                current = []
                continue
            }
            current.append(PKStrokePoint(location: location, timeOffset: p.timeOffset,
                                         size: CGSize(width: p.size.width * scale, height: p.size.height * scale),
                                         opacity: p.opacity, force: p.force, azimuth: p.azimuth + rotation,
                                         altitude: p.altitude, secondaryScale: p.secondaryScale))
        }
        if current.count >= 2 { runs.append(current) }

        return runs.map { run in
            PKStroke(ink: stroke.ink,
                     path: PKStrokePath(controlPoints: run, creationDate: stroke.path.creationDate),
                     transform: .identity, mask: nil, randomSeed: UInt32.random(in: 1...UInt32.max))
        }
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
                 mask: stroke.mask, randomSeed: UInt32.random(in: 1...UInt32.max))
    }

    static func recolored(_ stroke: PKStroke, to color: UIColor) -> PKStroke {
        PKStroke(ink: PKInk(stroke.ink.inkType, color: color), path: stroke.path,
                 transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }
}
