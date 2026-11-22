//
//  ElementViews.swift
//  BadNotes
//
//  페이지 위 요소(텍스트 상자·유리 메모지·사진)를 화면에 그리는 뷰.
//  - 유리 바탕: 진짜 Liquid Glass (UIGlassEffect). 종이 줄·PDF 글자가 유리 너머로 굴절돼 보임
//  - 글자·사진·색 바탕: 타일 레이어(CATiledLayer) → 확대해도 PDF처럼 선명
//  - 글자를 고치는 동안만 그 자리에 UITextView를 올림
//  좌표 = 페이지 캔버스 좌표 (PageView 안)
//

import UIKit

/// 요소 하나의 글자·사진을 타일로 그림 (백그라운드 스레드)
nonisolated final class ElementTileRenderer: TileRenderer, @unchecked Sendable {
    private let element: PageElement
    private let image: CGImage?

    init(element: PageElement, image: CGImage?) {
        self.element = element
        self.image = image
    }

    func drawTile(in context: CGContext) {
        let rect = CGRect(origin: .zero, size: element.frame.size)
        ElementRenderer.drawBackground(element, in: context, rect: rect, live: true)
        ElementRenderer.drawContent(element, image: image, in: context, rect: rect)
    }
}

final class ElementView: UIView {
    private(set) var element: PageElement
    private var image: CGImage?
    private var glass: UIVisualEffectView?
    private var tiles: TiledView?
    private(set) var textView: UITextView?

    init(element: PageElement, image: CGImage?) {
        self.element = element
        self.image = image
        super.init(frame: element.frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 바뀐 만큼만 다시 그림. 위치만 바뀌면 옮기기만
    func apply(_ new: PageElement, image newImage: CGImage?) {
        let old = element
        let imageChanged = newImage !== image
        element = new
        image = newImage
        frame = new.frame
        var moved = old
        moved.frame = new.frame
        if moved == new && old.frame.size == new.frame.size && !imageChanged {
            resetPreview()
            return
        }
        rebuild()
    }

    private func resetPreview() {
        glass?.frame = bounds
        tiles?.transform = .identity
        tiles?.frame = bounds
    }

    /// 끄는 동안: 크기만 바꿔 보여 줌 (타일은 손 뗄 때 다시 그림)
    func preview(frame newFrame: CGRect) {
        frame = newFrame
        glass?.frame = bounds
        if let tiles {
            if element.kind == .image {
                // 사진은 비율 그대로 늘려 보여 줌
                let sx = newFrame.width / max(1, element.width), sy = newFrame.height / max(1, element.height)
                tiles.transform = CGAffineTransform(scaleX: sx, y: sy)
                tiles.center = CGPoint(x: newFrame.width / 2, y: newFrame.height / 2)
            } else {
                // 글자는 손을 떼면 새 폭으로 다시 줄바꿈해서 그림. 그동안은 왼쪽 위에 붙여 둠
                tiles.transform = .identity
                tiles.frame.origin = .zero
            }
        }
    }

    private func rebuild() {
        tiles?.removeFromSuperview()
        tiles = nil
        let size = element.frame.size

        if element.usesGlass {
            // 메모지: 맑은 유리에 색을 살짝 → 종이 줄이 비쳐 보이는 유리판. 텍스트 상자: 뿌연 유리
            let effect = UIGlassEffect(style: element.kind == .sticky ? .clear : .regular)
            if element.kind == .sticky, element.fillColor.a > 0.01 {
                effect.tintColor = element.fillColor.uiColor.withAlphaComponent(0.3)
            }
            let view = glass ?? UIVisualEffectView(effect: effect)
            view.effect = effect
            view.frame = bounds
            view.isUserInteractionEnabled = false
            view.cornerConfiguration = .corners(radius: .fixed(element.cornerRadius))
            if glass == nil { insertSubview(view, at: 0) }
            glass = view
        } else {
            glass?.removeFromSuperview()
            glass = nil
        }

        guard size.width >= 1, size.height >= 1 else { return }
        let view = TiledView(frame: CGRect(origin: .zero, size: size),
                             renderer: ElementTileRenderer(element: element, image: image))
        view.isHidden = textView != nil
        addSubview(view)
        tiles = view
    }

    // MARK: 글자 고치기

    func beginEditing(delegate: UITextViewDelegate, renderScale: CGFloat) -> UITextView {
        if let textView { return textView }
        let view = UITextView(frame: bounds)
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: element.padding.height, left: element.padding.width,
                                               bottom: element.padding.height, right: element.padding.width)
        view.font = ElementRenderer.font(element)
        view.textColor = element.textColor.uiColor.withAlphaComponent(1)
        view.textAlignment = [.left, .center, .right][min(max(element.alignment, 0), 2)]
        view.typingAttributes = ElementRenderer.attributes(element)
        view.text = element.text
        view.tintColor = .systemBlue
        view.keyboardDismissMode = .none
        view.autocorrectionType = .default
        view.delegate = delegate
        view.overrideUserInterfaceStyle = .light
        addSubview(view)
        textView = view
        tiles?.isHidden = true
        isUserInteractionEnabled = true
        setRenderScale(renderScale)
        return view
    }

    func endEditing() {
        textView?.delegate = nil
        textView?.removeFromSuperview()
        textView = nil
        isUserInteractionEnabled = false
        // 고친 글자로 타일을 새로 그림
        rebuild()
    }

    /// 확대해서 고칠 때 글자가 흐리지 않게 (UITextView는 화면 배율로만 그려서 확대하면 뭉개짐)
    func setRenderScale(_ scale: CGFloat) {
        guard let textView else { return }
        func apply(_ view: UIView) {
            view.contentScaleFactor = scale
            view.layer.contentsScale = scale
            view.setNeedsDisplay()
            for sub in view.subviews { apply(sub) }
        }
        apply(textView)
    }

    /// 고치는 중 글자가 늘면 상자 높이를 맞춤
    func resizeForEditing(_ new: PageElement) {
        element = new
        frame = new.frame
        glass?.frame = bounds
        textView?.frame = bounds
    }
}

/// 고른 요소 둘레 점선 + 오른쪽 아래 크기 손잡이. 확대 배율과 상관없이 화면에서 같은 굵기로
final class SelectionFrameView: UIView {
    private let border = CAShapeLayer()
    private let handle = UIView()
    private(set) var target: CGRect = .null
    private var zoom: CGFloat = 1
    var showsHandle = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(border)
        handle.backgroundColor = .white
        handle.layer.borderColor = UIColor.systemBlue.cgColor
        handle.layer.shadowColor = UIColor.black.cgColor
        handle.layer.shadowOpacity = 0.25
        handle.layer.shadowRadius = 2
        handle.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(handle)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 손잡이 반지름 (페이지 좌표). 터치 판정에도 씀
    var handleRadius: CGFloat { 14 / max(zoom, 0.01) }

    var handleCenter: CGPoint { CGPoint(x: target.maxX, y: target.maxY) }

    func show(_ rect: CGRect?, zoom: CGFloat) {
        guard let rect, !rect.isNull else {
            isHidden = true
            target = .null
            return
        }
        isHidden = false
        target = rect
        self.zoom = max(zoom, 0.01)
        let pad = 4 / self.zoom
        frame = rect.insetBy(dx: -pad - handleRadius, dy: -pad - handleRadius)
        let local = CGRect(x: handleRadius, y: handleRadius, width: rect.width + pad * 2, height: rect.height + pad * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = UIBezierPath(roundedRect: local, cornerRadius: 6 / self.zoom).cgPath
        border.lineWidth = 1.5 / self.zoom
        border.lineDashPattern = [NSNumber(value: Double(6 / self.zoom)), NSNumber(value: Double(4 / self.zoom))]
        CATransaction.commit()
        let size = 18 / self.zoom
        handle.isHidden = !showsHandle
        handle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        handle.layer.cornerRadius = size / 2
        handle.layer.borderWidth = 2 / self.zoom
        handle.center = CGPoint(x: local.maxX - pad, y: local.maxY - pad)
    }
}
