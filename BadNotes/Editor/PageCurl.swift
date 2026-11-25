//
//  PageCurl.swift
//  BadNotes
//
//  종이 말려 넘기기 (android-page-curl 방식을 Metal로).
//  - 넘기는 종이 = 촘촘한 격자. 손가락이 잡은 가장자리 점 S가 손가락 F를 따라가도록 말리는 선(C, 방향 n)과
//    원통 반지름 R을 정하고, 선 너머 격자는 원통을 감고 넘어가 반대쪽에 뒤집혀 눕는다
//  - 종이는 책등에 붙어 있음: 잡은 점은 책등에서 종이 폭보다 멀리 못 감 (손가락이 멀리 가도 찢어지지 않게)
//  - 다 넘기면 R → 0 이라 뒷면이 반대쪽 자리에 딱 맞게 누움 → 실제 페이지로 바꿔도 티가 안 남
//  - 그림자: 말린 종이 밑 바닥 그늘 + 들린 종이가 드리우는 그림자 + 곡면 빛
//

import UIKit
import MetalKit

/// 말림 계산 (화면 좌표, pt). 화면과 상관없는 순수 계산이라 자체 점검에서도 씀
nonisolated struct CurlGeometry: Sendable {
    /// 넘기는 종이 자리
    let rect: CGRect
    /// 책등이 종이 왼쪽이면 true (앞으로 넘기는 오른쪽 페이지, 한 쪽 보기)
    let spineOnLeft: Bool

    var spineX: CGFloat { spineOnLeft ? rect.minX : rect.maxX }
    var freeX: CGFloat { spineOnLeft ? rect.maxX : rect.minX }
    var width: CGFloat { rect.width }

    /// 안 넘긴 상태에서 잡은 점 (바깥 가장자리)
    func rest(_ y: CGFloat) -> CGPoint { CGPoint(x: freeX, y: y) }
    /// 다 넘긴 상태 (책등 건너편에 거울처럼)
    func turned(_ y: CGFloat) -> CGPoint { CGPoint(x: 2 * spineX - freeX, y: y) }

    /// 스크롤 위치나 앞뒷면 높이가 다른 펼침면도 접힌 종이와 실제 다음 페이지의 모서리를 맞춘다.
    func landingTransform(to target: CGRect?, progress: CGFloat) -> CGAffineTransform {
        guard let target, !target.isEmpty, !rect.isEmpty else { return .identity }
        let t = progress * progress * (3 - 2 * progress)
        let foldedX = 2 * spineX - rect.maxX
        let sx = target.width / rect.width, sy = target.height / rect.height
        return CGAffineTransform(a: 1 + t * (sx - 1), b: 0, c: 0, d: 1 + t * (sy - 1),
                                 tx: t * (target.minX - foldedX * sx), ty: t * (target.minY - rect.minY * sy))
    }

    struct State: Equatable {
        /// 말리기 시작하는 선 위의 점과 말리는 쪽 방향 (바깥 가장자리 쪽)
        var point: CGPoint
        var normal: CGVector
        var radius: CGFloat
        var flat: Bool
        /// 0 = 안 넘김, 1 = 다 넘김
        var turned: CGFloat
    }

    /// 잡은 점은 책등(같은 높이)에서 종이 폭 안에만 있을 수 있음
    func clamp(_ finger: CGPoint, grabY: CGFloat) -> CGPoint {
        let dx = finger.x - spineX, dy = finger.y - grabY
        let length = hypot(dx, dy)
        guard length > width, length > 0 else { return finger }
        return CGPoint(x: spineX + dx / length * width, y: grabY + dy / length * width)
    }

    func state(finger raw: CGPoint, grabY: CGFloat) -> State {
        let s = rest(grabY)
        let f = clamp(raw, grabY: grabY)
        let outward: CGFloat = spineOnLeft ? 1 : -1
        let vx = s.x - f.x, vy = s.y - f.y
        let distance = hypot(vx, vy)
        guard distance > 0.5, vx * outward > 0 else {
            return State(point: s, normal: CGVector(dx: outward, dy: 0), radius: 0, flat: true, turned: 0)
        }
        let n = CGVector(dx: vx / distance, dy: vy / distance)
        // 처음엔 손가락이 간 만큼만 둥글게, 거의 다 넘기면 다시 납작하게
        let radius = max(0, min(width * 0.16, distance / .pi, (2 * width - distance) / .pi))
        // S가 원통을 감고 넘어가 F에 오는 자리: |S-C| = (|S-F| + πR) / 2
        let along = (distance + .pi * radius) / 2
        let c = CGPoint(x: s.x - n.dx * along, y: s.y - n.dy * along)
        return State(point: c, normal: n, radius: radius, flat: false, turned: min(1, distance / (2 * width)))
    }
}

/// 한 번만 만드는 Metal 준비물 (셰이더는 실행할 때 컴파일)
nonisolated final class CurlResources: @unchecked Sendable {
    static let shared = CurlResources()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let leaf: MTLRenderPipelineState
    let shadow: MTLRenderPipelineState
    let floor: MTLRenderPipelineState
    let leafDepth: MTLDepthStencilState
    let shadowStencil: MTLDepthStencilState
    let noDepth: MTLDepthStencilState
    let grid: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int

    static let depthFormat = MTLPixelFormat.depth32Float_stencil8

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                d.depthAttachmentPixelFormat = Self.depthFormat
                d.stencilAttachmentPixelFormat = Self.depthFormat
                if blend {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .one
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .one
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            leaf = try pipeline("leafVertex", "leafFragment", blend: false)
            shadow = try pipeline("shadowVertex", "shadowFragment", blend: true)
            floor = try pipeline("floorVertex", "floorFragment", blend: true)
        } catch {
            Log.error("종이 넘기기 셰이더를 못 만듦: \(error)")
            return nil
        }
        let leafD = MTLDepthStencilDescriptor()
        leafD.depthCompareFunction = .less
        leafD.isDepthWriteEnabled = true
        // 그림자는 한 점에 한 번만 (겹친 삼각형이 두 번 어두워지지 않게)
        let shadowD = MTLDepthStencilDescriptor()
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .equal
        stencil.depthStencilPassOperation = .incrementClamp
        shadowD.frontFaceStencil = stencil
        shadowD.backFaceStencil = stencil
        guard let leafDepth = device.makeDepthStencilState(descriptor: leafD),
              let shadowStencil = device.makeDepthStencilState(descriptor: shadowD),
              let noDepth = device.makeDepthStencilState(descriptor: MTLDepthStencilDescriptor()) else { return nil }

        // 격자: 접히는 선이 날카로워도 들쭉날쭉하지 않게 촘촘히
        let nx = 96, ny = 128
        var uv: [SIMD2<Float>] = []
        uv.reserveCapacity(nx * ny)
        for j in 0..<ny {
            for i in 0..<nx { uv.append(SIMD2(Float(i) / Float(nx - 1), Float(j) / Float(ny - 1))) }
        }
        var index: [UInt32] = []
        index.reserveCapacity((nx - 1) * (ny - 1) * 6)
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let a = UInt32(j * nx + i), b = a + 1, c = a + UInt32(nx), d = c + 1
                index += [a, c, b, b, c, d]
            }
        }
        guard let grid = device.makeBuffer(bytes: uv, length: uv.count * MemoryLayout<SIMD2<Float>>.stride),
              let indices = device.makeBuffer(bytes: index, length: index.count * 4) else { return nil }
        self.device = device
        self.queue = queue
        self.leafDepth = leafDepth
        self.shadowStencil = shadowStencil
        self.noDepth = noDepth
        self.grid = grid
        self.indices = indices
        self.indexCount = index.count
    }

    /// 페이지 사진 → 텍스처. 어떤 색 형식의 사진이든 화면과 같은 8비트 BGRA(sRGB)로 다시 그려서 올림
    func texture(_ image: CGImage) -> MTLTexture? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: rowBytes, space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard drawn, let texture = device.makeTexture(descriptor: descriptor) else {
            Log.warn("종이 넘기기: 텍스처를 못 만듦 (\(width)×\(height))")
            return nil
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: rowBytes)
        return texture
    }

    /// 그릴 것 한 벌 (화면과 자체 점검이 같이 씀)
    struct Frame {
        var viewSize: CGSize
        var leafRect: CGRect
        var underRect: CGRect?
        var state: CurlGeometry.State
        var pageWidth: CGFloat
        var front: MTLTexture
        var back: MTLTexture?
        var landingTransform: CGAffineTransform = .identity
    }

    private func uniforms(_ f: Frame, rect: CGRect) -> [SIMD4<Float>] {
        let s = f.state
        let t = f.landingTransform
        return [
            SIMD4(Float(f.viewSize.width), Float(f.viewSize.height), Float(rect.minX), Float(rect.minY)),
            SIMD4(Float(rect.width), Float(rect.height), Float(s.point.x), Float(s.point.y)),
            SIMD4(Float(s.normal.dx), Float(s.normal.dy), Float(max(s.radius, 0.0001)), f.back == nil ? 0 : 1),
            // 다 넘길 무렵(반지름이 줄면) 그림자도 같이 옅어짐
            SIMD4(0.26, s.flat ? 1 : 0, Float(0.34 * min(1, s.radius / max(1, f.pageWidth * 0.08))), 0),
            SIMD4(Float(t.a), Float(t.d), Float(t.tx), Float(t.ty)),
        ]
    }

    func encode(_ f: Frame, into encoder: MTLRenderCommandEncoder) {
        let length = MemoryLayout<SIMD4<Float>>.stride * 5
        // 격자 삼각형은 화면에서 반시계 방향 = 종이 앞면 (뒤집히면 시계 방향 = 뒷면)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        var leafU = uniforms(f, rect: f.leafRect)
        if !f.state.flat, let under = f.underRect {
            var floorU = uniforms(f, rect: under)
            encoder.setRenderPipelineState(floor)
            encoder.setDepthStencilState(noDepth)
            encoder.setVertexBytes(&floorU, length: length, index: 0)
            encoder.setFragmentBytes(&floorU, length: length, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setVertexBuffer(grid, offset: 0, index: 0)
        encoder.setVertexBytes(&leafU, length: length, index: 1)
        if !f.state.flat {
            encoder.setRenderPipelineState(shadow)
            encoder.setDepthStencilState(shadowStencil)
            encoder.setStencilReferenceValue(0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: 0)
        }
        encoder.setRenderPipelineState(leaf)
        encoder.setDepthStencilState(leafDepth)
        encoder.setFragmentTexture(f.front, index: 0)
        encoder.setFragmentTexture(f.back ?? f.front, index: 1)
        encoder.setFragmentBytes(&leafU, length: length, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
    }

    /// 첫 넘기기가 늦지 않게 미리 (셰이더 컴파일)
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = CurlResources.shared }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct U {
        float4 a; // 화면 폭, 높이, 종이 x, y
        float4 b; // 종이 폭, 높이, 말리는 선 점 x, y
        float4 c; // 방향 x, y, 반지름, 뒷면 있음
        float4 d; // 그림자 진하기, 납작함, 바닥 그늘 진하기, -
        float4 landing; // 원래 종이 좌표에서 내려앉을 화면 좌표로 가는 배율과 이동
    };

    struct LeafOut {
        float4 position [[position]];
        float2 uv;
        float3 normal;
    };

    struct ShadowOut {
        float4 position [[position]];
        float alpha;
    };

    struct FloorOut {
        float4 position [[position]];
        float2 p;
    };

    static float4 toClip(float2 p, float z, constant U& u) {
        return float4(p.x / u.a.x * 2.0 - 1.0, 1.0 - p.y / u.a.y * 2.0, clamp(0.5 - z * 0.0004, 0.0, 1.0), 1.0);
    }

    static void curl(float2 p, constant U& u, thread float2& q, thread float& z, thread float3& nrm) {
        float2 C = u.b.zw;
        float2 n = u.c.xy;
        float R = u.c.z;
        float dist = dot(p - C, n);
        if (u.d.y > 0.5 || dist <= 0.0) {
            q = p; z = 0.0; nrm = float3(0.0, 0.0, 1.0);
            return;
        }
        float arc = M_PI_F * R;
        if (dist < arc) {
            float ang = dist / R;
            q = p - n * dist + n * (R * sin(ang));
            z = R * (1.0 - cos(ang));
            nrm = float3(-n * sin(ang), cos(ang));
        } else {
            q = p - n * dist - n * (dist - arc);
            z = 2.0 * R + 0.8;
            nrm = float3(0.0, 0.0, -1.0);
        }
    }

    vertex LeafOut leafVertex(uint vid [[vertex_id]], const device float2* grid [[buffer(0)]],
                              constant U& u [[buffer(1)]]) {
        float2 uv = grid[vid];
        float2 q; float z; float3 nrm;
        curl(u.a.zw + uv * u.b.xy, u, q, z, nrm);
        LeafOut o;
        o.position = toClip(q * u.landing.xy + u.landing.zw, z, u);
        o.uv = uv;
        o.normal = nrm;
        return o;
    }

    fragment float4 leafFragment(LeafOut in [[stage_in]], bool facingFront [[front_facing]],
                                 texture2d<float> front [[texture(0)]],
                                 texture2d<float> back [[texture(1)]], constant U& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // 앞·뒷면은 삼각형 감김 방향으로 (접힌 선에서 법선을 섞으면 0이 돼서 NaN → 검게 나오던 것)
        float len = length(in.normal);
        float3 N = len > 0.05 ? in.normal / len : float3(0.0, 0.0, facingFront ? 1.0 : -1.0);
        float3 color;
        if (facingFront) {
            color = front.sample(s, in.uv).rgb;
        } else if (u.c.w > 0.5) {
            // 책등을 축으로 뒤집혀서 좌우가 바뀜
            color = back.sample(s, float2(1.0 - in.uv.x, in.uv.y)).rgb;
        } else {
            // 뒷면이 없으면 앞면이 살짝 비치는 흰 종이
            color = mix(front.sample(s, in.uv).rgb, float3(1.0), 0.88);
        }
        float3 Nv = facingFront ? N : -N;
        Nv.z = abs(Nv.z);
        float3 L = normalize(float3(-0.25, -0.35, 1.0));
        // 납작한 종이는 원래 밝기 그대로 (실제 페이지와 이어 붙여도 티 안 나게)
        float shade = (0.55 + 0.45 * max(dot(Nv, L), 0.0)) / (0.55 + 0.45 * L.z);
        float3 H = normalize(L + float3(0.0, 0.0, 1.0));
        float spec = pow(max(dot(Nv, H), 0.0), 24.0) * 0.10 * (1.0 - Nv.z);
        float3 outColor = clamp(color * shade + spec, 0.0, 1.0);
        if (any(isnan(outColor))) outColor = color;
        return float4(outColor, 1.0);
    }

    vertex ShadowOut shadowVertex(uint vid [[vertex_id]], const device float2* grid [[buffer(0)]],
                                  constant U& u [[buffer(1)]]) {
        float2 uv = grid[vid];
        float2 q; float z; float3 nrm;
        curl(u.a.zw + uv * u.b.xy, u, q, z, nrm);
        float lift = min(z, 80.0);
        ShadowOut o;
        o.position = toClip(q * u.landing.xy + u.landing.zw + float2(0.16, 0.26) * lift, 0.0, u);
        o.position.z = 0.95;
        o.alpha = u.d.x * clamp(z / 26.0, 0.0, 1.0);
        return o;
    }

    fragment float4 shadowFragment(ShadowOut in [[stage_in]]) {
        return float4(0.0, 0.0, 0.0, in.alpha);
    }

    vertex FloorOut floorVertex(uint vid [[vertex_id]], constant U& u [[buffer(0)]]) {
        float2 uv = float2(float(vid & 1), float(vid >> 1));
        float2 p = u.a.zw + uv * u.b.xy;
        FloorOut o;
        o.position = toClip(p, 0.0, u);
        o.position.z = 0.99;
        o.p = (p - u.landing.zw) / u.landing.xy;
        return o;
    }

    /// 말린 종이 밑, 드러난 새 페이지에 지는 그늘 (말린 곳 가까울수록 진함)
    fragment float4 floorFragment(FloorOut in [[stage_in]], constant U& u [[buffer(0)]]) {
        float2 C = u.b.zw;
        float2 n = u.c.xy;
        float R = u.c.z;
        float dist = dot(in.p - C, n);
        float w = max(10.0, R * 1.5);
        float a = u.d.z * exp(-max(dist - R * 0.4, 0.0) / w);
        return float4(0.0, 0.0, 0.0, a);
    }
    """
}

/// 넘어가는 종이 한 장을 그리는 화면 (페이지 위에 투명하게 덮음)
final class PageCurlView: MTKView {
    let geometry: CurlGeometry
    let grabY: CGFloat
    /// 종이 밑에서 드러나는 페이지 자리 (그늘을 드리움). 빈 자리면 nil
    var underRect: CGRect?
    /// 다 접힌 종이의 뒷면과 교체할 실제 페이지의 화면 좌표
    var landingRect: CGRect?
    /// 한 쪽 보기: 다 넘긴 종이는 화면 밖이라 끝 무렵 옅어짐
    var fadesWhenTurned = false

    private let resources: CurlResources
    private let front: MTLTexture
    private let back: MTLTexture?
    private(set) var finger: CGPoint
    private(set) var state: CurlGeometry.State
    private var link: CADisplayLink?
    private var animation: (from: CGPoint, to: CGPoint, start: CFTimeInterval, duration: CFTimeInterval,
                            lift: CGFloat, easeInOut: Bool, done: () -> Void)?

    init?(frame: CGRect, geometry: CurlGeometry, grabY: CGFloat, finger: CGPoint, front: CGImage, back: CGImage?) {
        guard let resources = CurlResources.shared else {
            Log.warn("종이 넘기기: Metal 준비 못 함")
            return nil
        }
        guard let frontTexture = resources.texture(front) else { return nil }
        self.resources = resources
        self.geometry = geometry
        self.grabY = grabY
        self.front = frontTexture
        self.back = back.flatMap(resources.texture)
        self.finger = finger
        self.state = geometry.state(finger: finger, grabY: grabY)
        super.init(frame: frame, device: resources.device)
        isOpaque = false
        layer.isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = CurlResources.depthFormat
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clearDepth = 1
        clearStencil = 0
        framebufferOnly = true
        // 페이지 배치가 바뀌는 그 순간에 같이 보이게 (한 프레임 번쩍임 없이)
        presentsWithTransaction = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = false
        let scale = UIScreen.main.scale
        contentScaleFactor = scale
        drawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFinger(_ point: CGPoint) {
        finger = point
        state = geometry.state(finger: point, grabY: grabY)
        if fadesWhenTurned {
            let t = min(max((state.turned - 0.8) / 0.2, 0), 1)
            alpha = 1 - t * t * (3 - 2 * t)
        }
        draw()
    }

    /// 손가락 자리를 target까지 옮기며 넘김. lift: 가운데쯤 위로 들어 올리는 높이 (모서리부터 말리게)
    func animate(to target: CGPoint, duration: CFTimeInterval, lift: CGFloat = 0, easeInOut: Bool = false,
                 completion: @escaping () -> Void) {
        animation = (finger, target, CACurrentMediaTime(), max(0.05, duration), lift, easeInOut, completion)
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    var isAnimating: Bool { animation != nil }

    func stop() {
        link?.invalidate()
        link = nil
        animation = nil
    }

    @objc private func step() {
        guard let a = animation else { stop(); return }
        let t = min(1, (CACurrentMediaTime() - a.start) / a.duration)
        let e: CGFloat = a.easeInOut ? CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
                                     : CGFloat(1 - pow(1 - t, 3))
        var point = CGPoint(x: a.from.x + (a.to.x - a.from.x) * e, y: a.from.y + (a.to.y - a.from.y) * e)
        point.y -= a.lift * sin(.pi * e)
        setFinger(point)
        if t >= 1 {
            stop()
            a.done()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = resources.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        resources.encode(CurlResources.Frame(viewSize: bounds.size, leafRect: geometry.rect, underRect: underRect,
                                             state: state, pageWidth: geometry.width, front: front, back: back,
                                             landingTransform: geometry.landingTransform(to: landingRect, progress: state.turned)),
                         into: encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }
}
