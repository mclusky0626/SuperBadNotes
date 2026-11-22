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

/// 페이지 필기
nonisolated final class InkTileRenderer: TileRenderer, @unchecked Sendable {
    private let ink: PageInk

    init(ink: PageInk) {
        self.ink = ink
    }

    func drawTile(in context: CGContext) {
        let clip = context.boundingBoxOfClipPath
        let snapshot = ink.renderSnapshot()
        var drawnPending: [StrokeKey] = []
        for stroke in snapshot.strokes where stroke.bounds.intersects(clip) {
            InkRenderer.draw(stroke, in: context, smooth: true)
            if snapshot.pending.contains(stroke.key) { drawnPending.append(stroke.key) }
        }
        if !drawnPending.isEmpty {
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
    private let elementLayer = UIView()
    private(set) var elementViews: [UUID: ElementView] = [:]
    let selectionFrame = SelectionFrameView()

    /// showsInk: Apple 도구 모드에서는 필기를 PencilKit이 직접 그려서 끔
    init(index: Int, page: PDFPage, size: CGSize, ink: PageInk, documentLock: ReadWriteLock, showsInk: Bool = true) {
        self.index = index
        self.ink = ink
        let rect = CGRect(origin: .zero, size: size)
        pdfTiles = TiledView(frame: rect, renderer: PDFPageTileRenderer(page: page, size: size, documentLock: documentLock))
        inkTiles = TiledView(frame: rect, renderer: InkTileRenderer(ink: ink))
        super.init(frame: rect)
        backgroundColor = .white
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowPath = UIBezierPath(rect: rect).cgPath
        addSubview(pdfTiles)
        elementLayer.frame = rect
        elementLayer.isUserInteractionEnabled = true
        // 자르기(clipsToBounds)를 켜면 따로 그려져서 유리가 뒤의 종이를 못 봄
        addSubview(elementLayer)
        if showsInk { addSubview(inkTiles) }
        addSubview(selectionFrame)
    }

    // MARK: 요소

    /// 문서의 요소 목록에 맞춰 뷰를 더하고·빼고·고침 (순서 = 목록 순서, 뒤가 위)
    func setElements(_ elements: [PageElement], image: (String) -> CGImage?) {
        let ids = Set(elements.map(\.id))
        for (id, view) in elementViews where !ids.contains(id) {
            view.removeFromSuperview()
            elementViews[id] = nil
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
            }
        }
    }

    func elementView(_ id: UUID) -> ElementView? { elementViews[id] }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidateInk(_ rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        inkTiles.invalidate(rect.insetBy(dx: -2, dy: -2))
    }
}
