//
//  TiledPageView.swift
//  BadNotes
//
//  페이지 한 장 = PDF 타일 + 필기 타일.
//  CATiledLayer는 확대 배율에 맞는 해상도로 화면에 보이는 조각만 다시 그려서, 아무리 확대해도 선명함.
//  필기가 바뀌면 필기 타일 중 바뀐 영역만 다시 그림 (PDF는 안 건드림).
//

import UIKit
import PDFKit
import PencilKit

/// 타일 하나를 그리는 쪽 (백그라운드 스레드에서 불림)
nonisolated protocol TileRenderer: AnyObject, Sendable {
    func drawTile(in context: CGContext)
}

/// 페이드 없이 바로 바뀌는 타일 레이어
nonisolated final class FastTiledLayer: CATiledLayer {
    nonisolated(unsafe) var tileRenderer: (any TileRenderer)?

    override class func fadeDuration() -> CFTimeInterval { 0 }

    override func draw(in ctx: CGContext) {
        tileRenderer?.drawTile(in: ctx)
    }
}

final class TiledView: UIView {
    override class var layerClass: AnyClass { FastTiledLayer.self }

    init(frame: CGRect, renderer: any TileRenderer) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        if let tiled = layer as? FastTiledLayer {
            tiled.tileRenderer = renderer
            tiled.tileSize = CGSize(width: 512, height: 512)
            // 1/4배 ~ 32배까지 그 배율에 맞는 해상도로
            tiled.levelsOfDetail = 8
            tiled.levelsOfDetailBias = 5
        }
        layer.setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidate(_ rect: CGRect) {
        layer.setNeedsDisplay(rect)
    }
}

/// PDF 페이지 내용 (다른 앱이 넣은 주석도 같이)
nonisolated final class PDFPageTileRenderer: TileRenderer, @unchecked Sendable {
    private let page: PDFPage
    private let size: CGSize
    /// 같은 페이지를 여러 타일 스레드가 동시에 그리지 않게
    private let lock = NSLock()
    /// 문서 전체: 그리는 동안 페이지가 들어오지 않게
    private let documentLock: ReadWriteLock

    init(page: PDFPage, size: CGSize, documentLock: ReadWriteLock) {
        self.page = page
        self.size = size
        self.documentLock = documentLock
    }

    func drawTile(in context: CGContext) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(context.boundingBoxOfClipPath)
        documentLock.read {
            lock.withLock {
                context.saveGState()
                // 레이어는 위쪽이 원점, PDF는 아래쪽이 원점. 회전·crop은 draw(with:to:)가 적용함
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
            }
        }
    }
}

/// 화이트보드 바탕: 점 무늬를 보이는 조각에만 그림 (멀리서 보면 점 간격을 넓힘)
nonisolated final class BoardTileRenderer: TileRenderer, @unchecked Sendable {
    func drawTile(in context: CGContext) {
        let clip = context.boundingBoxOfClipPath
        context.setFillColor(UIColor(red: 0.985, green: 0.983, blue: 0.975, alpha: 1).cgColor)
        context.fill(clip)
        let scale = max(0.01, abs(context.ctm.a))
        var spacing: CGFloat = 32
        while spacing * scale < 14 { spacing *= 4 }
        let radius = max(1.1, 1.3 / scale)
        context.setFillColor(UIColor(white: 0.72, alpha: 1).cgColor)
        var y = (clip.minY / spacing).rounded(.down) * spacing
        while y <= clip.maxY + spacing {
            var x = (clip.minX / spacing).rounded(.down) * spacing
            while x <= clip.maxX + spacing {
                context.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
        context.fillPath()
    }
}

/// 페이지 필기
nonisolated final class InkTileRenderer: TileRenderer, @unchecked Sendable {
    private let ink: PageInk

    init(ink: PageInk) {
        self.ink = ink
    }

    func drawTile(in context: CGContext) {
        draw(in: context, record: true)
    }

    /// record: 타일에 그렸다고 적어 둘지 (화면 밖에서 한 장 그릴 때는 안 적음)
    /// glass: 유리펜 획도 흉내로 그림 (화면에서는 진짜 유리 층이 따로 그려서 타일에는 안 그림)
    func draw(in context: CGContext, record: Bool, glass: Bool = false) {
        let clip = context.boundingBoxOfClipPath
        let snapshot = ink.renderSnapshot()
        let scale = max(0.05, abs(context.ctm.a))
        var drawnPending: [StrokeKey] = []
        // Apple 도구로 그은 획은 이어진 것끼리 모아서 Apple 렌더러로 한 번에 (순서는 지킴)
        var appleRun: [PKStroke] = []
        func flushApple() {
            guard !appleRun.isEmpty else { return }
            let drawing = PKDrawing(strokes: appleRun)
            appleRun = []
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: clip, scale: scale)
            }
            guard let image else { return }
            UIGraphicsPushContext(context)
            image.draw(in: clip)
            UIGraphicsPopContext()
        }
        for stroke in snapshot.strokes where stroke.bounds.intersects(clip) {
            if let source = stroke.appleSource {
                appleRun.append(source)
            } else {
                flushApple()
                // 유리펜 획은 진짜 Liquid Glass 층이 그림 (타일에는 안 그림)
                if glass || stroke.glassStrength == nil { InkRenderer.draw(stroke, in: context, smooth: true) }
            }
            if snapshot.pending.contains(stroke.key) { drawnPending.append(stroke.key) }
        }
        flushApple()
        if record, !drawnPending.isEmpty {
            ink.recordDrawn(clip, keys: drawnPending)
        }
    }
}

/// 페이지 한 장. 좌표계 = 페이지 캔버스 좌표 (필기 데이터 좌표와 같음)
/// 쌓는 순서: PDF 타일 → 요소(텍스트 상자·메모지·사진) → 필기 타일 → 선택 테두리
final class PageView: UIView {
    let index: Int
    let ink: PageInk
    private let pdfTiles: TiledView
    private let inkTiles: TiledView
    private let backgroundRenderer: any TileRenderer
    private let inkRenderer: InkTileRenderer
    private let elementLayer = UIView()
    private(set) var elementViews: [UUID: ElementView] = [:]
    let selectionFrame = SelectionFrameView()
    private var glassView: GlassShapeHost?
    private var glassMarks: [StrokeKey: GlassMark] = [:]
    private var glassKeys: [StrokeKey] = []
    private var transientGlass: [GlassMark] = []
    private let showsInk: Bool

    /// showsInk: Apple 도구 모드에서는 필기를 PencilKit이 직접 그려서 끔
    init(index: Int, page: PDFPage, size: CGSize, ink: PageInk, documentLock: ReadWriteLock, showsInk: Bool = true,
         board: Bool = false) {
        self.index = index
        self.ink = ink
        self.showsInk = showsInk
        let rect = CGRect(origin: .zero, size: size)
        let background: any TileRenderer = board ? BoardTileRenderer()
            : PDFPageTileRenderer(page: page, size: size, documentLock: documentLock)
        let inkRenderer = InkTileRenderer(ink: ink)
        backgroundRenderer = background
        self.inkRenderer = inkRenderer
        pdfTiles = TiledView(frame: rect, renderer: background)
        inkTiles = TiledView(frame: rect, renderer: inkRenderer)
        super.init(frame: rect)
        backgroundColor = .white
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowPath = UIBezierPath(rect: rect).cgPath
        if board { layer.shadowOpacity = 0 }
        addSubview(pdfTiles)
        elementLayer.frame = rect
        elementLayer.isUserInteractionEnabled = true
        // 자르기(clipsToBounds)를 켜면 따로 그려져서 유리가 뒤의 종이를 못 봄
        addSubview(elementLayer)
        if showsInk {
            addSubview(inkTiles)
            updateGlassInk()
        }
        addSubview(selectionFrame)
    }

    // MARK: 사진

    /// 페이지 한 장을 사진으로 (넘기는 종이용). 항상 직접 그림:
    /// 화면 찍기(drawHierarchy)와 layer.render는 Liquid Glass(유리 메모지·유리 글자·유리펜)를 검게 찍어서,
    /// 유리는 PDF 내보내기와 같은 흉내 그림으로 대신함
    /// - pointScale: 페이지 1pt당 픽셀 수
    func image(pointScale: CGFloat) -> CGImage? {
        let longest = max(bounds.width, bounds.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(pointScale, 4096 / max(longest, 1))
        format.opaque = false
        format.preferredRange = .standard
        let elements = elementLayer.subviews.compactMap { $0 as? ElementView }
        let drawn = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(bounds)
            backgroundRenderer.drawTile(in: cg)
            for view in elements {
                let e = view.element
                cg.saveGState()
                ElementRenderer.drawBackground(e, in: cg, rect: e.frame, live: false)
                ElementRenderer.drawContent(e, image: view.picture, in: cg, rect: e.frame, forPDF: true)
                cg.restoreGState()
            }
            if showsInk { inkRenderer.draw(in: cg, record: false, glass: true) }
        }.cgImage
        if let drawn, Self.looksBlank(drawn) {
            // 어두운 종이면 정상. 아니면 다음에 원인을 찾을 수 있게 남김
            Log.warn("페이지 \(index + 1) 넘기기 사진이 어둡게 그려짐 (\(drawn.width)×\(drawn.height))")
        }
        return drawn
    }

    /// 거의 다 까맣거나 투명한 사진인지 (16×16으로 줄여서 봄). 종이는 대부분 밝음
    nonisolated static func looksBlank(_ image: CGImage) -> Bool {
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return true }
        var bright = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let luma = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
            if pixels[i + 3] > 200, luma > 60 { bright += 1 }
        }
        return bright < n * n / 4
    }

    // MARK: 요소

    /// 문서의 요소 목록에 맞춰 뷰를 더하고·빼고·고침 (순서 = 목록 순서, 뒤가 위)
    func setElements(_ elements: [PageElement], image: @escaping (String) -> CGImage?, animated: Bool = false) {
        let ids = Set(elements.map(\.id))
        for (id, view) in elementViews where !ids.contains(id) {
            elementViews[id] = nil
            if animated {
                // 지울 때: 살짝 작아지며 사라짐
                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn]) {
                    view.alpha = 0
                    view.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                } completion: { _ in view.removeFromSuperview() }
            } else {
                view.removeFromSuperview()
            }
        }
        for element in elements {
            let picture = element.imageID.flatMap(image)
            if let view = elementViews[element.id] {
                if view.textView == nil { view.apply(element, image: picture) }
                elementLayer.bringSubviewToFront(view)
            } else {
                let view = ElementView(element: element, image: picture)
                elementLayer.addSubview(view)
                elementViews[element.id] = view
                if animated {
                    // 넣을 때: 톡 튀어나옴
                    view.alpha = 0
                    view.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                    UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.4) {
                        view.alpha = 1
                        view.transform = .identity
                    }
                }
            }
        }
    }

    func elementView(_ id: UUID) -> ElementView? { elementViews[id] }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateGlassInk() {
        let strokes = ink.renderSnapshot().strokes.filter { $0.glassStrength != nil }
        let keys = strokes.map(\.key)
        guard keys != glassKeys else { return }
        var next: [StrokeKey: GlassMark] = [:]
        for stroke in strokes {
            next[stroke.key] = glassMarks[stroke.key] ?? GlassMark(stroke: stroke)
        }
        glassMarks = next
        glassKeys = keys
        displayGlass()
    }

    func setTransientGlass(_ marks: [GlassMark]) {
        guard !marks.isEmpty || !transientGlass.isEmpty else { return }
        transientGlass = marks
        displayGlass()
    }

    private func displayGlass() {
        let marks = glassKeys.compactMap { glassMarks[$0] } + transientGlass
        if marks.isEmpty {
            glassView?.removeFromSuperview()
            glassView = nil
        } else if let glassView {
            glassView.update(marks)
        } else {
            let view = GlassShapeHost(marks: marks)
            if selectionFrame.superview != nil { insertSubview(view, belowSubview: selectionFrame) }
            else { addSubview(view) }
            glassView = view
        }
    }

    func invalidateInk(_ rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        updateGlassInk()
        inkTiles.invalidate(rect.insetBy(dx: -2, dy: -2))
    }
}
