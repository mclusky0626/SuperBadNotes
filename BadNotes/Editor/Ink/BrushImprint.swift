import PencilKit
import UIKit

/// 새 펜촉은 PKDrawing에 남는 씨앗값으로 구분한다. 기존 획을 열 때는 원래 렌더러를 쓴다.
nonisolated enum BrushProfile: UInt32 {
    case fountain = 0x6A56_0000
    case brush = 0x6A57_0000
    case graphite = 0x6A58_0000

    init?(seed: UInt32) { self.init(rawValue: seed & 0xFFFF_0000) }

    func seed(salt: UInt32) -> UInt32 { rawValue | (salt & 0xFFFF) }
}

/// 만년필은 납작한 펜촉이 지나간 윤곽을 채운다. 연필은 경로의 이동 거리마다 흑연 입자를 찍는다.
nonisolated enum BrushImprint {
    case fountain(CGPath)
    case graphite([GraphiteDab], seed: UInt32)

    struct GraphiteDab {
        let center: CGPoint
        let diameter: CGFloat
        let aspect: CGFloat
        let angle: CGFloat
        let flow: CGFloat
    }

    init?(profile: BrushProfile?, points: [PKStrokePoint], seed: UInt32) {
        guard let first = points.first else { return nil }
        switch profile {
        case .fountain:
            self = .fountain(Self.nibOutline(points))
        case .graphite:
            var dabs: [GraphiteDab] = []
            var remaining: CGFloat = 0
            var previous = first.location
            for p in points {
                let dx = p.location.x - previous.x, dy = p.location.y - previous.y
                let length = hypot(dx, dy)
                let diameter = max(0.25, InkRenderer.renderWidth(p, .pencil, direction: 0))
                let tilt = 1 - min(1, max(0, p.altitude / (.pi / 2)))
                let aspect = 1 - tilt * 0.52
                while remaining <= length {
                    let t = length > 0 ? remaining / length : 0
                    let center = CGPoint(x: previous.x + dx * t, y: previous.y + dy * t)
                    dabs.append(GraphiteDab(center: center, diameter: diameter, aspect: aspect,
                                            angle: p.azimuth, flow: p.opacity))
                    remaining += max(0.16, diameter * aspect * 0.30)
                }
                remaining -= length
                previous = p.location
            }
            self = .graphite(dabs, seed: seed)
        default: return nil
        }
    }

    /// PDF 주석 테두리를 정할 때는 비싼 재샘플링 대신 제어점·최대 펜촉 반지름으로 곡선을 감싼다.
    static func enclosingBounds(of stroke: PKStroke) -> CGRect {
        let profile = BrushProfile(seed: stroke.randomSeed)
        guard profile == .fountain || profile == .graphite else { return stroke.renderBounds }
        var box = CGRect.null
        var radius: CGFloat = 0
        for p in stroke.path {
            box = box.union(CGRect(origin: p.location, size: .zero))
            let r = profile == .fountain ? p.size.width - 2 : InkRenderer.renderWidth(p, .pencil, direction: 0) / 2
            radius = max(radius, r)
        }
        return stroke.renderBounds.union(box.insetBy(dx: -radius, dy: -radius).applying(stroke.transform))
    }

    var bounds: CGRect {
        switch self {
        case .fountain(let outline): outline.boundingBoxOfPath
        case let .graphite(dabs, _):
            dabs.reduce(into: CGRect.null) { bounds, dab in
                bounds = bounds.union(CGRect(origin: dab.center, size: .zero)
                    .insetBy(dx: -dab.diameter / 2, dy: -dab.diameter / 2))
            }
        }
    }

    func draw(alpha: CGFloat, in context: CGContext) {
        switch self {
        case .fountain(let outline):
            context.setAlpha(alpha)
            context.addPath(outline)
            context.fillPath()
        case let .graphite(dabs, seed):
            let clip = context.boundingBoxOfClipPath
            for (index, dab) in dabs.enumerated() {
                let radius = dab.diameter / 2
                let area = CGRect(x: dab.center.x - radius, y: dab.center.y - radius,
                                  width: dab.diameter, height: dab.diameter)
                guard area.intersects(clip) else { continue }
                context.saveGState()
                context.translateBy(x: dab.center.x, y: dab.center.y)
                context.rotate(by: dab.angle)
                context.scaleBy(x: 1, y: dab.aspect)
                context.setAlpha(dab.flow * alpha)
                let variant = (index + Int(seed)) % Self.grains.count
                context.draw(Self.grains[variant], in: CGRect(x: -radius, y: -radius,
                                                             width: dab.diameter, height: dab.diameter))
                context.restoreGState()
            }
        }
    }

    /// 타원의 진행 방향 법선 쪽 접점을 이어서 펜촉 크기·회전을 보존한다.
    private static func nibOutline(_ points: [PKStrokePoint]) -> CGPath {
        struct Edge {
            let left: CGPoint
            let right: CGPoint
            let angle: CGFloat
            let tip: CGAffineTransform
        }
        let path = CGMutablePath()
        var edges: [Edge] = []
        edges.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            let prev = points[max(0, i - 1)].location
            let next = points[min(points.count - 1, i + 1)].location
            let dx = next.x - prev.x, dy = next.y - prev.y
            let a = max(0.1, p.size.width - 2), b = a * 0.25
            let tip = CGAffineTransform(translationX: p.location.x, y: p.location.y)
                .rotated(by: p.azimuth).scaledBy(x: a, y: b)
            guard dx != 0 || dy != 0 else { continue }
            let angle = atan2(-dy * tip.c + dx * tip.d, -dy * tip.a + dx * tip.b)
            let u = cos(angle), v = sin(angle)
            edges.append(Edge(left: CGPoint(x: u, y: v).applying(tip),
                              right: CGPoint(x: -u, y: -v).applying(tip), angle: angle, tip: tip))
        }
        if let first = edges.first, let last = edges.last {
            path.move(to: first.left)
            for edge in edges.dropFirst() { path.addLine(to: edge.left) }
            path.addArc(center: .zero, radius: 1, startAngle: last.angle, endAngle: last.angle - .pi,
                        clockwise: true, transform: last.tip)
            for edge in edges.reversed() { path.addLine(to: edge.right) }
            path.addArc(center: .zero, radius: 1, startAngle: first.angle - .pi, endAngle: first.angle - 2 * .pi,
                        clockwise: true, transform: first.tip)
            path.closeSubpath()
        } else if let p = points.first {
            let r = max(0.1, p.size.width - 2)
            let tip = CGAffineTransform(translationX: p.location.x, y: p.location.y).rotated(by: p.azimuth)
            path.addEllipse(in: CGRect(x: -r, y: -r * 0.25, width: 2 * r, height: r * 0.5), transform: tip)
        }
        return path
    }

    /// 잉크 색으로 찍을 수 있는 흑연 마스크. 고정된 네 가지 결을 반복 사용해서 타일·PDF에도 같은 자국이 남는다.
    private static let grains: [CGImage] = (1...4).map { variant in
        let side = 48
        var state = UInt32(variant)
        let clumpSize = 4
        let coarseSide = side / clumpSize
        let deposits = (0..<(coarseSide * coarseSide)).map { _ -> Double in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / Double(0xFF_FFFF)
        }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(side * side)
        for y in 0..<side {
            for x in 0..<side {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Double(state >> 8) / Double(0xFF_FFFF)
                let dx = (Double(x) + 0.5) / Double(side) * 2 - 1
                let dy = (Double(y) + 0.5) / Double(side) * 2 - 1
                let edge = min(1, max(0, (1 - hypot(dx, dy)) * 3))
                let deposit = deposits[(y / clumpSize) * coarseSide + x / clumpSize]
                let density = min(1, max(0, (deposit * 0.65 + noise * 0.35 - 0.28) * 1.8))
                pixels.append(UInt8(255 * (1 - edge * density)))
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(maskWidth: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       provider: provider, decode: nil, shouldInterpolate: true)!
    }
}
