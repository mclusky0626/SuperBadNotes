//
//  ElementController.swift
//  BadNotes
//
//  페이지 요소 다루기: 고르기, 끌어서 옮기기·크기 바꾸기, 글자 고치기, 메뉴, 실행 취소.
//  편집기(직접 필기 / Apple 도구)는 터치를 받아서 여기로 넘겨 주기만 함.
//

import UIKit

@MainActor
protocol ElementHost: AnyObject {
    var elementDocument: NoteDocument { get }
    var elementUndo: UndoManager { get }
    /// 페이지 pt → 화면 pt 배율
    var elementZoom: CGFloat { get }
    func elementPageView(_ index: Int) -> PageView?
    func elementUndoChanged()
    func elementShowMenu(_ rect: CGRect, in pageView: PageView)
    func elementHideMenu()
    /// 키보드에 가리지 않게 그 영역이 보이도록 스크롤
    func elementReveal(_ rect: CGRect, in pageView: PageView)
    /// 한 페이지 좌표의 점이 어느 페이지 위에 있는지 (그 페이지 좌표로). 페이지 밖이면 nil
    func elementTransfer(_ point: CGPoint, from page: Int) -> (page: Int, point: CGPoint)?
}

final class ElementController: NSObject, UITextViewDelegate {
    struct Selected: Equatable {
        var page: Int
        var id: UUID
    }

    private struct Drag {
        var page: Int
        var id: UUID
        var resize: Bool
        var start: CGPoint
        var startFrame: CGRect
        var before: [PageElement]
        var frame: CGRect
    }

    private struct Editing {
        var page: Int
        var id: UUID
        var before: [PageElement]
        var name: String
    }

    weak var host: ElementHost?
    var tools: InkToolState?
    private(set) var selected: Selected?
    private var drag: Drag?
    private var editing: Editing?

    var isEditing: Bool { editing != nil }
    var isDragging: Bool { drag != nil }
    var dragPage: Int? { drag?.page }

    // MARK: 찾기

    func elements(_ page: Int) -> [PageElement] {
        host?.elementDocument.elements(for: page) ?? []
    }

    func element(_ id: UUID, page: Int) -> PageElement? {
        elements(page).first { $0.id == id }
    }

    var selectedElement: PageElement? {
        selected.flatMap { element($0.id, page: $0.page) }
    }

    /// 그 자리 맨 위 요소
    func hit(_ point: CGPoint, page: Int) -> PageElement? {
        let slop = 6 / max(host?.elementZoom ?? 1, 0.01)
        return elements(page).last { $0.frame.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// 고른 요소를 잡을 수 있는 자리인지 (몸통 또는 크기 손잡이)
    func grabs(_ point: CGPoint, page: Int) -> Bool {
        guard !isEditing, let selected, selected.page == page, let element = selectedElement,
              let pageView = host?.elementPageView(page) else { return false }
        if onHandle(point, pageView: pageView) { return true }
        let slop = 8 / max(host?.elementZoom ?? 1, 0.01)
        return element.frame.insetBy(dx: -slop, dy: -slop).contains(point)
    }

    func isInsideEditing(_ point: CGPoint, page: Int) -> Bool {
        guard let editing, editing.page == page, let element = element(editing.id, page: page) else { return false }
        return element.frame.insetBy(dx: -10, dy: -10).contains(point)
    }

    private func onHandle(_ point: CGPoint, pageView: PageView) -> Bool {
        let frame = pageView.selectionFrame
        guard !frame.isHidden, frame.showsHandle else { return false }
        let c = frame.handleCenter
        return hypot(point.x - c.x, point.y - c.y) <= frame.handleRadius * 1.7
    }

    // MARK: 화면

    func refresh(_ pageView: PageView, animated: Bool = false) {
        guard let document = host?.elementDocument else { return }
        pageView.setElements(document.elements(for: pageView.index), image: { document.image(for: $0) }, animated: animated)
    }

    func updateSelectionFrame() {
        guard let host else { return }
        if let selected, let element = selectedElement, let pageView = host.elementPageView(selected.page) {
            let frame = drag?.frame ?? element.frame
            pageView.selectionFrame.showsHandle = !isEditing
            pageView.selectionFrame.show(frame, zoom: host.elementZoom)
        }
    }

    /// 확대를 끝냈을 때: 고치는 글자를 그 배율로 다시 그림
    func zoomEnded() {
        guard let editing, let view = host?.elementPageView(editing.page)?.elementView(editing.id) else { return }
        view.setRenderScale(renderScale)
    }

    private var renderScale: CGFloat {
        let screen = host?.elementPageView(selected?.page ?? 0)?.traitCollection.displayScale ?? 2
        return min(max(1, (host?.elementZoom ?? 1) * max(screen, 1)), 12)
    }

    // MARK: 고르기

    func select(_ id: UUID, page: Int, showMenu: Bool = true) {
        if let old = selected, old.page != page {
            host?.elementPageView(old.page)?.selectionFrame.show(nil, zoom: 1)
        }
        selected = Selected(page: page, id: id)
        updateSelectionFrame()
        if showMenu { presentMenu() }
    }

    func clearSelection() {
        endEditing()
        if let selected { host?.elementPageView(selected.page)?.selectionFrame.show(nil, zoom: 1) }
        selected = nil
        host?.elementHideMenu()
    }

    func presentMenu() {
        guard !isEditing, let selected, let element = selectedElement,
              let pageView = host?.elementPageView(selected.page) else { return }
        host?.elementShowMenu(element.frame, in: pageView)
    }

    // MARK: 만들기

    /// 텍스트 상자: 누른 자리(왼쪽 위)에 만들고 바로 글자 입력
    /// 텍스트 상자: 누른 자리(왼쪽 가운데)에 만들고 바로 글자 입력. 모양은 텍스트 도구 막대 설정
    func insertText(at point: CGPoint, page: Int, pageSize: CGSize, fill: PageElement.Fill) {
        var element = PageElement(kind: .text, x: 0, y: 0, width: min(340, pageSize.width * 0.6), height: 40)
        element.fill = fill
        if let tools {
            element.fontSize = tools.textSize
            element.font = tools.textFont
            element.textColor = tools.textColor
            element.bold = tools.textBold
            element.alignment = tools.textAlignment
            element.glassClear = tools.textGlassClear
            element.glassText = tools.textGlass
            element.glassTextStrength = tools.textGlassStrength
        }
        if fill == .color {
            element.fillColor = PageElement.fillColors[0].1
            if element.textColor.isLight { element.textColor = RGBAColor(hex: 0x1C1C1E) }
        }
        element.height = ElementRenderer.fittedHeight(element)
        element.x = min(max(4, point.x - 6), max(4, pageSize.width - element.width - 4))
        element.y = min(max(4, point.y - element.height / 2), max(4, pageSize.height - element.height - 4))
        place(element, page: page, edit: true, name: "텍스트 상자")
    }

    /// 메모지: 누른 자리(가운데)에 놓고 바로 글자 입력. 색·유리 여부는 메모지 도구 막대 설정
    func insertSticky(center: CGPoint, page: Int, pageSize: CGSize) {
        let side = min(240, pageSize.width * 0.42)
        var element = PageElement(kind: .sticky, x: 0, y: 0, width: side, height: side)
        element.fontSize = 22
        if let tools {
            element.font = tools.textFont
            element.fillColor = tools.stickyColor
            element.fill = tools.stickyGlass ? .glass : .color
            element.glassClear = tools.stickyGlassClear
            element.glassTint = tools.stickyGlass ? (tools.stickyColor.a < 0.01 ? 0 : 0.5) : 0
        }
        element.height = ElementRenderer.fittedHeight(element)
        element.x = min(max(4, center.x - side / 2), max(4, pageSize.width - side - 4))
        element.y = min(max(4, center.y - element.height / 2), max(4, pageSize.height - element.height - 4))
        place(element, page: page, edit: true, name: "메모지")
    }

    func insertImage(id: String, size: CGSize, center: CGPoint, page: Int, pageSize: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // 페이지 폭의 60%, 높이의 50%, 그리고 화이트보드처럼 큰 판에서도 너무 크지 않게 긴 변 520pt까지
        let scale = min(pageSize.width * 0.6 / size.width, pageSize.height * 0.5 / size.height, 520 / max(size.width, size.height), 1)
        let w = max(40, size.width * scale), h = max(40, size.height * scale)
        var element = PageElement(kind: .image, x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        element.imageID = id
        element.x = min(max(4, element.x), max(4, pageSize.width - w - 4))
        element.y = min(max(4, element.y), max(4, pageSize.height - h - 4))
        place(element, page: page, edit: false, name: "사진")
    }

    /// 도구 막대에서 글자·메모지 모양을 바꾸면 지금 고른(고치는) 상자에도 바로 적용
    func restyleFromTools() {
        guard let tools, let selected, let element = selectedElement else { return }
        var updated = element
        switch element.kind {
        case .text:
            updated.font = tools.textFont
            updated.fontSize = tools.textSize
            updated.textColor = tools.textColor
            updated.bold = tools.textBold
            updated.alignment = tools.textAlignment
            updated.glassText = tools.textGlass
            if tools.textGlass { updated.glassTextStrength = tools.textGlassStrength }
            updated.fill = tools.textFill
            if tools.textFill == .glass { updated.glassClear = tools.textGlassClear }
            if tools.textFill == .color && updated.fillColor.a < 0.01 { updated.fillColor = PageElement.fillColors[0].1 }
        case .sticky:
            updated.fillColor = tools.stickyColor
            updated.fill = tools.stickyGlass ? .glass : .color
            updated.glassClear = tools.stickyGlassClear
            if tools.stickyGlass && updated.glassTint < 0.01 && tools.stickyColor.a > 0.01 { updated.glassTint = 0.5 }
        case .image:
            return
        }
        guard updated != element else { return }
        if updated.hasText {
            let fitted = ElementRenderer.fittedHeight(updated)
            updated.height = updated.kind == .sticky ? max(fitted, updated.height) : fitted
        }
        var list = elements(selected.page)
        guard let index = list.firstIndex(where: { $0.id == selected.id }) else { return }
        list[index] = updated
        if let editing, editing.id == selected.id, let view = host?.elementPageView(selected.page)?.elementView(selected.id) {
            // 고치는 중: 실행 취소는 입력을 끝낼 때 한 번에. 화면만 바로 바꿈
            host?.elementDocument.updateElements(list, page: selected.page)
            view.restyleEditing(updated, image: nil)
            updateSelectionFrame()
        } else {
            commit(list, previous: elements(selected.page), page: selected.page, name: "모양")
            updateSelectionFrame()
        }
    }

    private func place(_ element: PageElement, page: Int, edit: Bool, name: String) {
        endEditing()
        let before = elements(page)
        let after = before + [element]
        if edit {
            // 글자를 넣기 전까지는 실행 취소 기록 없이 둠 (빈 상자로 끝나면 흔적 없이 사라지게)
            apply(after, page: page)
            select(element.id, page: page, showMenu: false)
            beginEditing(before: before, name: name)
        } else {
            commit(after, previous: before, page: page, name: name)
            select(element.id, page: page)
        }
    }

    // MARK: 끌기 (옮기기 / 크기)

    func beginDrag(at point: CGPoint, page: Int) -> Bool {
        guard !isEditing, let selected, selected.page == page, let element = selectedElement,
              let pageView = host?.elementPageView(page) else { return false }
        let resize = onHandle(point, pageView: pageView)
        guard resize || grabs(point, page: page) else { return false }
        drag = Drag(page: page, id: element.id, resize: resize, start: point, startFrame: element.frame,
                    before: elements(page), frame: element.frame)
        // 옆 페이지로 넘어가도 가려지지 않게 이 페이지를 맨 앞으로
        if let pageView = host?.elementPageView(page) { pageView.superview?.bringSubviewToFront(pageView) }
        host?.elementHideMenu()
        return true
    }

    func moveDrag(to point: CGPoint) {
        guard var drag, let pageView = host?.elementPageView(drag.page),
              let element = drag.before.first(where: { $0.id == drag.id }) else { return }
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        var frame = drag.startFrame
        if drag.resize {
            switch element.kind {
            case .image:
                let width = max(30, drag.startFrame.width + dx)
                frame.size = CGSize(width: width, height: width * drag.startFrame.height / max(1, drag.startFrame.width))
            case .text:
                var probe = element
                probe.width = max(60, drag.startFrame.width + dx)
                frame.size = CGSize(width: probe.width, height: ElementRenderer.fittedHeight(probe))
            case .sticky:
                var probe = element
                probe.width = max(90, drag.startFrame.width + dx)
                frame.size = CGSize(width: probe.width,
                                    height: max(ElementRenderer.fittedHeight(probe), drag.startFrame.height + dy, 60))
            }
        } else {
            // 페이지 경계에 안 막힘 (두 쪽 펼침에서 옆 페이지로 옮길 수 있게). 놓을 때 어느 페이지인지 정함
            frame.origin.x += dx
            frame.origin.y += dy
        }
        drag.frame = frame
        self.drag = drag
        pageView.elementView(drag.id)?.preview(frame: frame)
        pageView.selectionFrame.show(frame, zoom: host?.elementZoom ?? 1)
    }

    func endDrag(cancelled: Bool) {
        guard let drag else { return }
        self.drag = nil
        var after = drag.before
        if !cancelled, !drag.resize, let index = after.firstIndex(where: { $0.id == drag.id }), drag.frame != drag.startFrame,
           let landing = host?.elementTransfer(CGPoint(x: drag.frame.midX, y: drag.frame.midY), from: drag.page),
           landing.page != drag.page {
            // 다른 페이지 위에 놓음 → 그 페이지로 옮김
            var moved = after.remove(at: index)
            moved.frame.origin = CGPoint(x: landing.point.x - moved.frame.width / 2, y: landing.point.y - moved.frame.height / 2)
            let targetBefore = elements(landing.page)
            commitPair(source: (drag.page, after, drag.before), target: (landing.page, targetBefore + [moved], targetBefore),
                       name: "다른 쪽으로 옮기기")
            select(moved.id, page: landing.page, showMenu: false)
        } else if !cancelled, let index = after.firstIndex(where: { $0.id == drag.id }), drag.frame != drag.startFrame {
            var frame = drag.frame
            if !drag.resize, let pageView = host?.elementPageView(drag.page) {
                // 페이지 밖에 놓으면 조금은 보이게 당겨 둠
                let bounds = pageView.bounds
                frame.origin.x = min(max(frame.minX, bounds.minX - frame.width * 0.7), bounds.maxX - frame.width * 0.3)
                frame.origin.y = min(max(frame.minY, bounds.minY - frame.height * 0.7), bounds.maxY - frame.height * 0.3)
            }
            after[index].frame = frame
            commit(after, previous: drag.before, page: drag.page, name: drag.resize ? "크기 바꾸기" : "옮기기")
        } else if let pageView = host?.elementPageView(drag.page) {
            // 제자리: 미리 보기로 바꾼 모양을 되돌림
            refresh(pageView)
        }
        updateSelectionFrame()
        presentMenu()
    }

    // MARK: 글자 고치기

    func beginEditing(before: [PageElement]? = nil, name: String = "글자") {
        guard let host, let selected, let element = selectedElement, element.hasText,
              let pageView = host.elementPageView(selected.page), let view = pageView.elementView(selected.id) else { return }
        if isEditing { return }
        editing = Editing(page: selected.page, id: selected.id, before: before ?? elements(selected.page), name: name)
        host.elementHideMenu()
        // 도구 막대가 이 상자의 글꼴·색·유리 설정을 보여 줌
        tools?.adopt(element)
        let textView = view.beginEditing(delegate: self, renderScale: renderScale)
        pageView.scheduleGlass()
        updateSelectionFrame()
        textView.becomeFirstResponder()
        host.elementReveal(element.frame, in: pageView)
    }

    func endEditing() {
        guard let editing else { return }
        self.editing = nil
        let pageView = host?.elementPageView(editing.page)
        let view = pageView?.elementView(editing.id)
        if let textView = view?.textView {
            textView.delegate = nil
            if textView.isFirstResponder { textView.resignFirstResponder() }
        }
        view?.endEditing()
        var after = elements(editing.page)
        if let index = after.firstIndex(where: { $0.id == editing.id }), after[index].kind == .text,
           after[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 빈 텍스트 상자는 지움
            after.remove(at: index)
            if selected?.id == editing.id {
                pageView?.selectionFrame.show(nil, zoom: 1)
                selected = nil
            }
        }
        if after != editing.before {
            commit(after, previous: editing.before, page: editing.page, name: editing.name)
        } else {
            apply(after, page: editing.page)
        }
        updateSelectionFrame()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let editing, var element = element(editing.id, page: editing.page),
              let pageView = host?.elementPageView(editing.page) else { return }
        element.text = textView.text
        let height = ElementRenderer.fittedHeight(element)
        element.height = element.kind == .sticky ? max(height, element.height) : height
        var list = elements(editing.page)
        guard let index = list.firstIndex(where: { $0.id == editing.id }) else { return }
        list[index] = element
        // 실행 취소 기록은 끝날 때 한 번. 문서(복구 기록)에는 바로 넣어서 앱이 죽어도 안 잃음
        host?.elementDocument.updateElements(list, page: editing.page)
        pageView.elementView(editing.id)?.resizeForEditing(element)
        updateSelectionFrame()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        endEditing()
    }

    // MARK: 고치기

    private func change(_ name: String, _ edit: (inout PageElement) -> Void) {
        guard let selected, let element = selectedElement else { return }
        endEditing()
        var updated = element
        edit(&updated)
        if updated.hasText { updated.height = updated.kind == .sticky
            ? max(ElementRenderer.fittedHeight(updated), updated.height) : ElementRenderer.fittedHeight(updated) }
        var list = elements(selected.page)
        guard let index = list.firstIndex(where: { $0.id == selected.id }) else { return }
        let before = list
        list[index] = updated
        commit(list, previous: before, page: selected.page, name: name)
        updateSelectionFrame()
        presentMenu()
    }

    func deleteSelected() {
        guard let selected else { return }
        endEditing()
        let before = elements(selected.page)
        let after = before.filter { $0.id != selected.id }
        clearSelection()
        commit(after, previous: before, page: selected.page, name: "삭제")
    }

    func duplicateSelected() {
        guard let selected, var copy = selectedElement else { return }
        endEditing()
        let before = elements(selected.page)
        copy.id = UUID()
        copy.x += 24
        copy.y += 24
        commit(before + [copy], previous: before, page: selected.page, name: "복제")
        select(copy.id, page: selected.page)
    }

    func bringSelectedToFront() {
        guard let selected, let element = selectedElement else { return }
        let before = elements(selected.page)
        let after = before.filter { $0.id != selected.id } + [element]
        guard after != before else { return }
        commit(after, previous: before, page: selected.page, name: "맨 앞으로")
        presentMenu()
    }

    // MARK: 메뉴

    func menu() -> UIMenu? {
        guard let element = selectedElement, !isEditing else { return nil }
        var items: [UIMenuElement] = []
        if element.hasText {
            items.append(UIAction(title: "글자 고치기", image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
                self?.beginEditing()
            })
        }
        if element.kind == .text {
            items.append(UIMenu(title: "바탕", image: UIImage(systemName: "square.on.square"), children:
                PageElement.Fill.allCases.map { fill in
                    UIAction(title: fill.title, image: UIImage(systemName: fill.icon), state: element.fill == fill ? .on : .off) { [weak self] _ in
                        self?.change("바탕") { e in
                            e.fill = fill
                            if fill == .color && e.fillColor.a < 0.01 { e.fillColor = PageElement.fillColors[0].1 }
                        }
                    }
                }))
            if element.fill == .color {
                items.append(colorMenu(title: "바탕 색", colors: PageElement.fillColors, current: element.fillColor) { e, color in
                    e.fillColor = color
                    e.textColor = color.isLight ? RGBAColor(hex: 0x1C1C1E) : RGBAColor(hex: 0xFFFFFF)
                })
            }
        }
        if element.kind == .sticky {
            items.append(colorMenu(title: "메모지 색", colors: PageElement.stickyColors, current: element.fillColor) { e, color in
                e.fillColor = color
                if e.glassTint < 0.01 { e.glassTint = 0.3 }
            })
        }
        if element.usesGlass {
            var glass: [UIMenuElement] = [
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "뿌옇게", image: UIImage(systemName: "cloud.fog"), state: element.glassClear ? .off : .on) { [weak self] _ in
                        self?.change("유리") { $0.glassClear = false }
                    },
                    UIAction(title: "맑게 (뒤가 비침)", image: UIImage(systemName: "drop"), state: element.glassClear ? .on : .off) { [weak self] _ in
                        self?.change("유리") { $0.glassClear = true }
                    },
                ]),
                UIMenu(title: "색 진하기", image: UIImage(systemName: "circle.lefthalf.filled"), children:
                    [("없음", 0.0), ("약하게", 0.15), ("보통", 0.3), ("진하게", 0.5), ("아주 진하게", 0.75)].map { name, value in
                        UIAction(title: name, state: abs(element.glassTint - value) < 0.01 ? .on : .off) { [weak self] _ in
                            self?.change("유리 색 진하기") { $0.glassTint = value }
                        }
                    }),
            ]
            if element.kind == .text {
                glass.append(colorMenu(title: "유리 색", colors: PageElement.stickyColors, current: element.fillColor) { e, color in
                    e.fillColor = color
                    if e.glassTint < 0.01 { e.glassTint = 0.3 }
                })
            }
            items.append(UIMenu(title: "유리", image: UIImage(systemName: "drop.halffull"), children: glass))
        }
        if element.hasText {
            let sizes: [CGFloat] = [14, 18, 22, 28, 36, 48]
            items.append(UIMenu(title: "글자", image: UIImage(systemName: "textformat.size"), children: [
                UIMenu(title: "글꼴", image: UIImage(systemName: "textformat"), children: TextFonts.available.map { option in
                    UIAction(title: option.title, image: Self.fontPreview(option.id),
                             state: element.font == option.id ? .on : .off) { [weak self] _ in
                        self?.change("글꼴") { $0.font = option.id }
                    }
                }),
                UIMenu(title: "크기", children: sizes.map { size in
                    UIAction(title: "\(Int(size))pt", state: abs(element.fontSize - size) < 0.5 ? .on : .off) { [weak self] _ in
                        self?.change("글자 크기") { $0.fontSize = size }
                    }
                }),
                UIAction(title: "굵게", image: UIImage(systemName: "bold"), state: element.bold ? .on : .off) { [weak self] _ in
                    self?.change("굵게") { $0.bold.toggle() }
                },
                UIAction(title: "유리 글자 (Liquid Glass)", image: UIImage(systemName: "drop.halffull"),
                         state: element.glassText ? .on : .off) { [weak self] _ in
                    self?.change("유리 글자") { $0.glassText.toggle() }
                },
                UIMenu(title: "유리 글자 진하기", image: UIImage(systemName: "circle.lefthalf.filled"), children:
                    [("투명하게", 0.1), ("맑게", 0.25), ("보통", 0.4), ("진하게", 0.65), ("아주 진하게", 0.9)].map { name, value in
                        UIAction(title: name, state: element.glassText && abs(element.glassTextStrength - value) < 0.01 ? .on : .off) { [weak self] _ in
                            self?.change("유리 글자 진하기") {
                                $0.glassText = true
                                $0.glassTextStrength = value
                            }
                        }
                    }),
                UIMenu(title: "정렬", children: [("왼쪽", "text.alignleft"), ("가운데", "text.aligncenter"), ("오른쪽", "text.alignright")]
                    .enumerated().map { index, item in
                        UIAction(title: item.0, image: UIImage(systemName: item.1), state: element.alignment == index ? .on : .off) { [weak self] _ in
                            self?.change("정렬") { $0.alignment = index }
                        }
                    }),
                UIAction(title: "지금 펜 색으로", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                    guard let tools = self?.tools else { return }
                    let color = tools.penColors[min(tools.penColorIndex, tools.penColors.count - 1)]
                    self?.change("글자 색") { $0.textColor = color }
                },
            ]))
        }
        items.append(UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.duplicateSelected()
        })
        items.append(UIAction(title: "맨 앞으로", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { [weak self] _ in
            self?.bringSelectedToFront()
        })
        items.append(UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.deleteSelected()
        })
        return UIMenu(children: items)
    }

    /// 메뉴에 보여 줄 글꼴 견본 "가A"
    private static func fontPreview(_ id: String) -> UIImage {
        let font = TextFonts.font(id, size: 15, bold: false)
        let text = NSAttributedString(string: "가A", attributes: [.font: font, .foregroundColor: UIColor.label])
        let size = text.size()
        return UIGraphicsImageRenderer(size: CGSize(width: max(28, ceil(size.width)), height: 20)).image { _ in
            text.draw(at: CGPoint(x: 0, y: (20 - size.height) / 2))
        }
    }

    private func colorMenu(title: String, colors: [(String, RGBAColor)], current: RGBAColor,
                           apply: @escaping (inout PageElement, RGBAColor) -> Void) -> UIMenu {
        UIMenu(title: title, image: UIImage(systemName: "paintpalette"), children: colors.map { name, color in
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
                let rect = CGRect(x: 1, y: 1, width: 16, height: 16)
                (color.a < 0.01 ? UIColor.systemGray5 : color.uiColor).setFill()
                UIBezierPath(ovalIn: rect).fill()
                UIColor.black.withAlphaComponent(0.2).setStroke()
                UIBezierPath(ovalIn: rect).stroke()
            }.withRenderingMode(.alwaysOriginal)
            return UIAction(title: name, image: swatch, state: current == color ? .on : .off) { [weak self] _ in
                self?.change(title) { apply(&$0, color) }
            }
        })
    }

    // MARK: 반영 + 실행 취소

    private func apply(_ list: [PageElement], page: Int) {
        guard let host else { return }
        host.elementDocument.updateElements(list, page: page)
        if let pageView = host.elementPageView(page) { refresh(pageView, animated: true) }
        if let selected, selected.page == page, !list.contains(where: { $0.id == selected.id }) {
            host.elementPageView(page)?.selectionFrame.show(nil, zoom: 1)
            self.selected = nil
            host.elementHideMenu()
        }
    }

    /// 두 페이지를 한 번에 바꾸고 실행 취소도 한 번에 (페이지 사이로 옮기기)
    private func commitPair(source: (page: Int, list: [PageElement], previous: [PageElement]),
                            target: (page: Int, list: [PageElement], previous: [PageElement]), name: String) {
        guard let host else { return }
        apply(source.list, page: source.page)
        apply(target.list, page: target.page)
        host.elementUndo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.endEditing()
                controller.commitPair(source: (source.page, source.previous, source.list),
                                      target: (target.page, target.previous, target.list), name: name)
                controller.updateSelectionFrame()
            }
        }
        host.elementUndo.setActionName(name)
        host.elementUndoChanged()
    }

    private func commit(_ list: [PageElement], previous: [PageElement], page: Int, name: String) {
        guard let host else { return }
        apply(list, page: page)
        host.elementUndo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.endEditing()
                target.commit(previous, previous: list, page: page, name: name)
                target.updateSelectionFrame()
            }
        }
        host.elementUndo.setActionName(name)
        host.elementUndoChanged()
    }
}
