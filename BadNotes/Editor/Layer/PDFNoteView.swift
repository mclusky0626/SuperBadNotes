//
//  PDFNoteView.swift
//  BadNotes
//
//  레이어 모드 (옵션). PDFView 위에 페이지마다 PencilKit 캔버스를 덮어서 필기.
//  Apple 기본 도구(PKToolPicker)를 그대로 쓰는 대신, 확대하면 캔버스가 늘어나서 필기가 흐려짐.
//  저장은 NoteDocument가 맡음. 여기서는 획이 바뀔 때마다 넘겨주기만 함.
//

import SwiftUI
import PDFKit
import PencilKit

struct PDFNoteView: UIViewRepresentable {
    let document: NoteDocument
    let bridge: EditorBridge
    var initialPage = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, bridge: bridge)
    }

    func makeUIView(context: Context) -> PDFView {
        let c = context.coordinator
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.pageOverlayViewProvider = c
        view.document = document.pdf
        view.isInMarkupMode = true
        c.pdfView = view
        bridge.attach(c)
        bridge.undoAction = nil
        bridge.redoAction = nil
        bridge.jumpAction = { [weak view] index in
            guard let view, let page = view.document?.page(at: index) else { return }
            view.go(to: page)
        }
        bridge.pageAddedAction = { [weak view, weak bridge] index in
            guard let view else { return }
            view.layoutDocumentView()
            bridge?.pageCount = view.document?.pageCount ?? 0
            if let page = view.document?.page(at: index) { view.go(to: page) }
        }
        c.attach()
        if initialPage > 0 {
            let start = initialPage
            DispatchQueue.main.async { [weak view] in
                if let view, let page = view.document?.page(at: start) { view.go(to: page) }
            }
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.bridge.detach(coordinator)
        let document = coordinator.document
        Task { await document.flush(reason: "편집기 닫힘") }
    }

    /// 몇 쪽 위에 덮인 캔버스인지 기억
    final class PageCanvasView: PKCanvasView {
        var pageIndex = 0
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
        let document: NoteDocument
        let bridge: EditorBridge
        let toolPicker = PKToolPicker()
        weak var pdfView: PDFView?
        var canvases: [Int: PageCanvasView] = [:]
        private var offsetObs: NSKeyValueObservation?
        private var lastY: CGFloat = 0
        private var lastToggle: CFTimeInterval = 0
        private var verifiedRotations: Set<Int> = []

        init(document: NoteDocument, bridge: EditorBridge) {
            self.document = document
            self.bridge = bridge
            super.init()
            // PDF 종이는 다크 모드에서도 흰색이라 색 고르기도 라이트 기준
            toolPicker.colorUserInterfaceStyle = .light
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            offsetObs?.invalidate()
        }

        func attach() {
            guard let view = pdfView else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                                   name: .PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(reassertToolPicker),
                                                   name: .PDFViewScaleChanged, object: view)
            pageChanged()
            // PDFView 안쪽 스크롤뷰를 찾아 스크롤 방향 감시
            DispatchQueue.main.async { [weak self] in
                guard let self, let sv = self.findScrollView(in: view) else {
                    AppLog.shared.warn("스크롤뷰를 못 찾아 도구 막대 자동 숨김이 꺼짐")
                    return
                }
                self.lastY = sv.contentOffset.y
                self.offsetObs = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                    MainActor.assumeIsolated { self?.scrolled(sv) }
                }
            }
        }

        private func scrolled(_ sv: UIScrollView) {
            let y = sv.contentOffset.y
            let minY = -sv.adjustedContentInset.top
            let maxY = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
            // 손가락으로 끌고 있을 때만 판정 (재배치·관성·튕김은 무시)
            guard sv.isTracking else { lastY = y; return }
            if y < minY || y > maxY { lastY = y; return }
            let dy = y - lastY
            if abs(dy) < 12 { return }
            lastY = y
            let now = CACurrentMediaTime()
            if now - lastToggle < 0.35 { return }
            let hide = (y <= minY + 4) ? false : dy > 0
            if hide != bridge.chromeHidden {
                bridge.chromeHidden = hide
                lastToggle = now
            }
        }

        func findScrollView(in v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView { return s }
            for sub in v.subviews { if let s = findScrollView(in: sub) { return s } }
            return nil
        }

        @objc func pageChanged() {
            guard let view = pdfView, let doc = view.document,
                  let cur = view.currentPage else { return }
            bridge.page = doc.index(for: cur)
            bridge.pageCount = doc.pageCount
            reassertToolPicker()
        }

        /// 줌/재배치로 캔버스가 바뀌면 first responder가 빠져 도구 팔레트가 사라짐.
        /// 화면에 붙어 있는 현재 페이지 캔버스에 다시 붙여 줌.
        @objc func reassertToolPicker() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.pdfView, let doc = view.document else { return }
                let cur = view.currentPage.map { doc.index(for: $0) }
                let target = cur.flatMap { self.canvases[$0] }.flatMap { $0.window != nil ? $0 : nil }
                    ?? self.canvases.values.first { $0.window != nil }
                guard let canvas = target else { return }
                if !canvas.isFirstResponder {
                    self.toolPicker.setVisible(true, forFirstResponder: canvas)
                    self.toolPicker.addObserver(canvas)
                    if !canvas.becomeFirstResponder() {
                        AppLog.shared.warn("필기 도구 다시 붙이기 실패")
                    }
                }
            }
        }

        // MARK: 페이지 캔버스

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let doc = view.document else { return nil }
            let index = doc.index(for: page)
            if let existing = canvases[index] { return existing }

            let canvas = PageCanvasView()
            canvas.pageIndex = index
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.drawingPolicy = AppSettings.shared.fingerDrawing ? .anyInput : .pencilOnly
            // PDF 종이는 다크 모드에서도 흰색 → 잉크 색을 뒤집으면 검은 글씨가 안 보임
            canvas.overrideUserInterfaceStyle = .light
            canvas.drawing = document.drawing(for: index)
            // 처음 그림을 넣은 다음에 연결해야 '바뀜'으로 안 잡힘
            canvas.delegate = self
            toolPicker.setVisible(true, forFirstResponder: canvas)
            toolPicker.addObserver(canvas)
            canvases[index] = canvas
            reassertToolPicker()
            DispatchQueue.main.async { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                self.verifyGeometry(canvas, page: page)
            }
            return canvas
        }

        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlay: UIView, for page: PDFPage) {
            guard let canvas = overlay as? PageCanvasView else { return }
            canvas.delegate = nil
            toolPicker.removeObserver(canvas)
            if canvases[canvas.pageIndex] === canvas {
                canvases[canvas.pageIndex] = nil
            }
            reassertToolPicker()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let canvas = canvasView as? PageCanvasView else { return }
            document.update(canvas.drawing, page: canvas.pageIndex)
        }

        /// 캔버스 좌표 → PDF 좌표 계산이 PDFKit의 실제 배치와 맞는지 회전 종류마다 한 번 확인
        private func verifyGeometry(_ canvas: PageCanvasView, page: PDFPage) {
            guard let view = pdfView, canvas.window != nil, canvas.bounds.width > 10 else { return }
            let geometry = PageGeometry(page: page)
            guard !verifiedRotations.contains(geometry.rotation) else { return }
            verifiedRotations.insert(geometry.rotation)

            let size = canvas.bounds.size
            if abs(size.width - geometry.canvasSize.width) > 1 || abs(size.height - geometry.canvasSize.height) > 1 {
                Log.warn("캔버스 크기 \(size) ≠ 페이지 \(geometry.canvasSize) (회전 \(geometry.rotation)°)")
            }
            for point in [CGPoint(x: size.width * 0.2, y: size.height * 0.25),
                          CGPoint(x: size.width * 0.7, y: size.height * 0.8)] {
                let expected = point.applying(geometry.canvasToPage)
                let actual = view.convert(canvas.convert(point, to: view), to: page)
                if hypot(expected.x - actual.x, expected.y - actual.y) > 2 {
                    Log.error("좌표 변환 불일치 (회전 \(geometry.rotation)°): 계산 \(expected), 실제 \(actual)")
                    return
                }
            }
            Log.info("좌표 변환 확인됨 (회전 \(geometry.rotation)°)")
        }
    }
}
