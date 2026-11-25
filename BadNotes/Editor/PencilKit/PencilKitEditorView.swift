//
//  PencilKitEditorView.swift
//  BadNotes
//
//  Apple 필기 도구 모드 (설정에서 켬).
//  - 스크롤뷰 자체가 PKCanvasView → Apple이 확대 배율에 맞춰 필기를 다시 그려서 선명함
//  - 페이지(PDF 타일 + 텍스트 상자·메모지·사진)는 캔버스 맨 아래에 깔고 같은 배율로 같이 확대
//    (예전 레이어 모드는 페이지 위 캔버스가 늘어나기만 해서 흐렸음)
//  - 필기는 페이지들을 세로로 쌓은 좌표에 한 장으로 합쳐서 캔버스에 넣고,
//    바뀔 때마다 획 위치로 페이지를 나눠서 NoteDocument에 넘김 → 저장 방식은 BadNotes 도구와 똑같음
//

import UIKit
import SwiftUI
import PDFKit
import PencilKit

final class PencilKitEditorView: UIView, PKCanvasViewDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate,
                                 UIEditMenuInteractionDelegate, ElementHost {
    let document: NoteDocument
    private let bridge: EditorBridge
    private let canvas = PKCanvasView()
    private let toolPicker = PKToolPicker()
    /// 캔버스 맨 아래에 까는 페이지들 (원래 크기로 배치하고 확대 배율만큼 키움)
    private let pagesView = UIView()
    private var pageViews: [PageView] = []
    private var placements: [PagePlacement] = []
    private var natural: CGSize = .zero
    private var laidOutSize: CGSize = .zero
    private var didInitialScroll = false
    private var applyingDrawing = false
    /// 페이지마다 마지막으로 넘긴 필기의 지문 (바뀐 페이지만 저장)
    private var signatures: [Int: [Int]] = [:]
    private var lastScrollY: CGFloat = 0
    private var lastChromeToggle: CFTimeInterval = 0
    private var keyboardOverlap: CGFloat = 0
    private var editMenu: UIEditMenuInteraction?
    private var menuTarget: CGRect?

    private let elements = ElementController()
    private let elementTap = UITapGestureRecognizer()
    private let elementPan = UIPanGestureRecognizer()
    private let fallbackUndo = UndoManager()
    private var pendingImage: (page: Int, point: CGPoint)?

    var initialPage = 0
    var chromeInsets: UIEdgeInsets = .zero {
        didSet {
            guard chromeInsets != oldValue else { return }
            let atTop = abs(canvas.contentOffset.y + canvas.contentInset.top) < 1
            updateInsets()
            if atTop { canvas.contentOffset.y = -canvas.contentInset.top }
        }
    }

    init(document: NoteDocument, bridge: EditorBridge) {
        self.document = document
        self.bridge = bridge
        super.init(frame: .zero)
        backgroundColor = .clear

        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsHorizontalScrollIndicator = false
        canvas.bouncesZoom = true
        // 종이는 다크 모드에서도 흰색 → 잉크 색을 뒤집지 않게
        canvas.overrideUserInterfaceStyle = .light
        addSubview(canvas)

        pagesView.layer.anchorPoint = .zero
        canvas.insertSubview(pagesView, at: 0)

        elements.host = self
        elements.tools = InkToolState.shared
        let pdf = document.pdf
        for index in 0..<pdf.pageCount {
            let page = pdf.page(at: index) ?? PDFPage()
            let view = PageView(index: index, page: page, size: PageGeometry(page: page).canvasSize,
                                ink: PageInk(drawing: PKDrawing()), documentLock: document.renderLock, showsInk: false,
                                board: document.isBoard)
            pageViews.append(view)
            pagesView.addSubview(view)
            elements.refresh(view)
        }

        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)

        // 요소: 손가락 탭으로 고르기, 고른 요소는 손가락으로 끌기 (펜슬은 Apple 도구가 받음)
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        elementTap.allowedTouchTypes = fingers
        elementTap.delegate = self
        elementTap.addTarget(self, action: #selector(handleElementTap(_:)))
        canvas.addGestureRecognizer(elementTap)
        elementPan.allowedTouchTypes = fingers
        elementPan.maximumNumberOfTouches = 1
        elementPan.delegate = self
        elementPan.addTarget(self, action: #selector(handleElementPan(_:)))
        canvas.addGestureRecognizer(elementPan)
        canvas.panGestureRecognizer.require(toFail: elementPan)

        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoChanged),
                                               name: .NSUndoManagerDidCloseUndoGroup, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoChanged),
                                               name: .NSUndoManagerDidUndoChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoChanged),
                                               name: .NSUndoManagerDidRedoChange, object: nil)

        bridge.attach(self)
        bridge.pageCount = pageViews.count
        bridge.page = 0
        bridge.undoAction = { [weak self] in self?.performUndo() }
        bridge.redoAction = { [weak self] in self?.performRedo() }
        bridge.jumpAction = { [weak self] page in self?.scroll(toPage: page, animated: true) }
        bridge.pageAddedAction = { [weak self] page in self?.pageAdded(page) }
        bridge.insertAction = { [weak self] what in self?.insert(what) }
        bridge.restyleAction = { [weak self] in self?.elements.restyleFromTools() }
        bridge.zoomAction = { [weak self] percent in
            guard let self else { return }
            let target = min(max(self.fitScale * CGFloat((percent ?? 100) / 100), self.canvas.minimumZoomScale),
                             self.canvas.maximumZoomScale)
            self.canvas.setZoomScale(target, animated: true)
        }
        setFingerDrawing(AppSettings.shared.fingerDrawing)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFingerDrawing(_ on: Bool) {
        canvas.drawingPolicy = on ? .anyInput : .pencilOnly
    }

    private var twoUp = AppSettings.shared.twoUpLandscape
    private var fitScale: CGFloat = 1
    private var zoomLocked = false

    func setZoomLocked(_ locked: Bool) {
        guard locked != zoomLocked else { return }
        zoomLocked = locked
        canvas.pinchGestureRecognizer?.isEnabled = !locked
        bridge.zoomLocked = locked
    }

    private func reportZoom() {
        let percent = Int((canvas.zoomScale / max(fitScale, 0.0001) * 100).rounded())
        if bridge.zoomPercent != percent { bridge.zoomPercent = percent }
    }

    /// 가로 두 쪽 설정이 바뀌면 다시 배치 (페이지 자리가 바뀌면 필기도 다시 합침)
    func setTwoUp(_ on: Bool) {
        guard on != twoUp else { return }
        twoUp = on
        guard laidOutSize.width > 0 else { return }
        let keep = bridge.page
        layoutPages(resetZoom: true)
        scroll(toPage: keep, animated: false)
    }

    func prepareForRemoval() {
        elements.endEditing()
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        toolPicker.removeObserver(self)
        bridge.detach(self)
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        showToolPicker()
    }

    private func showToolPicker() {
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    // MARK: 배치

    private func updateBoardMap() {
        guard document.isBoard, let board = pageViews.first, bridge.owner == ObjectIdentifier(self) else { return }
        bridge.boardMap.update(canvas, board: board, insets: chromeInsets)
    }

    override func layoutSubviews() {
        defer { updateBoardMap() }
        super.layoutSubviews()
        canvas.frame = bounds
        guard bounds.width > 0, bounds.height > 0, bounds.size != laidOutSize else { return }
        let keep = bridge.page
        laidOutSize = bounds.size
        layoutPages(resetZoom: true)
        if didInitialScroll {
            scroll(toPage: keep, animated: false)
        } else {
            didInitialScroll = true
            loadDrawing()
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
            if document.isBoard, let board = pageViews.first {
                let target = document.contentBounds(page: 0)
                    ?? CGRect(x: board.bounds.midX - 400, y: board.bounds.midY - 300, width: 800, height: 600)
                let zoom = canvas.zoomScale, origin = placements.first?.frame.origin ?? .zero
                canvas.contentOffset = CGPoint(x: (origin.x + target.midX) * zoom - canvas.bounds.width / 2,
                                               y: (origin.y + target.midY) * zoom - canvas.bounds.height / 2)
            } else if initialPage > 0 {
                scroll(toPage: initialPage, animated: false)
            }
        }
    }

    /// 페이지를 원래 크기(pt)로 세로로 쌓음. 페이지 자리가 바뀌면 필기도 다시 합쳐서 넣음
    private func layoutPages(resetZoom: Bool) {
        let spread = !document.isBoard && twoUp && bounds.width > bounds.height
        let rows = PageRows.make(count: pageViews.count, twoUp: spread, coverAlone: document.hasCover)
        let arrangement = PageArrangement(sizes: pageViews.map(\.bounds.size), rows: rows, twoUp: spread,
                                          coverAlone: document.hasCover)
        let moved = !placements.isEmpty && !arrangement.placements.starts(with: placements)
        placements = arrangement.placements
        for placement in placements { placement.apply(to: pageViews[placement.index]) }
        natural = arrangement.size
        pagesView.bounds = CGRect(origin: .zero, size: natural)

        if document.isBoard {
            // 화이트보드: 1배에서 시작, 멀리 0.12배 ~ 가까이 6배
            canvas.minimumZoomScale = 0.12
            canvas.maximumZoomScale = 6
            if resetZoom && !didInitialScroll { canvas.zoomScale = 1 }
        } else {
            let ratio = zoomLocked && didInitialScroll ? canvas.zoomScale / fitScale : 1
            let fit = bounds.width / natural.width
            fitScale = fit
            canvas.minimumZoomScale = fit * 0.5
            canvas.maximumZoomScale = fit * 8
            if resetZoom { canvas.zoomScale = fit * ratio }
        }
        syncUnderlay()
        if moved { loadDrawing() }
    }

    /// 페이지 층을 캔버스 확대 배율에 맞춤
    private func syncUnderlay() {
        let zoom = canvas.zoomScale
        pagesView.layer.position = .zero
        pagesView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        let size = CGSize(width: natural.width * zoom, height: natural.height * zoom)
        if abs(canvas.contentSize.width - size.width) > 0.5 || abs(canvas.contentSize.height - size.height) > 0.5 {
            canvas.contentSize = size
        }
        updateInsets()
    }

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        updateInsets()
    }

    private func updateInsets() {
        let side = max(0, (canvas.bounds.width - canvas.contentSize.width) / 2)
        let palette = toolPicker.isVisible ? toolPicker.frameObscured(in: self).intersection(bounds) : .null
        let docked = !palette.isNull && palette.maxY >= bounds.maxY - 1
        let bottom = max(chromeInsets.bottom, docked ? palette.height : 0, keyboardOverlap > 0 ? keyboardOverlap + 16 : 0)
        canvas.contentInset = UIEdgeInsets(top: chromeInsets.top, left: side, bottom: bottom, right: side)
        canvas.verticalScrollIndicatorInsets = UIEdgeInsets(top: chromeInsets.top, left: 0, bottom: bottom, right: 0)
    }

    func scroll(toPage index: Int, animated: Bool) {
        guard placements.indices.contains(index) else { return }
        let zoom = canvas.zoomScale
        let top = -canvas.contentInset.top
        let bottom = max(top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
        let y = min(max(placements[index].frame.minY * zoom - canvas.contentInset.top, top), bottom)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: animated)
    }

    func pageAdded(_ index: Int) {
        guard index == pageViews.count, let page = document.pdf.page(at: index) else { return }
        let view = PageView(index: index, page: page, size: PageGeometry(page: page).canvasSize,
                            ink: PageInk(drawing: PKDrawing()), documentLock: document.renderLock, showsInk: false,
                                board: document.isBoard)
        pageViews.append(view)
        pagesView.addSubview(view)
        elements.refresh(view)
        bridge.pageCount = pageViews.count
        let offset = canvas.contentOffset
        layoutPages(resetZoom: false)
        canvas.contentOffset = offset
        scroll(toPage: index, animated: true)
    }

    // MARK: 필기 합치기 / 나누기

    /// 페이지별 필기를 쌓은 좌표 한 장으로 합쳐서 캔버스에 넣음
    private func loadDrawing() {
        var merged = PKDrawing()
        signatures = [:]
        for placement in placements {
            let index = placement.index
            let drawing = document.drawing(for: index)
            signatures[index] = Self.signature(drawing.strokes)
            guard !drawing.strokes.isEmpty else { continue }
            merged.append(drawing.transformed(using: placement.transform))
        }
        applyingDrawing = true
        canvas.drawing = merged
        applyingDrawing = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applyingDrawing, !placements.isEmpty else { return }
        var perPage: [Int: [PKStroke]] = [:]
        for stroke in canvasView.drawing.strokes {
            let index = page(for: stroke)
            var local = stroke
            local.transform = stroke.transform.concatenating(placements[index].transform.inverted())
            perPage[index, default: []].append(local)
        }
        for index in placements.indices {
            let strokes = perPage[index] ?? []
            let signature = Self.signature(strokes)
            guard signature != (signatures[index] ?? []) else { continue }
            signatures[index] = signature
            document.update(PKDrawing(strokes: strokes), page: index)
        }
        undoChanged()
    }

    /// 획 가운데가 들어 있는 페이지 (페이지 사이 틈이면 가까운 페이지)
    private func page(for stroke: PKStroke) -> Int {
        let bounds = stroke.renderBounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for placement in placements {
            let index = placement.index
            let frame = placement.frame
            if frame.contains(center) { return index }
            let dy = center.y < frame.minY ? frame.minY - center.y : max(0, center.y - frame.maxY)
            let dx = max(frame.minX - center.x, center.x - frame.maxX, 0)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// 획 목록의 지문. 페이지 좌표로 옮겼다 되돌리면 소수점 끝자리가 달라질 수 있어서 반올림해서 비교
    private static func signature(_ strokes: [PKStroke]) -> [Int] {
        strokes.map { stroke in
            var hasher = Hasher()
            hasher.combine(stroke.path.creationDate.timeIntervalSinceReferenceDate)
            hasher.combine(stroke.randomSeed)
            hasher.combine(stroke.path.count)
            let t = stroke.transform
            for value in [t.a, t.b, t.c, t.d, t.tx, t.ty] { hasher.combine((value * 100).rounded()) }
            hasher.combine(stroke.ink.inkType.rawValue)
            for value in stroke.ink.color.cgColor.components ?? [] { hasher.combine((value * 1000).rounded()) }
            if let mask = stroke.mask {
                let b = mask.bounds
                for value in [b.minX, b.minY, b.width, b.height] { hasher.combine((value * 10).rounded()) }
                var elements = 0
                mask.cgPath.applyWithBlock { _ in elements += 1 }
                hasher.combine(elements)
            }
            return hasher.finalize()
        }
    }

    // MARK: 스크롤

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        defer { updateBoardMap() }
        reportZoom()
        syncUnderlay()
        elements.updateSelectionFrame()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        syncUnderlay()
        elements.zoomEnded()
        if elements.selected != nil { elements.presentMenu() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        defer { updateBoardMap() }
        updateCurrentPage()
        if elements.selected != nil { editMenu?.dismissMenu() }
        updateChromeVisibility()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if elements.selected != nil { elements.presentMenu() }
    }

    private func updateCurrentPage() {
        let centerY = (canvas.contentOffset.y + canvas.bounds.height / 2) / max(canvas.zoomScale, 0.001)
        var current = 0
        for placement in placements {
            if placement.frame.minY <= centerY { current = placement.index } else { break }
        }
        if bridge.page != current { bridge.page = current }
        if bridge.isBook { bridge.isBook = false }
        if !placements.isEmpty {
            let maxY = natural.height * canvas.zoomScale
            let atEnd = maxY <= canvas.contentOffset.y + canvas.bounds.height + 40
            if bridge.atLastPage != atEnd { bridge.atLastPage = atEnd }
        }
    }

    private func updateChromeVisibility() {
        let y = canvas.contentOffset.y
        let top = -canvas.contentInset.top
        let bottom = max(top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
        guard canvas.isTracking, !canvas.isZooming, y >= top, y <= bottom else {
            lastScrollY = y
            return
        }
        let dy = y - lastScrollY
        guard abs(dy) > 14 else { return }
        lastScrollY = y
        let now = CACurrentMediaTime()
        guard now - lastChromeToggle > 0.35 else { return }
        let hide = y > top + 20 && dy > 0
        if hide != bridge.chromeHidden {
            bridge.chromeHidden = hide
            lastChromeToggle = now
        }
    }

    // MARK: 실행 취소 (Apple 도구와 같은 실행 취소 기록을 씀)

    private var history: UndoManager { canvas.undoManager ?? fallbackUndo }

    private func performUndo() {
        elements.endEditing()
        if history.canUndo { history.undo() }
        undoChanged()
    }

    private func performRedo() {
        elements.endEditing()
        if history.canRedo { history.redo() }
        undoChanged()
    }

    @objc private func undoChanged() {
        let canUndo = history.canUndo, canRedo = history.canRedo
        if bridge.canUndo != canUndo { bridge.canUndo = canUndo }
        if bridge.canRedo != canRedo { bridge.canRedo = canRedo }
    }

    // MARK: 요소

    private func pageHit(_ point: CGPoint) -> (PageView, CGPoint)? {
        let inPages = canvas.convert(point, to: pagesView)
        let hit = pageViews.first { $0.frame.contains(inPages) }
            ?? pageViews.first { $0.frame.insetBy(dx: -24, dy: -12).contains(inPages) }
        return hit.map { ($0, pagesView.convert(inPages, to: $0)) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let (pageView, point) = pageHit(touch.location(in: canvas)) else { return gestureRecognizer === elementTap }
        if gestureRecognizer === elementPan { return elements.grabs(point, page: pageView.index) }
        if AppSettings.shared.fingerDrawing { return elements.hit(point, page: pageView.index) != nil }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === elementTap
    }

    @objc private func handleElementTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let (pageView, point) = pageHit(gesture.location(in: canvas)) else {
            elements.clearSelection()
            return
        }
        if elements.isEditing {
            if elements.isInsideEditing(point, page: pageView.index) { return }
            // 글 입력 중에 다른 데를 누르면 입력만 끝냄
            elements.endEditing()
            showToolPicker()
            return
        }
        if let hit = elements.hit(point, page: pageView.index) {
            if elements.selected?.id == hit.id, hit.hasText {
                elements.beginEditing()
            } else {
                elements.select(hit.id, page: pageView.index)
            }
            return
        }
        switch InkToolState.shared.tool {
        case .text:
            elements.clearSelection()
            elements.insertText(at: point, page: pageView.index, pageSize: pageView.bounds.size, fill: InkToolState.shared.textFill)
        case .sticky:
            elements.clearSelection()
            elements.insertSticky(center: point, page: pageView.index, pageSize: pageView.bounds.size)
        case .image:
            elements.clearSelection()
            pendingImage = (pageView.index, point)
            bridge.imageRequest += 1
        default:
            if elements.selected != nil { elements.clearSelection() }
        }
    }

    @objc private func handleElementPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let moved = gesture.translation(in: canvas)
            let now = gesture.location(in: canvas)
            guard let (pageView, point) = pageHit(CGPoint(x: now.x - moved.x, y: now.y - moved.y)),
                  elements.beginDrag(at: point, page: pageView.index) else {
                gesture.isEnabled = false
                gesture.isEnabled = true
                return
            }
        case .changed:
            guard let page = elements.dragPage, pageViews.indices.contains(page) else { return }
            elements.moveDrag(to: gesture.location(in: pageViews[page]))
        case .ended:
            elements.endDrag(cancelled: false)
        case .cancelled, .failed:
            elements.endDrag(cancelled: true)
        default:
            break
        }
    }

    private func insert(_ what: EditorBridge.Insert) {
        elements.clearSelection()
        var index = min(max(bridge.page, 0), pageViews.count - 1)
        guard pageViews.indices.contains(index) else { return }
        var pageView = pageViews[index]
        let visible = canvas.bounds.inset(by: canvas.adjustedContentInset)
        let area = canvas.convert(visible, to: pageView).intersection(pageView.bounds)
        var center = area.isNull ? CGPoint(x: pageView.bounds.midX, y: pageView.bounds.midY) : CGPoint(x: area.midX, y: area.midY)
        if case .image = what, let pending = pendingImage, pageViews.indices.contains(pending.page) {
            index = pending.page
            pageView = pageViews[index]
            center = pending.point
        }
        pendingImage = nil
        let size = pageView.bounds.size
        switch what {
        case .text(let fill):
            let width = min(340, size.width * 0.6)
            elements.insertText(at: CGPoint(x: center.x - width / 2, y: center.y), page: index, pageSize: size, fill: fill)
        case .sticky:
            elements.insertSticky(center: center, page: index, pageSize: size)
        case .image(let data):
            Task { [weak self] in
                let prepared = await Task.detached(priority: .userInitiated) { ElementImages.prepare(data) }.value
                guard let self else { return }
                guard let prepared else {
                    Log.error("사진을 읽지 못함")
                    return
                }
                self.document.addImage(id: prepared.id, data: prepared.data)
                self.elements.insertImage(id: prepared.id, size: prepared.size, center: center, page: index, pageSize: size)
            }
        }
    }

    @objc private func keyboardChanged(_ note: Notification) {
        var overlap: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification,
           let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue, window != nil {
            overlap = max(0, bounds.maxY - convert(frame, from: nil).minY)
        }
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        updateInsets()
        if overlap == 0, !elements.isEditing { showToolPicker() }
        if let selected = elements.selected, elements.isEditing, let element = elements.selectedElement,
           pageViews.indices.contains(selected.page) {
            elementReveal(element.frame, in: pageViews[selected.page])
        }
    }

    // MARK: 메뉴

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        elements.menu()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuTarget ?? CGRect(origin: configuration.sourcePoint, size: .zero)
    }

    // MARK: ElementHost

    var elementDocument: NoteDocument { document }
    var elementUndo: UndoManager { history }
    func elementZoom(on page: Int) -> CGFloat {
        canvas.zoomScale * (elementPageView(page)?.transform.a ?? 1)
    }

    func elementPageView(_ index: Int) -> PageView? {
        pageViews.indices.contains(index) ? pageViews[index] : nil
    }

    func elementUndoChanged() {
        undoChanged()
    }

    func elementShowMenu(_ rect: CGRect, in pageView: PageView) {
        let onScreen = pageView.convert(rect, to: self)
        menuTarget = onScreen
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: "element" as NSString,
                                                                 sourcePoint: CGPoint(x: onScreen.midX, y: onScreen.minY)))
    }

    func elementHideMenu() {
        editMenu?.dismissMenu()
    }

    func elementTransfer(_ point: CGPoint, from page: Int) -> (page: Int, point: CGPoint)? {
        guard pageViews.indices.contains(page) else { return nil }
        let inPages = pageViews[page].convert(point, to: pagesView)
        guard let target = pageViews.first(where: { $0.frame.contains(inPages) }) else { return nil }
        return (target.index, pagesView.convert(inPages, to: target))
    }

    func elementReveal(_ rect: CGRect, in pageView: PageView) {
        let target = pageView.convert(rect, to: canvas)
        let bottom = canvas.contentOffset.y + canvas.bounds.height - canvas.adjustedContentInset.bottom
        guard target.maxY + 20 > bottom else { return }
        let maxY = max(-canvas.adjustedContentInset.top,
                       canvas.contentSize.height - canvas.bounds.height + canvas.adjustedContentInset.bottom)
        let y = min(canvas.contentOffset.y + target.maxY + 20 - bottom, maxY)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: true)
    }
}

/// SwiftUI에서 쓰는 Apple 도구 편집기
struct PencilKitEditor: UIViewRepresentable {
    let document: NoteDocument
    let bridge: EditorBridge
    let initialPage: Int
    let fingerDrawing: Bool
    let twoUp: Bool
    var zoomLocked = false
    let insets: EdgeInsets

    func makeUIView(context: Context) -> PencilKitEditorView {
        let view = PencilKitEditorView(document: document, bridge: bridge)
        view.initialPage = initialPage
        return view
    }

    func updateUIView(_ view: PencilKitEditorView, context: Context) {
        view.setFingerDrawing(fingerDrawing)
        view.setTwoUp(twoUp)
        view.setZoomLocked(zoomLocked)
        view.chromeInsets = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
    }

    static func dismantleUIView(_ view: PencilKitEditorView, coordinator: ()) {
        view.prepareForRemoval()
        let document = view.document
        Task { await document.flush(reason: "편집기 닫힘") }
    }
}
