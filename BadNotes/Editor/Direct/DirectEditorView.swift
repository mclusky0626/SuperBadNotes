//
//  DirectEditorView.swift
//  BadNotes
//
//  직접 필기 모드 (기본). PDFView를 안 쓰고 직접 만든 보기 화면.
//  - 페이지마다 PDF 타일 + 필기 타일 → 확대 배율에 맞춰 조각마다 다시 그려서 항상 선명
//  - 지금 긋는 획은 화면 좌표 위 임시 레이어(WetInkView)에, 펜을 떼면 페이지 필기에 넣음
//  - 손가락: 스크롤·확대 / 펜슬: 필기 (손가락 필기를 켜면 스크롤은 두 손가락)
//  - 바뀐 필기는 NoteDocument로 넘겨서 복구 기록 + PDF 자동 저장
//

import UIKit
import SwiftUI
import PDFKit
import PencilKit

final class DirectEditorView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate,
                              UIPencilInteractionDelegate, UIEditMenuInteractionDelegate, ElementHost {
    let document: NoteDocument
    private let tools: InkToolState
    private let bridge: EditorBridge

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let wetView = WetInkView()
    private var pageViews: [PageView] = []
    private let history = UndoManager()
    private let inkGesture = InkGestureRecognizer()
    private let undoTap = UITapGestureRecognizer()
    private let redoTap = UITapGestureRecognizer()
    private var editMenu: UIEditMenuInteraction?
    /// 텍스트 상자·메모지·사진
    private let elements = ElementController()
    private let elementTap = UITapGestureRecognizer()
    private let elementPan = UIPanGestureRecognizer()
    /// 키보드가 가린 높이 (그만큼 아래 여백을 더 줌)
    private var keyboardOverlap: CGFloat = 0
    private var editingEndedAt: CFTimeInterval = 0
    /// 이미지 도구로 누른 자리 (사진을 고르면 거기에)
    private var pendingImage: (page: Int, point: CGPoint)?

    // 페이지 보기: 줄(가로면 두 쪽씩) + 책처럼 넘기기
    private var rows: [[Int]] = []
    private var currentRow = 0
    private var bookMode = AppSettings.shared.pageTurn
    private var twoUp = AppSettings.shared.twoUpLandscape
    /// 화이트보드: 지금 확대 배율을 다시 배치할 때도 지킴
    private var boardZoom: CGFloat = 1
    private var fitZoom: CGFloat = 1
    private var turning = false
    private let swipeNext = UISwipeGestureRecognizer()
    private let swipePrev = UISwipeGestureRecognizer()

    private var laidOutWidth: CGFloat = 0
    private var didInitialScroll = false
    private var lastScrollY: CGFloat = 0
    private var lastChromeToggle: CFTimeInterval = 0

    /// 처음 열 때 보여 줄 페이지
    var initialPage = 0

    /// 떠 있는 도구 막대 높이만큼 내용을 비켜 둠
    var chromeInsets: UIEdgeInsets = .zero {
        didSet { if chromeInsets != oldValue { updateInsets() } }
    }

    private enum Action {
        case none
        case drawing(PageView)
        case erasing(PageView, before: PKDrawing, last: CGPoint)
        case lassoing(PageView)
        case moving(PageView, before: PKDrawing, start: CGPoint, indices: [Int])
    }

    private var action: Action = .none
    private var builder: StrokeBuilder?
    private var lassoPoints: [CGPoint] = []
    private var eraseChanged = false
    private var selection: (page: Int, indices: [Int])?

    init(document: NoteDocument, tools: InkToolState, bridge: EditorBridge) {
        self.document = document
        self.tools = tools
        self.bridge = bridge
        super.init(frame: .zero)
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.panGestureRecognizer.allowedTouchTypes = fingers
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = fingers
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        let pdf = document.pdf
        elements.host = self
        elements.tools = tools
        if document.isBoard { bookMode = false }
        for index in 0..<pdf.pageCount {
            let page = pdf.page(at: index) ?? PDFPage()
            let view = PageView(index: index, page: page, size: PageGeometry(page: page).canvasSize,
                                ink: PageInk(drawing: document.drawing(for: index)), documentLock: document.renderLock,
                                board: document.isBoard)
            pageViews.append(view)
            contentView.addSubview(view)
            elements.refresh(view)
        }

        addSubview(wetView)

        inkGesture.delegate = self
        inkGesture.onBegan = { [weak self] touch, event in self?.inputBegan(touch, event) ?? false }
        inkGesture.onMoved = { [weak self] touch, event in self?.inputMoved(touch, event) }
        inkGesture.onEnded = { [weak self] touch, event, cancelled in self?.inputEnded(touch, event, cancelled: cancelled) }
        scrollView.addGestureRecognizer(inkGesture)

        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = fingers
        undoTap.addTarget(self, action: #selector(tapUndo))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = fingers
        redoTap.addTarget(self, action: #selector(tapRedo))
        scrollView.addGestureRecognizer(undoTap)
        scrollView.addGestureRecognizer(redoTap)

        // 요소: 손가락(텍스트 도구면 펜슬도) 탭으로 고르기·만들기, 고른 요소는 끌어서 옮기기·크기 바꾸기
        let anyTouch = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        elementTap.allowedTouchTypes = anyTouch
        elementTap.delegate = self
        elementTap.addTarget(self, action: #selector(handleElementTap(_:)))
        scrollView.addGestureRecognizer(elementTap)
        elementPan.allowedTouchTypes = anyTouch
        elementPan.maximumNumberOfTouches = 1
        elementPan.delegate = self
        elementPan.addTarget(self, action: #selector(handleElementPan(_:)))
        scrollView.addGestureRecognizer(elementPan)
        scrollView.panGestureRecognizer.require(toFail: elementPan)

        // 책처럼 넘기기: 옆으로 쓸기
        for (swipe, direction) in [(swipeNext, UISwipeGestureRecognizer.Direction.left), (swipePrev, .right)] {
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipe.delegate = self
            swipe.addTarget(self, action: #selector(handleSwipe(_:)))
            scrollView.addGestureRecognizer(swipe)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

        addInteraction(UIPencilInteraction(delegate: self))
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu

        history.levelsOfUndo = 300
        bridge.attach(self)
        bridge.pageCount = pageViews.count
        bridge.page = 0
        bridge.undoAction = { [weak self] in self?.performUndo() }
        bridge.redoAction = { [weak self] in self?.performRedo() }
        bridge.jumpAction = { [weak self] page in self?.scroll(toPage: page, animated: true) }
        bridge.pageAddedAction = { [weak self] page in self?.pageAdded(page) }
        bridge.insertAction = { [weak self] what in self?.insert(what) }
        bridge.turnAction = { [weak self] delta in self?.turn(by: delta) }
        bridge.restyleAction = { [weak self] in self?.elements.restyleFromTools() }
        setFingerDrawing(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 바깥(SwiftUI)에서 부르는 것

    func toolChanged(_ tool: InkToolState.Tool) {
        guard tool != currentTool else { return }
        currentTool = tool
        if tool != .lasso { clearSelection() }
        if tool != .eraser { wetView.setEraser(center: nil, radius: 0, page: nil) }
        // 글상자를 고치는 중에 텍스트·메모지 도구로 바뀌는 건 그 상자를 보여 주려는 것이라 그대로 둠
        if tool != .text && tool != .sticky { elements.endEditing() }
    }

    private var currentTool: InkToolState.Tool?

    func setFingerDrawing(_ on: Bool) {
        var types = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if on { types.append(NSNumber(value: UITouch.TouchType.direct.rawValue)) }
        inkGesture.allowedTouchTypes = types
        scrollView.panGestureRecognizer.minimumNumberOfTouches = on ? 2 : 1
        // 손가락 필기면 한 손가락은 필기라서 넘기기는 두 손가락으로
        swipeNext.numberOfTouchesRequired = on ? 2 : 1
        swipePrev.numberOfTouchesRequired = on ? 2 : 1
    }

    /// 설정의 페이지 보기가 바뀌면 지금 페이지를 지키며 다시 배치
    func setPageView(book: Bool, twoUp newTwoUp: Bool) {
        guard !document.isBoard else { return }
        guard book != bookMode || newTwoUp != twoUp else { return }
        let keep = bridge.page
        bookMode = book
        twoUp = newTwoUp
        guard laidOutWidth > 0 else { return }
        currentRow = PageRows.row(containing: keep, in: PageRows.make(count: pageViews.count, twoUp: useTwoUp,
                                                                     coverAlone: document.hasCover))
        layoutPages()
        scroll(toPage: keep, animated: false)
        updateCurrentPage()
    }

    private var useTwoUp: Bool { twoUp && bounds.width > bounds.height }

    func setTapToUndo(_ on: Bool) {
        undoTap.isEnabled = on
        redoTap.isEnabled = on
    }

    func prepareForRemoval() {
        elements.endEditing()
        wetView.stop()
        bridge.detach(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 배치

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        wetView.frame = bounds
        guard bounds.width > 0, abs(bounds.width - laidOutWidth) > 0.5 else { return }
        let keepPage = didInitialScroll ? bridge.page : initialPage
        laidOutWidth = bounds.width
        currentRow = PageRows.row(containing: keepPage, in: PageRows.make(count: pageViews.count, twoUp: useTwoUp,
                                                                         coverAlone: document.hasCover))
        layoutPages()
        if didInitialScroll {
            if !document.isBoard { scroll(toPage: keepPage, animated: false) }
        } else {
            didInitialScroll = true
            scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
            if document.isBoard {
                centerBoard()
            } else if initialPage > 0 {
                scroll(toPage: initialPage, animated: false)
            }
            updateCurrentPage()
            #if DEBUG
            runDemoIfRequested()
            #endif
        }
    }

    /// 페이지를 원래 크기(pt)로 줄(한 쪽 / 두 쪽)마다 놓고 확대 배율을 정함.
    /// 세로 보기: 줄을 위아래로 쌓아 폭에 맞춤. 책 보기: 지금 줄만 보이고 화면 안에 다 들어오게
    private func layoutPages() {
        if document.isBoard {
            layoutBoard()
            return
        }
        rows = PageRows.make(count: pageViews.count, twoUp: useTwoUp, coverAlone: document.hasCover)
        currentRow = min(max(currentRow, 0), max(0, rows.count - 1))
        let maxWidth = pageViews.map(\.bounds.width).max() ?? 1
        let gap = max(12, maxWidth * 0.025)
        let spine: CGFloat = 2
        func width(_ row: [Int]) -> CGFloat {
            row.reduce(0) { $0 + pageViews[$1].bounds.width } + spine * CGFloat(max(0, row.count - 1))
        }
        func height(_ row: [Int]) -> CGFloat { row.map { pageViews[$0].bounds.height }.max() ?? 0 }
        func place(_ row: [Int], x startX: CGFloat, y: CGFloat) {
            var x = startX
            let h = height(row)
            for index in row {
                let view = pageViews[index]
                view.frame.origin = CGPoint(x: x, y: y + (h - view.bounds.height) / 2)
                x += view.bounds.width + spine
            }
        }

        let natural: CGSize
        if bookMode, rows.indices.contains(currentRow) {
            let row = rows[currentRow]
            for view in pageViews { view.isHidden = !row.contains(view.index) }
            // 두 쪽 화면에서 표지가 혼자면 책처럼 오른쪽에
            let full = useTwoUp ? maxWidth * 2 + spine : width(row)
            let offset = (useTwoUp && row == [0] && document.hasCover) ? maxWidth + spine : (full - width(row)) / 2
            place(row, x: gap + offset, y: gap)
            natural = CGSize(width: full + gap * 2, height: height(row) + gap * 2)
        } else {
            for view in pageViews { view.isHidden = false }
            let contentWidth = rows.map(width).max() ?? maxWidth
            var y = gap
            for row in rows {
                place(row, x: gap + (contentWidth - width(row)) / 2, y: y)
                y += height(row) + gap
            }
            natural = CGSize(width: contentWidth + gap * 2, height: y)
        }

        scrollView.minimumZoomScale = 0.01
        scrollView.maximumZoomScale = 100
        scrollView.zoomScale = 1
        contentView.frame = CGRect(origin: .zero, size: natural)
        scrollView.contentSize = natural

        let available = bounds.height - chromeInsets.top - max(chromeInsets.bottom, 60)
        fitZoom = bookMode ? min(bounds.width / natural.width, max(0.1, available / natural.height))
                           : bounds.width / natural.width
        scrollView.minimumZoomScale = fitZoom * 0.5
        scrollView.maximumZoomScale = fitZoom * 12
        scrollView.zoomScale = fitZoom
        updateInsets()
        if bookMode {
            scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
        }
    }

    /// 화이트보드: 한 장을 원래 크기로 두고 1배에서 시작. 아주 멀리(0.12배)까지 멀어지고 6배까지 가까이
    private func layoutBoard() {
        rows = [[0]]
        currentRow = 0
        guard let board = pageViews.first else { return }
        if scrollView.zoomScale > 0.0001, didInitialScroll { boardZoom = scrollView.zoomScale }
        board.isHidden = false
        board.frame.origin = .zero
        scrollView.minimumZoomScale = 0.01
        scrollView.maximumZoomScale = 100
        scrollView.zoomScale = 1
        contentView.frame = CGRect(origin: .zero, size: board.bounds.size)
        scrollView.contentSize = board.bounds.size
        fitZoom = 1
        scrollView.minimumZoomScale = 0.12
        scrollView.maximumZoomScale = 6
        scrollView.zoomScale = boardZoom
        updateInsets()
    }

    /// 화이트보드를 처음 열 때: 쓴 게 있으면 그 가운데, 없으면 판 한가운데
    private func centerBoard() {
        guard let board = pageViews.first else { return }
        let target = document.contentBounds(page: 0) ?? CGRect(x: board.bounds.midX - 400, y: board.bounds.midY - 300,
                                                                 width: 800, height: 600)
        let zoom = scrollView.zoomScale
        let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        scrollView.contentOffset = CGPoint(x: target.midX * zoom - visible.width / 2 - scrollView.adjustedContentInset.left,
                                           y: target.midY * zoom - visible.height / 2 - scrollView.adjustedContentInset.top)
    }

    /// 내용이 화면보다 좁으면 가운데로. 책 보기는 위아래도 가운데
    private func updateInsets() {
        let side = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        var top = chromeInsets.top
        var bottom = max(chromeInsets.bottom, keyboardOverlap + 16)
        if bookMode {
            let free = scrollView.bounds.height - scrollView.contentSize.height - top - bottom
            if free > 0 {
                top += free / 2
                bottom += free / 2
            }
        }
        scrollView.contentInset = UIEdgeInsets(top: top, left: side, bottom: bottom, right: side)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: chromeInsets.top, left: 0,
                                                                bottom: chromeInsets.bottom, right: 0)
    }

    func scroll(toPage index: Int, animated: Bool) {
        guard pageViews.indices.contains(index) else { return }
        if bookMode {
            turn(toRow: PageRows.row(containing: index, in: rows), animated: animated)
            return
        }
        let frame = contentView.convert(pageViews[index].frame, to: scrollView)
        let top = -scrollView.contentInset.top
        let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        let y = min(max(frame.minY - scrollView.contentInset.top - 12, top), bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: animated)
    }

    // MARK: 책처럼 넘기기

    func turn(by delta: Int) {
        guard bookMode else {
            scroll(toPage: min(max(bridge.page + delta, 0), pageViews.count - 1), animated: true)
            return
        }
        let target = currentRow + delta
        guard rows.indices.contains(target) else {
            // 끝이면 살짝 튕기기 (모델 값은 안 바꾸는 덧셈 애니메이션)
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.x")
            let d: CGFloat = delta > 0 ? -22 : 22
            bounce.values = [0, d, -d * 0.3, d * 0.1, 0]
            bounce.keyTimes = [0, 0.25, 0.55, 0.8, 1]
            bounce.duration = 0.45
            bounce.isAdditive = true
            scrollView.layer.add(bounce, forKey: "edge")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        turn(toRow: target, animated: true)
    }

    private func turn(toRow row: Int, animated: Bool) {
        guard rows.indices.contains(row), row != currentRow, !turning else { return }
        clearSelection()
        elements.endEditing()
        elements.clearSelection()
        let forward = row > currentRow
        // 넘기기 전 보이던 페이지 사진
        let old: [PageTurn.Sheet] = animated ? rows[currentRow].compactMap { index in
            let view = pageViews[index]
            guard let shot = view.snapshotView(afterScreenUpdates: false) else { return nil }
            return PageTurn.Sheet(snapshot: shot, frame: view.convert(view.bounds, to: self))
        } : []
        currentRow = row
        layoutPages()
        updateCurrentPage()
        guard animated, !old.isEmpty else { return }
        turning = true
        let newRow = rows[row]
        UISelectionFeedbackGenerator().selectionChanged()
        PageTurn.run(in: self, old: old, forward: forward, newBack: { [weak self] _ in
            // 넘어가는 종이 뒷면 = 새로 펼친 반대쪽 페이지 (반쯤 넘겼을 때 찍음: 그때쯤 타일이 그려져 있음)
            guard let self else { return nil }
            let index = forward ? newRow.first : newRow.last
            return index.flatMap { self.pageViews[$0].snapshotView(afterScreenUpdates: false) }
        }, completion: { [weak self] in
            self?.turning = false
        })
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard bookMode, !turning else { return }
        turn(by: gesture === swipeNext ? 1 : -1)
    }

    /// 실행 취소한 페이지가 화면 밖이면 그 페이지로
    private func reveal(page index: Int) {
        guard pageViews.indices.contains(index) else { return }
        if bookMode {
            if !(rows.indices.contains(currentRow) && rows[currentRow].contains(index)) { scroll(toPage: index, animated: true) }
            return
        }
        let frame = contentView.convert(pageViews[index].frame, to: scrollView)
        if !frame.intersects(scrollView.bounds) {
            scroll(toPage: index, animated: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        wetView.refresh()
        elements.updateSelectionFrame()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        elements.zoomEnded()
        if elements.selected != nil { elements.presentMenu() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCurrentPage()
        if wetView.hasContent { wetView.refresh() }
        if selection != nil || elements.selected != nil { editMenu?.dismissMenu() }
        updateChromeVisibility()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if selection != nil { showSelection() }
        if elements.selected != nil { elements.presentMenu() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate, elements.selected != nil { elements.presentMenu() }
    }

    private func updateCurrentPage() {
        if bookMode {
            guard rows.indices.contains(currentRow) else { return }
            let page = rows[currentRow].first ?? 0
            if bridge.page != page { bridge.page = page }
            let atEnd = currentRow == rows.count - 1
            if bridge.atLastPage != atEnd { bridge.atLastPage = atEnd }
            if bridge.isBook != true { bridge.isBook = true }
            if bridge.canTurnBack != (currentRow > 0) { bridge.canTurnBack = currentRow > 0 }
            if bridge.canTurnForward != !atEnd { bridge.canTurnForward = !atEnd }
            return
        }
        if bridge.isBook { bridge.isBook = false }
        let centerY = (scrollView.contentOffset.y + scrollView.bounds.height / 2) / max(scrollView.zoomScale, 0.001)
        var current = 0
        for (index, view) in pageViews.enumerated() {
            if view.frame.minY <= centerY { current = index } else { break }
        }
        if bridge.page != current { bridge.page = current }
        if let last = pageViews.last {
            let frame = contentView.convert(last.frame, to: scrollView)
            let atEnd = frame.maxY <= scrollView.contentOffset.y + scrollView.bounds.height + 40
            if bridge.atLastPage != atEnd { bridge.atLastPage = atEnd }
        }
    }

    /// 문서 맨 뒤에 페이지가 들어왔을 때 (NoteDocument.appendPage 다음)
    func pageAdded(_ index: Int) {
        guard index == pageViews.count, let page = document.pdf.page(at: index) else { return }
        let view = PageView(index: index, page: page, size: PageGeometry(page: page).canvasSize,
                            ink: PageInk(drawing: document.drawing(for: index)), documentLock: document.renderLock,
                                board: document.isBoard)
        pageViews.append(view)
        contentView.addSubview(view)
        elements.refresh(view)
        bridge.pageCount = pageViews.count
        view.alpha = 0
        UIView.animate(withDuration: 0.35, delay: 0.1, options: [.curveEaseOut]) { view.alpha = 1 }
        if bookMode {
            layoutPages()
            turn(toRow: PageRows.row(containing: index, in: rows), animated: true)
            return
        }
        // 지금 확대·위치 그대로 두고 다시 배치
        let zoom = scrollView.zoomScale
        let offset = scrollView.contentOffset
        layoutPages()
        scrollView.zoomScale = min(max(zoom, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        scrollView.contentOffset = offset
        updateInsets()
        scroll(toPage: index, animated: true)
    }

    /// 손가락으로 아래로 넘기면 도구 막대를 숨기고, 위로 넘기면 다시 보임
    private func updateChromeVisibility() {
        let y = scrollView.contentOffset.y
        let top = -scrollView.contentInset.top
        let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        guard scrollView.isTracking, !scrollView.isZooming, y >= top, y <= bottom else {
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

    // MARK: 입력

    private func pageView(at point: CGPoint) -> PageView? {
        pageViews.first { !$0.isHidden && $0.frame.insetBy(dx: -24, dy: -12).contains(point) }
    }

    private func samples(_ touch: UITouch, _ event: UIEvent?, in view: UIView, predicted: Bool = false) -> [InputSample] {
        var touches: [UITouch]
        if predicted {
            touches = event?.predictedTouches(for: touch) ?? []
        } else {
            touches = event?.coalescedTouches(for: touch) ?? []
            if touches.isEmpty { touches = [touch] }
        }
        return touches.map { t in
            let pencil = t.type == .pencil
            return InputSample(location: t.location(in: view),
                               time: t.timestamp,
                               force: pencil && t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : nil,
                               azimuth: pencil ? t.azimuthAngle(in: view) : 0,
                               altitude: pencil ? t.altitudeAngle : .pi / 2)
        }
    }

    private func inputBegan(_ touch: UITouch, _ event: UIEvent) -> Bool {
        guard let pageView = pageView(at: touch.location(in: contentView)) else { return false }
        let location = touch.location(in: pageView)
        // 고치는 중인 글상자 안은 글상자가 받음 (펜슬 손글씨 입력 포함)
        if elements.isEditing {
            if elements.isInsideEditing(location, page: pageView.index) { return false }
            // 다른 데를 누르면 글 입력만 끝냄 (그 탭으로 새 글상자를 또 만들지 않게)
            elements.endEditing()
            editingEndedAt = CACurrentMediaTime()
            if tools.tool.places { return false }
        }
        // 텍스트 도구는 탭으로, 고른 요소를 잡은 펜슬은 끌기로
        // 텍스트·메모지·이미지 도구는 탭으로 놓음
        if tools.tool.places { return false }
        // 고른 요소를 잡으면 옮기기 (손가락은 늘, 펜슬은 올가미일 때)
        if touch.type != .pencil || tools.tool == .lasso, elements.grabs(location, page: pageView.index) { return false }
        // 다른 데 쓰기 시작하면 고른 요소는 놓아 줌
        if elements.selected != nil { elements.clearSelection() }
        editMenu?.dismissMenu()

        switch tools.tool {
        case .text, .sticky, .image:
            return false
        case .pen, .highlighter:
            clearSelection()
            var newBuilder = StrokeBuilder(inkType: tools.currentInkType, color: tools.currentInkColor,
                                           width: tools.currentWidth, pressureRange: tools.currentPressureRange,
                                           startTime: touch.timestamp)
            for sample in samples(touch, event, in: pageView) { newBuilder.add(sample) }
            builder = newBuilder
            action = .drawing(pageView)
            wetView.setActive(newBuilder.makeStroke(seed: tools.strokeSeed(preview: true)), page: pageView)

        case .eraser:
            clearSelection()
            eraseChanged = false
            action = .erasing(pageView, before: pageView.ink.currentDrawing(), last: location)
            erase(on: pageView, from: location, to: location)
            wetView.setEraser(center: location, radius: tools.eraserRadius, page: pageView)

        case .lasso:
            if let selection, selection.page == pageView.index,
               selectionBounds().insetBy(dx: -16, dy: -16).contains(location) {
                // 선택한 획 옮기기 시작
                let before = pageView.ink.currentDrawing()
                let all = pageView.ink.sampledStrokes()
                let picked = selection.indices.filter { all.indices.contains($0) }.map { all[$0] }
                pageView.invalidateInk(pageView.ink.setHidden(Set(selection.indices)))
                wetView.setMoving(picked, page: pageView)
                wetView.setSelection(nil, page: nil)
                action = .moving(pageView, before: before, start: location, indices: selection.indices)
            } else {
                clearSelection()
                lassoPoints = [location]
                action = .lassoing(pageView)
                wetView.setLasso(lassoPoints, page: pageView)
            }
        }
        return true
    }

    private func inputMoved(_ touch: UITouch, _ event: UIEvent) {
        switch action {
        case .drawing(let pageView):
            guard builder != nil else { return }
            for sample in samples(touch, event, in: pageView) { builder?.add(sample) }
            let predicted = samples(touch, event, in: pageView, predicted: true)
            wetView.setActive(builder?.makeStroke(predicted: predicted, seed: tools.strokeSeed(preview: true)), page: pageView)

        case .erasing(let pageView, let before, var last):
            for sample in samples(touch, event, in: pageView) {
                erase(on: pageView, from: last, to: sample.location)
                last = sample.location
            }
            action = .erasing(pageView, before: before, last: last)
            wetView.setEraser(center: last, radius: tools.eraserRadius, page: pageView)

        case .lassoing(let pageView):
            lassoPoints.append(contentsOf: samples(touch, event, in: pageView).map(\.location))
            wetView.setLasso(lassoPoints, page: pageView)

        case .moving(let pageView, _, let start, _):
            let p = touch.location(in: pageView)
            wetView.setMovingOffset(CGVector(dx: p.x - start.x, dy: p.y - start.y))

        case .none:
            break
        }
    }

    private func inputEnded(_ touch: UITouch, _ event: UIEvent?, cancelled: Bool) {
        let finished = action
        action = .none

        switch finished {
        case .drawing(let pageView):
            defer {
                builder = nil
                wetView.setActive(nil, page: nil)
            }
            guard !cancelled, var finalBuilder = builder else { return }
            for sample in samples(touch, event, in: pageView) { finalBuilder.add(sample) }
            if tools.tool == .highlighter, AppSettings.shared.straightHighlighter,
               let straight = finalBuilder.straightened() {
                finalBuilder = straight
            }
            guard let stroke = finalBuilder.makeStroke(seed: tools.strokeSeed(preview: false)) else { return }
            let before = pageView.ink.currentDrawing()
            var after = before
            after.strokes.append(stroke)
            // 타일이 이 획을 그리는 걸 놓치지 않게 넣기 전에 표시
            pageView.ink.markPending([StrokeKey(stroke)])
            commit(after, previous: before, page: pageView.index, name: "필기")
            wetView.settle(stroke, page: pageView, ink: pageView.ink)

        case .erasing(let pageView, let before, _):
            wetView.setEraser(center: nil, radius: 0, page: nil)
            guard eraseChanged else { return }
            let after = pageView.ink.currentDrawing()
            document.update(after, page: pageView.index)
            registerUndo(previous: before, current: after, page: pageView.index, name: "지우기")

        case .lassoing(let pageView):
            wetView.setLasso([], page: nil)
            if !cancelled {
                // 올가미를 거의 안 그리고 톡 찍었으면: 그 자리 요소 고르기
                let box = lassoPoints.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                if box.width < 8, box.height < 8, let point = lassoPoints.first,
                   let hit = elements.hit(point, page: pageView.index) {
                    elements.select(hit.id, page: pageView.index)
                } else {
                    finishLasso(on: pageView)
                }
            }
            lassoPoints = []

        case .moving(let pageView, let before, let start, let indices):
            let p = touch.location(in: pageView)
            let offset = cancelled ? CGVector.zero : CGVector(dx: p.x - start.x, dy: p.y - start.y)
            if hypot(offset.dx, offset.dy) < 0.5 {
                // 거의 안 움직였으면 그냥 탭: 원래대로
                pageView.invalidateInk(pageView.ink.setHidden([]))
                wetView.setMoving([], page: nil)
            } else {
                var after = before
                for index in indices where after.strokes.indices.contains(index) {
                    after.strokes[index] = StrokeEditing.translated(after.strokes[index], by: offset)
                }
                let movedKeys = indices.filter { after.strokes.indices.contains($0) }.map { StrokeKey(after.strokes[$0]) }
                pageView.ink.markPending(movedKeys)
                commit(after, previous: before, page: pageView.index, name: "옮기기")
                wetView.settleMoving(keys: movedKeys, ink: pageView.ink)
            }
            selection = (pageView.index, indices)
            showSelection()

        case .none:
            break
        }
    }

    // MARK: 지우개

    private func erase(on pageView: PageView, from a: CGPoint, to b: CGPoint) {
        let radius = tools.eraserRadius
        let mode = tools.eraserMode
        var drawing = pageView.ink.currentDrawing()
        let sampled = pageView.ink.sampledStrokes()
        guard sampled.count == drawing.strokes.count else { return }

        let onlyHighlighter = tools.eraserHighlighterOnly
        var changed = false
        var kept: [PKStroke] = []
        kept.reserveCapacity(drawing.strokes.count)
        for (stroke, s) in zip(drawing.strokes, sampled) {
            if onlyHighlighter && !StrokeEditing.isHighlighter(stroke) {
                kept.append(stroke)
                continue
            }
            switch mode {
            case .stroke:
                if StrokeEditing.touches(s, from: a, to: b, radius: radius) {
                    changed = true
                } else {
                    kept.append(stroke)
                }
            case .partial:
                if let pieces = StrokeEditing.erase(stroke, sampled: s, from: a, to: b, radius: radius) {
                    changed = true
                    kept.append(contentsOf: pieces)
                } else {
                    kept.append(stroke)
                }
            }
        }
        guard changed else { return }
        drawing.strokes = kept
        pageView.invalidateInk(pageView.ink.replace(with: drawing))
        eraseChanged = true
    }

    // MARK: 올가미

    private func finishLasso(on pageView: PageView) {
        guard lassoPoints.count > 4 else { return }
        elements.clearSelection()
        let path = CGMutablePath()
        path.addLines(between: lassoPoints)
        path.closeSubpath()
        let indices = StrokeEditing.select(pageView.ink.sampledStrokes(), lasso: path)
        guard !indices.isEmpty else { return }
        selection = (pageView.index, indices)
        showSelection()
    }

    private func selectionBounds() -> CGRect {
        guard let selection, pageViews.indices.contains(selection.page) else { return .null }
        let all = pageViews[selection.page].ink.sampledStrokes()
        return selection.indices.reduce(CGRect.null) { all.indices.contains($1) ? $0.union(all[$1].bounds) : $0 }
    }

    private func showSelection() {
        guard let selection, pageViews.indices.contains(selection.page) else { return }
        let pageView = pageViews[selection.page]
        let rect = selectionBounds()
        guard !rect.isNull else { clearSelection(); return }
        wetView.setSelection(rect, page: pageView)
        let onScreen = pageView.convert(rect, to: self)
        menuTarget = onScreen
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                                 sourcePoint: CGPoint(x: onScreen.midX, y: onScreen.minY)))
    }

    private func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        wetView.setSelection(nil, page: nil)
        editMenu?.dismissMenu()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        if configuration.identifier as? String == "element" { return elements.menu() }
        guard selection != nil else { return nil }
        return UIMenu(children: [
            UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.duplicateSelection()
            },
            UIAction(title: "지금 색으로", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                self?.recolorSelection()
            },
            UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteSelection()
            },
        ])
    }

    private func deleteSelection() {
        guard let selection, pageViews.indices.contains(selection.page) else { return }
        let page = selection.page
        let before = pageViews[page].ink.currentDrawing()
        let removed = Set(selection.indices)
        var after = before
        after.strokes = before.strokes.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        clearSelection()
        commit(after, previous: before, page: page, name: "삭제")
    }

    private func duplicateSelection() {
        guard let selection, pageViews.indices.contains(selection.page) else { return }
        let page = selection.page
        let before = pageViews[page].ink.currentDrawing()
        var after = before
        var copies: [Int] = []
        for index in selection.indices where before.strokes.indices.contains(index) {
            copies.append(after.strokes.count)
            after.strokes.append(StrokeEditing.duplicated(before.strokes[index], by: CGVector(dx: 24, dy: 24)))
        }
        commit(after, previous: before, page: page, name: "복제")
        self.selection = (page, copies)
        showSelection()
    }

    private func recolorSelection() {
        guard let selection, pageViews.indices.contains(selection.page) else { return }
        let page = selection.page
        let color = tools.currentInkColor
        let before = pageViews[page].ink.currentDrawing()
        var after = before
        for index in selection.indices where after.strokes.indices.contains(index) {
            after.strokes[index] = StrokeEditing.recolored(after.strokes[index], to: color)
        }
        commit(after, previous: before, page: page, name: "색 바꾸기")
        showSelection()
    }

    // MARK: 반영 + 실행 취소

    private func commit(_ drawing: PKDrawing, previous: PKDrawing, page: Int, name: String) {
        apply(drawing, page: page)
        registerUndo(previous: previous, current: drawing, page: page, name: name)
    }

    private func apply(_ drawing: PKDrawing, page: Int) {
        guard pageViews.indices.contains(page) else { return }
        let view = pageViews[page]
        view.invalidateInk(view.ink.replace(with: drawing))
        document.update(drawing, page: page)
    }

    private func registerUndo(previous: PKDrawing, current: PKDrawing, page: Int, name: String) {
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.clearSelection()
                target.commit(previous, previous: current, page: page, name: name)
                target.reveal(page: page)
            }
        }
        history.setActionName(name)
        refreshUndoState()
    }

    private func performUndo() {
        clearSelection()
        elements.endEditing()
        if history.canUndo { history.undo() }
        refreshUndoState()
    }

    private func performRedo() {
        clearSelection()
        elements.endEditing()
        if history.canRedo { history.redo() }
        refreshUndoState()
    }

    private func refreshUndoState() {
        if bridge.canUndo != history.canUndo { bridge.canUndo = history.canUndo }
        if bridge.canRedo != history.canRedo { bridge.canRedo = history.canRedo }
    }

    @objc private func tapUndo() { performUndo() }
    @objc private func tapRedo() { performRedo() }

    // MARK: 펜슬 두 번 탭

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser: tools.toggleEraser()
        case .switchPrevious: tools.switchToPrevious()
        default: break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === swipeNext || gestureRecognizer === swipePrev {
            return other === scrollView.panGestureRecognizer
        }
        return gestureRecognizer === inkGesture
            && (other === scrollView.pinchGestureRecognizer || other === scrollView.panGestureRecognizer)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === swipeNext || gestureRecognizer === swipePrev {
            // 확대해서 보는 중에는 옆으로 밀면 스크롤
            return bookMode && !turning && !elements.isEditing && !elements.isDragging
                && scrollView.zoomScale <= fitZoom * 1.05
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === elementTap {
            // 펜슬은 텍스트 도구일 때만 (나머지 도구에서는 필기)
            if touch.type == .pencil { return tools.tool.places }
            // 손가락 필기를 켰으면 손가락도 필기 → 텍스트·올가미 도구에서만, 또는 고른 요소를 다시 누를 때
            if AppSettings.shared.fingerDrawing {
                return tools.tool.places || tools.tool == .lasso || elementAt(touch)?.id == elements.selected?.id
            }
            return true
        }
        if gestureRecognizer === elementPan {
            if touch.type == .pencil, tools.tool != .lasso, tools.tool != .text { return false }
            guard let pageView = pageView(at: touch.location(in: contentView)) else { return false }
            return elements.grabs(touch.location(in: pageView), page: pageView.index)
        }
        return true
    }

    private func elementAt(_ touch: UITouch) -> PageElement? {
        guard let pageView = pageView(at: touch.location(in: contentView)) else { return nil }
        return elements.hit(touch.location(in: pageView), page: pageView.index)
    }

    // MARK: 요소 (텍스트 상자·메모지·사진)

    @objc private func handleElementTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let pageView = pageView(at: gesture.location(in: contentView)) else {
            elements.clearSelection()
            return
        }
        let point = gesture.location(in: pageView)
        if elements.isEditing {
            if elements.isInsideEditing(point, page: pageView.index) { return }
            // 글 입력 중에 다른 데를 누르면 입력만 끝냄
            elements.endEditing()
            return
        }
        // 방금 펜슬 터치로 입력을 끝낸 그 탭이면 아무것도 안 함
        if CACurrentMediaTime() - editingEndedAt < 0.6 { return }
        if let hit = elements.hit(point, page: pageView.index) {
            clearSelection()
            if elements.selected?.id == hit.id, hit.hasText {
                elements.beginEditing()
            } else {
                elements.select(hit.id, page: pageView.index)
            }
            return
        }
        switch tools.tool {
        case .text:
            clearSelection()
            elements.clearSelection()
            elements.insertText(at: point, page: pageView.index, pageSize: pageView.bounds.size, fill: tools.textFill)
            return
        case .sticky:
            clearSelection()
            elements.clearSelection()
            elements.insertSticky(center: point, page: pageView.index, pageSize: pageView.bounds.size)
            return
        case .image:
            // 누른 자리에 넣을 사진을 고르게 함
            elements.clearSelection()
            pendingImage = (pageView.index, point)
            bridge.imageRequest += 1
            return
        default:
            break
        }
        if elements.selected != nil { elements.clearSelection() }
    }

    @objc private func handleElementPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // 끌기가 인식될 때는 이미 조금 움직인 뒤라서, 처음 닿은 자리(손잡이 판정)는 이동량을 빼서 구함
            let moved = gesture.translation(in: contentView)
            let now = gesture.location(in: contentView)
            let start = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
            guard let pageView = pageView(at: start),
                  elements.beginDrag(at: contentView.convert(start, to: pageView), page: pageView.index) else {
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

    /// 도구 막대의 [+]에서: 지금 보고 있는 페이지 가운데에 넣음
    private func insert(_ what: EditorBridge.Insert) {
        clearSelection()
        elements.clearSelection()
        var index = min(max(bridge.page, 0), pageViews.count - 1)
        guard pageViews.indices.contains(index) else { return }
        var pageView = pageViews[index]
        let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        let area = scrollView.convert(visible, to: pageView).intersection(pageView.bounds)
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
            let local = convert(frame, from: nil)
            overlap = max(0, bounds.maxY - local.minY)
        }
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        updateInsets()
        if let selected = elements.selected, elements.isEditing, let element = elements.selectedElement,
           pageViews.indices.contains(selected.page) {
            elementReveal(element.frame, in: pageViews[selected.page])
        }
    }

    // MARK: ElementHost

    var elementDocument: NoteDocument { document }
    var elementUndo: UndoManager { history }
    var elementZoom: CGFloat { scrollView.zoomScale }

    func elementPageView(_ index: Int) -> PageView? {
        pageViews.indices.contains(index) ? pageViews[index] : nil
    }

    func elementUndoChanged() {
        refreshUndoState()
    }

    func elementShowMenu(_ rect: CGRect, in pageView: PageView) {
        let onScreen = pageView.convert(rect, to: self)
        menuTarget = onScreen
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: "element" as NSString,
                                                                 sourcePoint: CGPoint(x: onScreen.midX, y: onScreen.minY)))
    }

    /// 메뉴가 고른 것을 가리지 않게 그 둘레에 띄움
    private var menuTarget: CGRect?

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuTarget ?? CGRect(origin: configuration.sourcePoint, size: .zero)
    }

    func elementHideMenu() {
        editMenu?.dismissMenu()
    }

    func elementReveal(_ rect: CGRect, in pageView: PageView) {
        let target = pageView.convert(rect, to: scrollView)
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let bottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        var y = scrollView.contentOffset.y
        if target.maxY + 20 > bottom { y += target.maxY + 20 - bottom }
        if target.minY - 20 < top + (y - scrollView.contentOffset.y) { y = target.minY - 20 - scrollView.adjustedContentInset.top }
        let maxY = max(-scrollView.adjustedContentInset.top,
                       scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        y = min(max(y, -scrollView.adjustedContentInset.top), maxY)
        if abs(y - scrollView.contentOffset.y) > 1 {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: true)
        }
    }

    // MARK: 점검용 시연

    #if DEBUG
    /// -BNInkDemo 로 켜면 터치 대신 같은 처리 경로로 펜·형광펜·지우개·실행 취소·올가미·확대를 차례로 해 봄
    private func runDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BNInkDemo"), let page = pageViews.first else { return }
        Task { @MainActor in
            let w = page.bounds.width, h = page.bounds.height
            // 시연이 끝나면 사용자가 쓰던 도구 설정으로 돌려놓음
            let saved = (tools.tool, tools.penStyle, tools.penColorIndex, tools.eraserMode, tools.highlighterColorIndex)
            func step(_ name: String) async {
                print("[DEMO] \(name)")
                // 맥에서 기기 화면을 찍을 시간
                try? await Task.sleep(for: .seconds(2.5))
            }
            try? await Task.sleep(for: .seconds(1.5))
            print("[DEMO] 시작")
            try? await Task.sleep(for: .seconds(2))

            tools.tool = .pen
            tools.penStyle = .brush
            let wave = (0...90).map { i in
                CGPoint(x: w * 0.55 + CGFloat(i) * w * 0.004, y: h * 0.72 + sin(CGFloat(i) / 7) * h * 0.04)
            }
            demoStroke(wave, on: page) { i in i < 45 ? 0.1 : 0.8 }
            await step("붓펜 물결")

            tools.penStyle = .ballpoint
            tools.penColorIndex = 1
            let zigzag = (0...40).map { i in
                CGPoint(x: w * 0.55 + CGFloat(i) * w * 0.008, y: h * 0.86 + (i % 2 == 0 ? 0 : h * 0.03))
            }
            demoStroke(zigzag, on: page) { _ in 0.5 }
            await step("볼펜 지그재그")

            tools.tool = .highlighter
            let highlight = (0...60).map { i in CGPoint(x: w * 0.04 + CGFloat(i) * w * 0.007, y: h * 0.485) }
            demoStroke(highlight, on: page) { _ in 0.5 }
            await step("형광펜")

            tools.tool = .eraser
            tools.eraserMode = .partial
            let before = page.ink.currentDrawing()
            eraseChanged = false
            erase(on: page, from: CGPoint(x: w * 0.66, y: h * 0.6), to: CGPoint(x: w * 0.66, y: h * 0.82))
            if eraseChanged {
                let after = page.ink.currentDrawing()
                document.update(after, page: page.index)
                registerUndo(previous: before, current: after, page: page.index, name: "지우기")
            }
            print("[DEMO] 부분 지우개: 획 \(before.strokes.count) → \(page.ink.currentDrawing().strokes.count)")
            await step("부분 지우개")

            performUndo()
            print("[DEMO] 실행 취소 후 획 \(page.ink.currentDrawing().strokes.count)")
            performRedo()
            print("[DEMO] 다시 실행 후 획 \(page.ink.currentDrawing().strokes.count)")
            await step("실행 취소/다시 실행")

            tools.tool = .lasso
            lassoPoints = [CGPoint(x: w * 0.53, y: h * 0.83), CGPoint(x: w * 0.9, y: h * 0.83),
                           CGPoint(x: w * 0.9, y: h * 0.93), CGPoint(x: w * 0.53, y: h * 0.93),
                           CGPoint(x: w * 0.53, y: h * 0.84)]
            finishLasso(on: page)
            print("[DEMO] 올가미 선택: \(selection?.indices.count ?? 0)획")
            await step("올가미")
            try? await Task.sleep(for: .seconds(1.5))

            clearSelection()
            let focus = CGRect(x: w * 0.6, y: h * 0.62, width: w * 0.12, height: h * 0.18)
            scrollView.zoom(to: contentView.convert(focus, from: page), animated: false)
            print("[DEMO] 확대 \(String(format: "%.2f", scrollView.zoomScale / max(0.001, bounds.width / contentView.bounds.width)))배")
            await step("확대")

            if let added = document.appendPage() {
                pageAdded(added)
                print("[DEMO] 페이지 추가: \(added + 1)쪽 (전체 \(pageViews.count)쪽)")
            }
            await step("페이지 추가")

            tools.tool = saved.0
            tools.penStyle = saved.1
            tools.penColorIndex = saved.2
            tools.eraserMode = saved.3
            tools.highlighterColorIndex = saved.4
            print("[DEMO] done")
        }
    }

    private func demoStroke(_ points: [CGPoint], on page: PageView, force: (Int) -> CGFloat) {
        var demo = StrokeBuilder(inkType: tools.currentInkType, color: tools.currentInkColor,
                                 width: tools.currentWidth, pressureRange: tools.currentPressureRange, startTime: 0)
        for (i, point) in points.enumerated() {
            demo.add(InputSample(location: point, time: Double(i) * 0.008, force: force(i), azimuth: 0, altitude: .pi / 2))
        }
        if tools.tool == .highlighter, let straight = demo.straightened() { demo = straight }
        guard let stroke = demo.makeStroke() else { return }
        let before = page.ink.currentDrawing()
        var after = before
        after.strokes.append(stroke)
        page.ink.markPending([StrokeKey(stroke)])
        commit(after, previous: before, page: page.index, name: "필기")
        wetView.settle(stroke, page: page, ink: page.ink)
    }
    #endif
}

/// SwiftUI에서 쓰는 직접 필기 편집기
struct DirectEditor: UIViewRepresentable {
    let document: NoteDocument
    let bridge: EditorBridge
    let initialPage: Int
    let tool: InkToolState.Tool
    let fingerDrawing: Bool
    let tapToUndo: Bool
    let pageTurn: Bool
    let twoUp: Bool
    let insets: EdgeInsets

    func makeUIView(context: Context) -> DirectEditorView {
        let view = DirectEditorView(document: document, tools: .shared, bridge: bridge)
        view.initialPage = initialPage
        return view
    }

    func updateUIView(_ view: DirectEditorView, context: Context) {
        view.toolChanged(tool)
        view.setFingerDrawing(fingerDrawing)
        view.setTapToUndo(tapToUndo)
        view.setPageView(book: pageTurn, twoUp: twoUp)
        view.chromeInsets = UIEdgeInsets(top: insets.top, left: insets.leading,
                                         bottom: insets.bottom, right: insets.trailing)
    }

    static func dismantleUIView(_ view: DirectEditorView, coordinator: ()) {
        view.prepareForRemoval()
        let document = view.document
        Task { await document.flush(reason: "편집기 닫힘") }
    }
}
