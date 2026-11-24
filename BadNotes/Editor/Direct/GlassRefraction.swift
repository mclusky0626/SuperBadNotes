//
//  GlassRefraction.swift
//  BadNotes
//
//  Liquid Glass 펜·유리 글자의 굴절을 직접 계산.
//  Apple 유리(glassEffect)는 모양 전체를 하나의 렌즈로 보고 굴절을 계산해서, 손글씨처럼 길고 가늘고
//  꼬인 모양에서는 뒤 그림이 소용돌이치듯 심하게 왜곡됨. 그래서 획·글자마다 '둥근 유리 막대'로 보고 계산:
//  - 높이: 가장자리에서 안쪽까지 거리 d로 원 단면 h = R·√(1 − (1 − d/R)²) (R = 획 굵기의 절반)
//  - 법선: 높이의 기울기, 빛은 스넬 법칙(굴절률 1.5)으로 꺾여서 두께 h만큼 지나간 자리의 바탕을 봄
//    → 막대 두께 이상으로는 안 밀려서 자연스러운 볼록렌즈처럼 보임
//  - 색 입히기(진하기) + 위쪽 반사광 + 가장자리 빛(프레넬) + 아래 그늘 + 그림자
//  바탕(PDF + 상자·사진 + 유리 아닌 필기)을 직접 그려서 픽셀로 계산 → 백그라운드에서
//

import UIKit
import PDFKit
import PencilKit

nonisolated enum GlassRefraction {
    struct Shape {
        /// 페이지 좌표의 윤곽
        let path: CGPath
        /// 막대 반지름 (페이지 pt)
        let radius: CGFloat
        let tint: (r: CGFloat, g: CGFloat, b: CGFloat)
        let strength: CGFloat
    }

    struct Scene {
        let page: PDFPage?
        let pageSize: CGSize
        let board: Bool
        let documentLock: ReadWriteLock?
        let elements: [PageElement]
        let images: [String: CGImage]
        let strokes: [SampledStroke]
        let shapes: [Shape]
    }

    /// 유리가 놓인 영역과 그 그림 (영역 밖은 투명)
    static func render(_ scene: Scene) -> (image: CGImage, frame: CGRect, scale: CGFloat)? {
        guard !scene.shapes.isEmpty else { return nil }
        let pad = (scene.shapes.map(\.radius).max() ?? 4) * 1.5 + 6
        let union = scene.shapes.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        let frame = union.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: scene.pageSize)).integral
        guard !frame.isNull, frame.width >= 1, frame.height >= 1 else { return nil }
        // 확대해도 덜 흐리게 넉넉히, 단 너무 크면 줄임
        let scale = max(1.5, min(4, sqrt(28_000_000 / (frame.width * frame.height))))
        let width = Int((frame.width * scale).rounded(.up)), height = Int((frame.height * scale).rounded(.up))
        guard width > 0, height > 0, let background = renderBackground(scene, frame: frame, scale: scale,
                                                                        width: width, height: height) else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let out = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        // 위가 원점, 페이지 좌표 → 픽셀
        out.translateBy(x: 0, y: CGFloat(height))
        out.scaleBy(x: 1, y: -1)
        out.scaleBy(x: scale, y: scale)
        out.translateBy(x: -frame.minX, y: -frame.minY)

        // 1. 그림자 (유리 밑)
        for shape in scene.shapes {
            out.saveGState()
            out.setShadow(offset: CGSize(width: 0, height: -shape.radius * 0.35 * scale), blur: shape.radius * 1.1 * scale,
                          color: UIColor(white: 0, alpha: 0.28).cgColor)
            out.addPath(shape.path)
            out.setFillColor(UIColor(white: 0, alpha: 0.12).cgColor)
            out.fillPath()
            out.restoreGState()
        }
        guard let outData = out.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bg = background
        bg.withUnsafeBufferPointer { bgPixels in
            for shape in scene.shapes {
                refract(shape, frame: frame, scale: scale, width: width, height: height, background: bgPixels, output: outData)
            }
        }
        guard let image = out.makeImage() else { return nil }
        return (image, frame, scale)
    }

    // MARK: 바탕 그리기 (유리 없이)

    private static func renderBackground(_ scene: Scene, frame: CGRect, scale: CGFloat, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(scene.board ? UIColor(red: 0.985, green: 0.983, blue: 0.975, alpha: 1).cgColor : UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // 페이지 좌표 (위가 원점)
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -frame.minX, y: -frame.minY)
            if let page = scene.page, !scene.board {
                let draw = {
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: scene.pageSize.height)
                    ctx.scaleBy(x: 1, y: -1)
                    page.draw(with: .cropBox, to: ctx)
                    ctx.restoreGState()
                }
                if let lock = scene.documentLock { lock.read(draw) } else { draw() }
            }
            UIGraphicsPushContext(ctx)
            for element in scene.elements where element.frame.intersects(frame) {
                ElementRenderer.drawBackground(element, in: ctx, rect: element.frame, live: false)
                ElementRenderer.drawContent(element, image: element.imageID.flatMap { scene.images[$0] }, in: ctx, rect: element.frame)
            }
            UIGraphicsPopContext()
            var appleRun: [PKStroke] = []
            func flushApple() {
                guard !appleRun.isEmpty else { return }
                let drawing = PKDrawing(strokes: appleRun)
                appleRun = []
                var image: UIImage?
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    image = drawing.image(from: frame, scale: scale)
                }
                guard let image else { return }
                UIGraphicsPushContext(ctx)
                image.draw(in: frame)
                UIGraphicsPopContext()
            }
            for stroke in scene.strokes where stroke.glassStrength == nil && stroke.bounds.intersects(frame) {
                if let source = stroke.appleSource {
                    appleRun.append(source)
                } else {
                    flushApple()
                    InkRenderer.draw(stroke, in: ctx, smooth: true)
                }
            }
            flushApple()
            return true
        }
        return ok ? pixels : nil
    }

    // MARK: 굴절

    private static func refract(_ shape: Shape, frame: CGRect, scale: CGFloat, width: Int, height: Int,
                                background: UnsafeBufferPointer<UInt8>, output: UnsafeMutablePointer<UInt8>) {
        let box = shape.path.boundingBoxOfPath
        let x0 = max(0, Int(((box.minX - frame.minX) * scale).rounded(.down)) - 2)
        let y0 = max(0, Int(((box.minY - frame.minY) * scale).rounded(.down)) - 2)
        let x1 = min(width, Int(((box.maxX - frame.minX) * scale).rounded(.up)) + 2)
        let y1 = min(height, Int(((box.maxY - frame.minY) * scale).rounded(.up)) + 2)
        let w = x1 - x0, h = y1 - y0
        guard w > 2, h > 2 else { return }

        // 모양 덮임 정도 (가장자리 부드럽게)
        var coverage = [UInt8](repeating: 0, count: w * h)
        coverage.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -CGFloat(x0), y: -CGFloat(y0))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -frame.minX, y: -frame.minY)
            ctx.addPath(shape.path)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillPath()
        }

        // 가장자리까지 거리 (모따기 거리 변환, 두 번 훑기)
        let far: Float = 1e6
        var distance = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { distance[i] = coverage[i] > 127 ? far : 0 }
        let diagonal: Float = 1.4142
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard distance[i] > 0 else { continue }
                var d = distance[i]
                if x > 0 { d = min(d, distance[i - 1] + 1) }
                if y > 0 {
                    d = min(d, distance[i - w] + 1)
                    if x > 0 { d = min(d, distance[i - w - 1] + diagonal) }
                    if x < w - 1 { d = min(d, distance[i - w + 1] + diagonal) }
                }
                distance[i] = d
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                guard distance[i] > 0 else { continue }
                var d = distance[i]
                if x < w - 1 { d = min(d, distance[i + 1] + 1) }
                if y < h - 1 {
                    d = min(d, distance[i + w] + 1)
                    if x < w - 1 { d = min(d, distance[i + w + 1] + diagonal) }
                    if x > 0 { d = min(d, distance[i + w - 1] + diagonal) }
                }
                distance[i] = d
            }
        }

        // 높이: 원 단면 막대
        let rad = max(1.5, Float(shape.radius * scale))
        var heightMap = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where coverage[i] > 0 {
            let d = max(distance[i] - 0.5, 0) + Float(coverage[i]) / 255 * 0.5
            let t = min(d, rad) / rad
            heightMap[i] = rad * (1 - (1 - t) * (1 - t)).squareRoot()
        }

        // 거리 계산의 계단 때문에 생기는 결(줄무늬)을 없애려고 높이를 부드럽게 (3×3 평균 두 번, 모양 안에서만)
        for _ in 0..<2 {
            var smooth = heightMap
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    guard coverage[i] > 0 else { continue }
                    var sum: Float = 0
                    for oy in -1...1 { for ox in -1...1 { sum += heightMap[i + oy * w + ox] } }
                    smooth[i] = sum / 9
                }
            }
            heightMap = smooth
        }

        let tintR = Float(shape.tint.r) * 255, tintG = Float(shape.tint.g) * 255, tintB = Float(shape.tint.b) * 255
        let tintAmount = 0.06 + Float(shape.strength) * 0.62
        let eta: Float = 1 / 1.5
        // 빛: 왼쪽 위에서 (화면 아래가 +y)
        var light = (x: Float(-0.35), y: Float(-0.75), z: Float(0.56))
        let ll = (light.x * light.x + light.y * light.y + light.z * light.z).squareRoot()
        light = (light.x / ll, light.y / ll, light.z / ll)
        let half = { () -> (Float, Float, Float) in
            let hx = light.x, hy = light.y, hz = light.z + 1
            let n = (hx * hx + hy * hy + hz * hz).squareRoot()
            return (hx / n, hy / n, hz / n)
        }()

        func sample(_ fx: Float, _ fy: Float) -> (Float, Float, Float) {
            let cx = min(max(fx, 0), Float(width - 1)), cy = min(max(fy, 0), Float(height - 1))
            let ix = Int(cx), iy = Int(cy)
            let ax = cx - Float(ix), ay = cy - Float(iy)
            let ix1 = min(ix + 1, width - 1), iy1 = min(iy + 1, height - 1)
            func px(_ x: Int, _ y: Int) -> (Float, Float, Float) {
                let o = (y * width + x) * 4
                return (Float(background[o]), Float(background[o + 1]), Float(background[o + 2]))
            }
            let a = px(ix, iy), b = px(ix1, iy), c = px(ix, iy1), d = px(ix1, iy1)
            func mix(_ p: Float, _ q: Float, _ r: Float, _ s: Float) -> Float {
                (p * (1 - ax) + q * ax) * (1 - ay) + (r * (1 - ax) + s * ax) * ay
            }
            return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2))
        }

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let cover = Float(coverage[i]) / 255
                guard cover > 0.01 else { continue }
                // 기울기 → 법선
                let gx = (heightMap[i + 1] - heightMap[i - 1]) * 0.5
                let gy = (heightMap[i + w] - heightMap[i - w]) * 0.5
                var nx = -gx, ny = -gy, nz: Float = 1
                let nl = (nx * nx + ny * ny + nz * nz).squareRoot()
                nx /= nl; ny /= nl; nz /= nl
                // 스넬 법칙: 위에서 내려오는 시선이 표면에서 꺾여 두께만큼 지나간 자리
                let cosi = nz
                let k = 1 - eta * eta * (1 - cosi * cosi)
                var dx: Float = 0, dy: Float = 0
                if k > 0 {
                    let factor = eta * cosi - k.squareRoot()
                    let tx = factor * nx, ty = factor * ny, tz = -eta + factor * nz
                    let travel = heightMap[i] * 1.15
                    if tz < -0.05 { dx = travel * tx / -tz; dy = travel * ty / -tz }
                }
                let gxPix = Float(x0 + x), gyPix = Float(y0 + y)
                var (r, g, b) = sample(gxPix + dx, gyPix + dy)
                // 유리 색 + 살짝 밝게
                r = r * (1 - tintAmount) + tintR * tintAmount
                g = g * (1 - tintAmount) + tintG * tintAmount
                b = b * (1 - tintAmount) + tintB * tintAmount
                r = r * 0.95 + 12; g = g * 0.95 + 12; b = b * 0.95 + 12
                // 아래쪽 면은 살짝 어둡게, 위쪽 반사광, 가장자리 빛
                let shade = max(0, ny) * 0.16
                r *= 1 - shade; g *= 1 - shade; b *= 1 - shade
                let specDot = max(0, nx * half.0 + ny * half.1 + nz * half.2)
                let spec = pow(specDot, 70) * 0.9 + pow(specDot, 12) * 0.12
                let rim = pow(1 - nz, 2.2) * 0.45
                let glow = min(1, spec + rim) * 255
                r = min(255, r + glow); g = min(255, g + glow); b = min(255, b + glow)

                // 원래 그림자 위에 덮어 칠하기 (덮임만큼)
                let o = ((y0 + y) * width + (x0 + x)) * 4
                let a = cover
                output[o] = UInt8(min(255, r * a + Float(output[o]) * (1 - a)))
                output[o + 1] = UInt8(min(255, g * a + Float(output[o + 1]) * (1 - a)))
                output[o + 2] = UInt8(min(255, b * a + Float(output[o + 2]) * (1 - a)))
                output[o + 3] = UInt8(min(255, 255 * a + Float(output[o + 3]) * (1 - a)))
            }
        }
    }
}
