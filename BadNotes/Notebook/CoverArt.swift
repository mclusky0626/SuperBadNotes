//
//  CoverArt.swift
//  BadNotes
//
//  노트북 표지 그림. 전부 벡터(면·선·글자)로만 그림 → PDF에 들어가서 아무리 확대해도 선명.
//  그라데이션은 안 씀 (확대하면 색 띠가 보이고, PDF 그라데이션은 투명도도 못 담음).
//  무늬의 '무작위'는 표지마다 정해진 씨앗으로 만들어서 미리보기와 PDF가 똑같음.
//

import UIKit

nonisolated enum CoverArt {
    static func draw(_ style: CoverStyle, title: String?, in context: CGContext, rect: CGRect) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        var p = Painter(context: context, rect: rect)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch style {
        case .navy, .burgundy, .forest, .charcoal, .cream, .sky, .lemon, .blush:
            classic(style, title: title, &p)
        case .stripes: stripes(title: title, &p)
        case .dots: dots(title: title, &p)
        case .gingham: gingham(title: title, &p)
        case .linen: linen(title: title, &p)
        case .terrazzo: terrazzo(title: title, &p)
        case .memphis: memphis(title: title, &p)
        case .kraft: kraft(title: title, &p)
        case .waves: waves(title: title, &p)
        case .mountains: mountains(title: title, &p)
        case .sunset: sunset(title: title, &p)
        case .night: night(title: title, &p)
        case .leaves: leaves(title: title, &p)
        case .bauhaus: bauhaus(title: title, &p)
        }
    }

    // MARK: 클래식 (가죽 노트 느낌: 박음질 + 책등 + 고무줄 + 박 찍은 제목)

    private static func classic(_ style: CoverStyle, title: String, _ p: inout Painter) {
        let base: UInt32, foil: UInt32, dark: Bool
        switch style {
        case .navy: (base, foil, dark) = (0x22304D, 0xD9B96E, true)
        case .burgundy: (base, foil, dark) = (0x6A2030, 0xDDBE78, true)
        case .forest: (base, foil, dark) = (0x2C4A3B, 0xD8C285, true)
        case .charcoal: (base, foil, dark) = (0x2A2B2F, 0xCDD0D7, true)
        case .cream: (base, foil, dark) = (0xEFE6D2, 0x2E3752, false)
        case .sky: (base, foil, dark) = (0x9CC0E2, 0x1E3452, false)
        case .lemon: (base, foil, dark) = (0xF1DA6E, 0x4A3D10, false)
        default: (base, foil, dark) = (0xEDBBC6, 0x5A2534, false)
        }
        let b = Painter.color(base)
        let shade = Painter.mix(b, .black, dark ? 0.22 : 0.14)
        let r = p.rect, u = p.u

        p.fill(r, b)
        // 박음질
        let stitchInset = 3.2 * u
        let stitch = CGRect(x: r.minX + r.width * 0.075 + stitchInset * 0.8, y: r.minY + stitchInset,
                            width: r.width * 0.925 - stitchInset * 1.8, height: r.height - stitchInset * 2)
        p.context.saveGState()
        p.context.setLineDash(phase: 0, lengths: [1.7 * u, 1.1 * u])
        p.stroke(UIBezierPath(roundedRect: stitch, cornerRadius: 2.2 * u).cgPath,
                 Painter.mix(b, dark ? .white : .black, dark ? 0.32 : 0.22), width: 0.28 * u)
        p.context.restoreGState()
        // 책등
        p.fill(CGRect(x: r.minX, y: r.minY, width: r.width * 0.075, height: r.height), shade)
        p.fill(CGRect(x: r.minX + r.width * 0.075, y: r.minY, width: 0.35 * u, height: r.height),
               Painter.mix(b, .white, dark ? 0.10 : 0.25))
        p.fill(CGRect(x: r.minX + r.width * 0.075 + 1.4 * u, y: r.minY, width: 0.3 * u, height: r.height),
               Painter.mix(b, .black, dark ? 0.12 : 0.08))
        // 고무줄
        let band = CGRect(x: r.maxX - r.width * 0.12, y: r.minY, width: max(2.2 * u, r.width * 0.032), height: r.height)
        p.fill(band, Painter.mix(b, .black, dark ? 0.38 : 0.45))
        p.fill(CGRect(x: band.minX, y: r.minY, width: 0.25 * u, height: r.height), Painter.mix(b, .black, dark ? 0.2 : 0.25))
        // 제목 자리 (살짝 눌린 판 + 박 테두리)
        let plate = p.labelRect()
        let foilColor = Painter.color(foil)
        p.fill(UIBezierPath(roundedRect: plate, cornerRadius: 1.6 * u).cgPath, Painter.mix(b, .black, dark ? 0.12 : 0.07))
        p.stroke(UIBezierPath(roundedRect: plate.insetBy(dx: 1.1 * u, dy: 1.1 * u), cornerRadius: 1.0 * u).cgPath,
                 foilColor, width: 0.22 * u)
        p.title(title, in: plate, color: foilColor)
    }

    // MARK: 패턴

    private static func stripes(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0x2F57A0))
        let light = Painter.color(0x3E6BB8)
        let width = 6 * u, period = 12 * u
        let path = CGMutablePath()
        var x = r.minX - r.height
        while x < r.maxX {
            path.move(to: CGPoint(x: x, y: r.maxY))
            path.addLine(to: CGPoint(x: x + width, y: r.maxY))
            path.addLine(to: CGPoint(x: x + width + r.height, y: r.minY))
            path.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            path.closeSubpath()
            x += period
        }
        p.fill(path, light)
        p.plate(title, fill: Painter.color(0xFFFDF7), border: Painter.color(0x2F57A0), text: Painter.color(0x1E3A72))
    }

    private static func dots(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0xE7735B))
        let step = 9 * u, radius = 1.7 * u
        let path = CGMutablePath()
        var row = 0
        var y = r.minY + step * 0.4
        while y < r.maxY + radius {
            var x = r.minX + (row.isMultiple(of: 2) ? step * 0.25 : step * 0.75)
            while x < r.maxX + radius {
                path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += step
            }
            y += step * 0.866
            row += 1
        }
        p.fill(path, Painter.color(0xFBE3D9))
        p.plate(title, fill: Painter.color(0xFFF8F3), border: Painter.color(0xC9533C), text: Painter.color(0x8E2F1E))
    }

    private static func gingham(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        let base = Painter.color(0xF6F7FB), mid = Painter.color(0xB4C3E0), dark = Painter.color(0x6E86B8)
        p.fill(r, base)
        let s = 4.2 * u
        let vertical = CGMutablePath(), horizontal = CGMutablePath(), cross = CGMutablePath()
        var columns: [CGFloat] = []
        var x = r.minX
        while x < r.maxX { columns.append(x); vertical.addRect(CGRect(x: x, y: r.minY, width: s, height: r.height)); x += s * 2 }
        var y = r.minY
        while y < r.maxY {
            horizontal.addRect(CGRect(x: r.minX, y: y, width: r.width, height: s))
            for cx in columns { cross.addRect(CGRect(x: cx, y: y, width: s, height: s)) }
            y += s * 2
        }
        p.fill(vertical, mid)
        p.fill(horizontal, mid)
        p.fill(cross, dark)
        p.plate(title, fill: Painter.color(0xFFFFFF), border: dark, text: Painter.color(0x30406A))
    }

    private static func linen(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        let base = Painter.color(0xCDBC9E)
        p.fill(r, base)
        // 씨실·날실: 아주 가까운 두 색으로 촘촘하게
        let a = CGMutablePath(), b = CGMutablePath()
        var i = 0
        var x = r.minX
        while x < r.maxX {
            (i.isMultiple(of: 2) ? a : b).addRect(CGRect(x: x, y: r.minY, width: 0.45 * u, height: r.height))
            x += 1.15 * u; i += 1
        }
        var y = r.minY
        i = 0
        while y < r.maxY {
            (i.isMultiple(of: 2) ? b : a).addRect(CGRect(x: r.minX, y: y, width: r.width, height: 0.45 * u))
            y += 1.15 * u; i += 1
        }
        p.fill(a, Painter.mix(base, .white, 0.10))
        p.fill(b, Painter.mix(base, .black, 0.07))
        p.plate(title, fill: Painter.color(0xFAF6EE), border: Painter.color(0x6F5E41), text: Painter.color(0x4B3E28))
    }

    private static func terrazzo(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0xEFEAE3))
        var random = SeededRandom(seed: 0x7E77A220)
        let palette: [UInt32] = [0xC8573E, 0x8FA58A, 0x4F5D75, 0xE2B04A, 0x2E2E33, 0xE9A7A0, 0xB9C4CF]
        let count = Int(r.width * r.height / (u * u) / 55)
        for _ in 0..<count {
            let center = CGPoint(x: r.minX + random.unit() * r.width, y: r.minY + random.unit() * r.height)
            let size = (random.unit() < 0.15 ? random.range(2.6, 4.2) : random.range(0.6, 2.2)) * u
            let sides = 4 + Int(random.unit() * 4)
            let start = random.unit() * .pi * 2
            let path = CGMutablePath()
            for k in 0..<sides {
                let angle = start + CGFloat(k) / CGFloat(sides) * .pi * 2 + random.range(-0.25, 0.25)
                let radius = size * random.range(0.55, 1)
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            p.fill(path, Painter.color(palette[Int(random.unit() * CGFloat(palette.count)) % palette.count]))
        }
        p.plate(title, fill: Painter.color(0xFFFFFF), border: Painter.color(0x2E2E33), text: Painter.color(0x2E2E33))
    }

    private static func memphis(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0xF8E6E0))
        var random = SeededRandom(seed: 0x3E3F1155)
        let palette: [UInt32] = [0x2B2D42, 0xF2A541, 0x4EA5D9, 0xE4572E, 0x76B041, 0xA06CD5]
        let count = Int(r.width * r.height / (u * u) / 150)
        for n in 0..<count {
            let center = CGPoint(x: r.minX + random.unit() * r.width, y: r.minY + random.unit() * r.height)
            let color = Painter.color(palette[(n + Int(random.unit() * 3)) % palette.count])
            let angle = random.unit() * .pi
            let size = random.range(3.4, 6.5) * u
            let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
            switch n % 5 {
            case 0: // 지그재그
                let path = CGMutablePath()
                for k in 0...5 {
                    let point = CGPoint(x: -size * 1.2 + CGFloat(k) * size * 0.48, y: k.isMultiple(of: 2) ? -size * 0.25 : size * 0.25)
                    if k == 0 { path.move(to: point, transform: t) } else { path.addLine(to: point, transform: t) }
                }
                p.context.setLineJoin(.round)
                p.stroke(path, color, width: 1.1 * u, cap: .round)
            case 1: // 세모 테두리
                let path = CGMutablePath()
                path.addLines(between: [CGPoint(x: 0, y: -size * 0.7), CGPoint(x: size * 0.65, y: size * 0.45),
                                        CGPoint(x: -size * 0.65, y: size * 0.45)], transform: t)
                path.closeSubpath()
                p.context.setLineJoin(.round)
                p.stroke(path, color, width: 1.0 * u)
            case 2: // 동그라미
                p.fill(CGPath(ellipseIn: CGRect(x: center.x - size * 0.4, y: center.y - size * 0.4,
                                                width: size * 0.8, height: size * 0.8), transform: nil), color)
            case 3: // 반원
                let path = CGMutablePath()
                path.addArc(center: .zero, radius: size * 0.6, startAngle: 0, endAngle: .pi, clockwise: false, transform: t)
                path.closeSubpath()
                p.fill(path, color)
            default: // 점 무리
                let path = CGMutablePath()
                for gx in 0..<3 { for gy in 0..<3 {
                    let point = CGPoint(x: CGFloat(gx - 1) * size * 0.45, y: CGFloat(gy - 1) * size * 0.45).applying(t)
                    path.addEllipse(in: CGRect(x: point.x - 0.5 * u, y: point.y - 0.5 * u, width: 1.0 * u, height: 1.0 * u))
                } }
                p.fill(path, color)
            }
        }
        let plate = p.labelRect()
        p.fill(CGPath(rect: plate.offsetBy(dx: 1.2 * u, dy: 1.2 * u), transform: nil), Painter.color(0x2B2D42))
        p.fill(CGPath(rect: plate, transform: nil), Painter.color(0xFFFFFF))
        p.stroke(CGPath(rect: plate, transform: nil), Painter.color(0x2B2D42), width: 0.5 * u)
        p.title(title, in: plate, color: Painter.color(0x2B2D42))
    }

    private static func kraft(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        let base = Painter.color(0xC6A27B)
        p.fill(r, base)
        var random = SeededRandom(seed: 0x6B4AF7)
        let dark = CGMutablePath(), light = CGMutablePath()
        let count = Int(r.width * r.height / (u * u) / 9)
        for _ in 0..<count {
            let start = CGPoint(x: r.minX + random.unit() * r.width, y: r.minY + random.unit() * r.height)
            let angle = random.unit() * .pi
            let length = random.range(0.6, 2.6) * u
            let path = random.unit() < 0.6 ? dark : light
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length))
        }
        p.stroke(dark, Painter.mix(base, .black, 0.13), width: 0.16 * u, cap: .round)
        p.stroke(light, Painter.mix(base, .white, 0.16), width: 0.16 * u, cap: .round)
        // 끈
        let string = Painter.color(0xF4EBDD)
        p.fill(CGRect(x: r.minX, y: r.maxY - r.height * 0.2, width: r.width, height: 0.7 * u), string)
        p.fill(CGRect(x: r.maxX - r.width * 0.2, y: r.minY, width: 0.7 * u, height: r.height), string)
        // 흰 라벨 + 검은 줄
        let plate = p.labelRect()
        p.fill(CGPath(rect: plate, transform: nil), Painter.color(0xFBF8F1))
        p.stroke(CGPath(rect: plate.insetBy(dx: 1 * u, dy: 1 * u), transform: nil), Painter.color(0x2A2620), width: 0.3 * u)
        p.title(title, in: plate, color: Painter.color(0x2A2620))
    }

    // MARK: 그림

    private static func waves(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0xD6EEF0))
        let sun = CGPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.52)
        p.fill(CGPath(ellipseIn: CGRect(x: sun.x - 11 * u, y: sun.y - 11 * u, width: 22 * u, height: 22 * u), transform: nil),
               Painter.color(0xFBE7B5))
        let colors: [UInt32] = [0x8FCFD1, 0x4FA9B3, 0x2B7F92, 0x1D5A75, 0x163D5A]
        for (i, color) in colors.enumerated() {
            let top = r.minY + r.height * (0.56 + 0.085 * CGFloat(i))
            p.fill(wave(in: r, top: top, amplitude: 1.6 * u, halfPeriod: r.width / CGFloat(3 + i % 2) / 2,
                        phase: CGFloat(i) * 0.37), Painter.color(color))
        }
        p.plate(title, fill: Painter.color(0xFFFFFB), border: Painter.color(0x1D5A75), text: Painter.color(0x163D5A))
    }

    private static func mountains(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0xF3E3CF))
        p.fill(CGPath(ellipseIn: CGRect(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.40, width: 17 * u, height: 17 * u),
                      transform: nil), Painter.color(0xEE9B62))
        var random = SeededRandom(seed: 0x40A1E5)
        let layers: [(UInt32, CGFloat, CGFloat)] = [(0xC9B6C9, 0.50, 13), (0x9E8DB0, 0.58, 15), (0x6E6690, 0.66, 13), (0x463F66, 0.76, 10)]
        for (color, level, height) in layers {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            var x = r.minX - 4 * u
            path.addLine(to: CGPoint(x: x, y: r.minY + r.height * level))
            while x < r.maxX + 4 * u {
                let peakWidth = random.range(9, 18) * u
                let peak = CGPoint(x: x + peakWidth / 2, y: r.minY + r.height * level - random.range(0.4, 1) * height * u)
                path.addLine(to: peak)
                x += peakWidth
                path.addLine(to: CGPoint(x: x, y: r.minY + r.height * level + random.range(-1.5, 1.5) * u))
            }
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.closeSubpath()
            p.fill(path, Painter.color(color))
        }
        p.fill(wave(in: r, top: r.minY + r.height * 0.88, amplitude: 1.2 * u, halfPeriod: r.width / 2.5, phase: 0.2),
               Painter.color(0x2C2745))
        p.plate(title, fill: Painter.color(0xFFF9F1), border: Painter.color(0x463F66), text: Painter.color(0x2C2745))
    }

    private static func sunset(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        let sky: [UInt32] = [0x1E1B4B, 0x35226A, 0x5C2A7E, 0x8E3183, 0xC23F79, 0xE9606A, 0xF79457]
        let horizon = r.minY + r.height * 0.7
        let band = (horizon - r.minY) / CGFloat(sky.count)
        for (i, color) in sky.enumerated() {
            p.fill(CGRect(x: r.minX, y: r.minY + band * CGFloat(i), width: r.width, height: band + 0.5), Painter.color(color))
        }
        // 줄무늬 해
        let radius = min(r.width * 0.3, r.height * 0.24)
        let sun = CGPath(ellipseIn: CGRect(x: r.midX - radius, y: horizon - radius, width: radius * 2, height: radius * 2), transform: nil)
        let cuts = CGMutablePath()
        var gap = 0.5 * u
        var y = horizon - radius * 0.45
        while y < horizon {
            cuts.addRect(CGRect(x: r.minX, y: y, width: r.width, height: gap))
            gap += 0.45 * u
            y += radius * 0.16
        }
        cuts.addRect(CGRect(x: r.minX, y: horizon, width: r.width, height: r.maxY - horizon))
        p.fill(sun.subtracting(cuts), Painter.color(0xFFC75F))
        // 바다와 물빛
        p.fill(CGRect(x: r.minX, y: horizon, width: r.width, height: r.maxY - horizon), Painter.color(0x241C55))
        let glints = CGMutablePath()
        for i in 0..<7 {
            let w = radius * 2 * (1 - CGFloat(i) * 0.12)
            glints.addRoundedRect(in: CGRect(x: r.midX - w / 2, y: horizon + 2.5 * u + CGFloat(i) * 3.2 * u, width: w, height: 0.9 * u),
                                  cornerWidth: 0.45 * u, cornerHeight: 0.45 * u)
        }
        p.fill(glints, Painter.color(0xE9606A))
        p.plate(title, fill: Painter.color(0xFFF6EC), border: Painter.color(0x5C2A7E), text: Painter.color(0x35226A))
    }

    private static func night(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0x131A33))
        // 초승달
        let moonRadius = 7 * u
        let moonCenter = CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.42)
        let moon = CGPath(ellipseIn: CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
                                            width: moonRadius * 2, height: moonRadius * 2), transform: nil)
        let bite = CGPath(ellipseIn: CGRect(x: moonCenter.x - moonRadius * 0.55, y: moonCenter.y - moonRadius * 1.05,
                                            width: moonRadius * 2, height: moonRadius * 2), transform: nil)
        p.fill(moon.subtracting(bite), Painter.color(0xF6E7B0))
        // 별
        var random = SeededRandom(seed: 0x5A7A2)
        let small = CGMutablePath(), warm = CGMutablePath()
        let count = Int(r.width * r.height / (u * u) / 70)
        for _ in 0..<count {
            let point = CGPoint(x: r.minX + random.unit() * r.width, y: r.minY + random.unit() * r.height * 0.8)
            if hypot(point.x - moonCenter.x, point.y - moonCenter.y) < moonRadius * 1.4 { continue }
            let radius = random.range(0.12, 0.42) * u
            (random.unit() < 0.7 ? small : warm).addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                                                       width: radius * 2, height: radius * 2))
        }
        p.fill(small, Painter.color(0xE8ECF8))
        p.fill(warm, Painter.color(0xF6E2A6))
        let sparkles = CGMutablePath()
        for _ in 0..<7 {
            let center = CGPoint(x: r.minX + random.range(0.08, 0.92) * r.width, y: r.minY + random.range(0.3, 0.68) * r.height)
            let size = random.range(1.2, 2.2) * u
            let inner = size * 0.22
            for k in 0..<8 {
                let angle = CGFloat(k) * .pi / 4 - .pi / 2
                let radius = k.isMultiple(of: 2) ? size : inner
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if k == 0 { sparkles.move(to: point) } else { sparkles.addLine(to: point) }
            }
            sparkles.closeSubpath()
        }
        p.fill(sparkles, Painter.color(0xFFFFFF))
        // 언덕
        p.fill(wave(in: r, top: r.minY + r.height * 0.84, amplitude: 2.4 * u, halfPeriod: r.width / 1.6, phase: 0.1),
               Painter.color(0x1F2A4D))
        p.fill(wave(in: r, top: r.minY + r.height * 0.9, amplitude: 1.8 * u, halfPeriod: r.width / 2.2, phase: 0.6),
               Painter.color(0x0B1024))
        p.plate(title, fill: Painter.color(0x1F2A4D), border: Painter.color(0xF6E7B0), text: Painter.color(0xF6E7B0))
    }

    private static func leaves(title: String, _ p: inout Painter) {
        let r = p.rect, u = p.u
        p.fill(r, Painter.color(0xE6ECDF))
        var random = SeededRandom(seed: 0x1EAF5)
        let greens: [UInt32] = [0x5E8C61, 0x3F6B4A, 0x8DB38B, 0x2E5240, 0xA9C69A]
        let count = Int(r.width * r.height / (u * u) / 190)
        for n in 0..<count {
            let center = CGPoint(x: r.minX + random.unit() * r.width, y: r.minY + random.unit() * r.height)
            let length = random.range(7, 14) * u
            let width = length * random.range(0.26, 0.4)
            let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: random.unit() * .pi * 2)
            let leaf = CGMutablePath()
            leaf.move(to: CGPoint(x: -length / 2, y: 0), transform: t)
            leaf.addQuadCurve(to: CGPoint(x: length / 2, y: 0), control: CGPoint(x: 0, y: -width), transform: t)
            leaf.addQuadCurve(to: CGPoint(x: -length / 2, y: 0), control: CGPoint(x: 0, y: width), transform: t)
            leaf.closeSubpath()
            let color = Painter.color(greens[n % greens.count])
            p.fill(leaf, color)
            // 잎맥과 꼭지
            let vein = CGMutablePath()
            vein.move(to: CGPoint(x: -length / 2 - length * 0.12, y: 0), transform: t)
            vein.addLine(to: CGPoint(x: length * 0.38, y: 0), transform: t)
            for k in 1...3 {
                let x = -length / 2 + CGFloat(k) * length * 0.22
                vein.move(to: CGPoint(x: x, y: 0), transform: t)
                vein.addLine(to: CGPoint(x: x + length * 0.1, y: -width * 0.45), transform: t)
                vein.move(to: CGPoint(x: x, y: 0), transform: t)
                vein.addLine(to: CGPoint(x: x + length * 0.1, y: width * 0.45), transform: t)
            }
            p.stroke(vein, Painter.mix(color, .white, 0.35), width: 0.22 * u, cap: .round)
        }
        p.plate(title, fill: Painter.color(0xFBFAF4), border: Painter.color(0x3F6B4A), text: Painter.color(0x2E5240))
    }

    private static func bauhaus(title: String, _ p: inout Painter) {
        let r = p.rect
        let palette: [UInt32] = [0xF1E8D8, 0xE3A72F, 0xC8553D, 0x2A7F80, 0x24304A, 0xE8B4A0]
        let columns = r.width > r.height ? 4 : 3
        let side = r.width / CGFloat(columns)
        let rows = Int(ceil(r.height / side))
        var random = SeededRandom(seed: 0xBA0BA05)
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = CGRect(x: r.minX + CGFloat(column) * side, y: r.minY + CGFloat(row) * side, width: side, height: side)
                let bg = Int(random.unit() * CGFloat(palette.count)) % palette.count
                var fg = Int(random.unit() * CGFloat(palette.count)) % palette.count
                if fg == bg { fg = (fg + 2) % palette.count }
                p.fill(cell, Painter.color(palette[bg]))
                let shape = CGMutablePath()
                let corner = Int(random.unit() * 4) % 4
                let corners = [CGPoint(x: cell.minX, y: cell.minY), CGPoint(x: cell.maxX, y: cell.minY),
                               CGPoint(x: cell.maxX, y: cell.maxY), CGPoint(x: cell.minX, y: cell.maxY)]
                switch (row * columns + column + Int(random.unit() * 3)) % 5 {
                case 0: // 사분원
                    let c = corners[corner]
                    shape.move(to: c)
                    shape.addArc(center: c, radius: side, startAngle: CGFloat(corner) * .pi / 2,
                                 endAngle: CGFloat(corner) * .pi / 2 + .pi / 2, clockwise: false)
                    shape.closeSubpath()
                case 1: // 반원
                    let center = CGPoint(x: cell.midX, y: corner < 2 ? cell.maxY : cell.minY)
                    shape.addArc(center: center, radius: side / 2, startAngle: corner < 2 ? .pi : 0,
                                 endAngle: corner < 2 ? 0 : .pi, clockwise: false)
                    shape.closeSubpath()
                case 2: // 원
                    shape.addEllipse(in: cell.insetBy(dx: side * 0.14, dy: side * 0.14))
                case 3: // 반쪽 세모
                    shape.addLines(between: [corners[corner], corners[(corner + 1) % 4], corners[(corner + 2) % 4]])
                    shape.closeSubpath()
                default: // 고리
                    shape.addEllipse(in: cell.insetBy(dx: side * 0.12, dy: side * 0.12))
                    shape.addEllipse(in: cell.insetBy(dx: side * 0.3, dy: side * 0.3))
                }
                p.context.addPath(shape)
                p.context.setFillColor(Painter.color(palette[fg]))
                p.context.fillPath(using: .evenOdd)
            }
        }
        p.plate(title, fill: Painter.color(0xF7F1E6), border: Painter.color(0x24304A), text: Painter.color(0x24304A))
    }

    /// 위쪽 가장자리가 물결인 띠 (아래 끝까지 채움). 2차 곡선을 위아래로 번갈아 이어서 매끈함
    private static func wave(in r: CGRect, top: CGFloat, amplitude: CGFloat, halfPeriod: CGFloat, phase: CGFloat) -> CGPath {
        let path = CGMutablePath()
        var x = r.minX - halfPeriod * (1 + phase)
        path.move(to: CGPoint(x: x, y: r.maxY))
        path.addLine(to: CGPoint(x: x, y: top))
        var up = true
        while x < r.maxX {
            path.addQuadCurve(to: CGPoint(x: x + halfPeriod, y: top),
                              control: CGPoint(x: x + halfPeriod / 2, y: top + (up ? -2 : 2) * amplitude))
            x += halfPeriod
            up.toggle()
        }
        path.addLine(to: CGPoint(x: x, y: r.maxY))
        path.closeSubpath()
        return path
    }
}

/// 표지 그리기 도구 (u = 짧은 변의 1/100 → 종이 크기·방향이 달라도 비율이 같음)
nonisolated struct Painter {
    let context: CGContext
    let rect: CGRect
    let u: CGFloat

    init(context: CGContext, rect: CGRect) {
        self.context = context
        self.rect = rect
        u = min(rect.width, rect.height) / 100
    }

    static func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// 두 색을 섞은 불투명 색 (PDF에서 투명도 없이 똑같이 보이게)
    static func mix(_ a: CGColor, _ b: UIColor, _ amount: CGFloat) -> CGColor {
        let first = UIColor(cgColor: a), second = b
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return CGColor(srgbRed: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    func fill(_ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
    }

    func fill(_ path: CGPath, _ color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat, cap: CGLineCap = .butt) {
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(cap)
        context.strokePath()
    }

    /// 제목 라벨 자리 (위쪽 1/6쯤, 가운데)
    func labelRect() -> CGRect {
        let landscape = rect.width > rect.height
        let width = rect.width * (landscape ? 0.56 : 0.68)
        let height = max(15 * u, rect.height * (landscape ? 0.19 : 0.14))
        return CGRect(x: rect.midX - width / 2, y: rect.minY + rect.height * (landscape ? 0.16 : 0.15), width: width, height: height)
    }

    /// 라벨 판 + 안쪽 테두리 + 제목
    func plate(_ title: String, fill: CGColor, border: CGColor, text: CGColor) {
        let plate = labelRect()
        self.fill(UIBezierPath(roundedRect: plate, cornerRadius: 1.4 * u).cgPath, fill)
        stroke(UIBezierPath(roundedRect: plate.insetBy(dx: 1.1 * u, dy: 1.1 * u), cornerRadius: 0.8 * u).cgPath,
               border, width: 0.3 * u)
        self.title(title, in: plate, color: text)
    }

    /// 판 안에 들어가게 글자 크기를 줄여 가며 가운데에
    func title(_ title: String, in plate: CGRect, color: CGColor) {
        guard !title.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let maxWidth = plate.width - 7 * u
        var size = min(plate.height * 0.5, 12 * u)
        var font = UIFont.systemFont(ofSize: size, weight: .bold)
        while size > 3 * u {
            font = UIFont.systemFont(ofSize: size, weight: .bold)
            if (title as NSString).size(withAttributes: [.font: font]).width <= maxWidth { break }
            size *= 0.92
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: UIColor(cgColor: color), .paragraphStyle: paragraph, .kern: size * 0.02,
        ])
        let height = font.lineHeight
        text.draw(in: CGRect(x: plate.minX + 3 * u, y: plate.midY - height / 2, width: maxWidth, height: height))
    }
}

/// 정해진 씨앗으로 늘 같은 순서를 내는 난수 (SplitMix64)
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 이상 1 미만
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }

    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * unit() }
}
