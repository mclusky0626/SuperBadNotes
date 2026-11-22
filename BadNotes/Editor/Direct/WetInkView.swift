//
//  WetInkView.swift
//  BadNotes
//
//  화면 좌표 위 임시 레이어: 지금 긋는 획, 막 끝난 획(타일이 다시 그려질 때까지), 올가미 선,
//  선택 상자, 옮기는 중인 획, 지우개 동그라미.
//  확대·스크롤과 상관없이 화면 해상도로 그려서 선명하고, 바뀐 영역만 다시 그림.
//
//  막 끝난 획: 페이지 타일이 그 획을 포함해서 다시 그린 영역만큼 여기서 지움.
//  그래서 두 번 겹쳐 진해지지도(형광펜), 잠깐 사라졌다 나타나지도 않음.
//

import UIKit
import PencilKit

final class WetInkView: UIView {
    private struct Settling {
        let stroke: SampledStroke
        weak var page: UIView?
        let ink: PageInk
        let key: StrokeKey
        let start: CFTimeInterval
        let offset: CGVector
    }

    private var active: SampledStroke?
    private weak var activePage: UIView?
    private var settling: [Settling] = []
    private var moving: [SampledStroke] = []
    private weak var movingPage: UIView?
    private var movingOffset: CGVector = .zero
    private var lasso: [CGPoint] = []
    private weak var lassoPage: UIView?
    private var selection: CGRect?
    private weak var selectionPage: UIView?
    private var eraser: (center: CGPoint, radius: CGFloat)?
    private weak var eraserPage: UIView?

    private var link: CADisplayLink?
    private var lastBounds: CGRect = .null

    /// 타일이 끝내 안 그려지면(화면 밖 등) 이만큼 지나서 정리
    private static let settleTimeout: CFTimeInterval = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var hasContent: Bool {
        active != nil || !settling.isEmpty || !moving.isEmpty || !lasso.isEmpty || selection != nil || eraser != nil
    }

    // MARK: 바꾸기

    func setActive(_ stroke: PKStroke?, page: UIView?) {
        active = stroke.map { InkRenderer.sample($0) }
        activePage = page
        refresh()
    }

    /// 펜을 뗀 획은 페이지 타일이 그릴 때까지 여기서 계속 보여 줌
    func settle(_ stroke: PKStroke, page: UIView, ink: PageInk) {
        let key = StrokeKey(stroke)
        settling.append(Settling(stroke: InkRenderer.sample(stroke, key: key), page: page, ink: ink, key: key,
                                 start: CACurrentMediaTime(), offset: .zero))
        startTicking()
        refresh()
    }

    func setMoving(_ strokes: [SampledStroke], page: UIView?) {
        moving = strokes
        movingPage = page
        movingOffset = .zero
        refresh()
    }

    func setMovingOffset(_ offset: CGVector) {
        movingOffset = offset
        refresh()
    }

    /// 옮기기를 끝낸 획도 타일이 새 자리에 그릴 때까지 보여 줌. keys = 옮긴 뒤 획의 키 (moving과 같은 순서)
    func settleMoving(keys: [StrokeKey], ink: PageInk) {
        if let page = movingPage {
            let now = CACurrentMediaTime()
            for (stroke, key) in zip(moving, keys) {
                settling.append(Settling(stroke: stroke, page: page, ink: ink, key: key, start: now, offset: movingOffset))
            }
            startTicking()
        }
        moving = []
        movingPage = nil
        movingOffset = .zero
        refresh()
    }

    func setLasso(_ points: [CGPoint], page: UIView?) {
        lasso = points
        lassoPage = page
        refresh()
    }

    func setSelection(_ rect: CGRect?, page: UIView?) {
        selection = rect
        selectionPage = page
        refresh()
    }

    func setEraser(center: CGPoint?, radius: CGFloat, page: UIView?) {
        eraser = center.map { ($0, radius) }
        eraserPage = page
        refresh()
    }

    func stop() {
        link?.invalidate()
        link = nil
        for item in settling { item.ink.clearPending(item.key) }
        settling = []
    }

    /// 내용이나 화면 위치(스크롤·확대)가 바뀌었을 때. 예전 영역과 새 영역만 다시 그림
    func refresh() {
        let now = contentBounds()
        let dirty = lastBounds.union(now)
        lastBounds = now
        guard !dirty.isNull else { return }
        let area = dirty.insetBy(dx: -4, dy: -4).intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return }
        setNeedsDisplay(area)
    }

    // MARK: 그리기

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        for item in settling {
            guard let page = item.page else { continue }
            let covered = item.ink.coveredRects(for: item.key)
            ctx.saveGState()
            ctx.concatenate(transform(from: page))
            if covered.isEmpty {
                InkRenderer.draw(item.stroke, in: ctx, smooth: true, offset: item.offset)
            } else {
                // 타일이 이미 그린 영역은 지운 채로 (겹치지 않게)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                InkRenderer.draw(item.stroke, in: ctx, smooth: true, offset: item.offset)
                ctx.setBlendMode(.clear)
                for area in covered { ctx.fill(area) }
                ctx.endTransparencyLayer()
            }
            ctx.restoreGState()
        }

        if let page = movingPage, !moving.isEmpty {
            ctx.saveGState()
            ctx.concatenate(transform(from: page))
            for stroke in moving {
                InkRenderer.draw(stroke, in: ctx, smooth: true, offset: movingOffset)
            }
            ctx.restoreGState()
        }

        if let active, let page = activePage {
            ctx.saveGState()
            ctx.concatenate(transform(from: page))
            InkRenderer.draw(active, in: ctx, smooth: true)
            ctx.restoreGState()
        }

        // 선·상자는 화면 좌표로 바꿔서 그림 → 확대해도 선 굵기가 그대로
        if lasso.count > 1, let page = lassoPage {
            let t = transform(from: page)
            let path = UIBezierPath()
            path.move(to: lasso[0].applying(t))
            for point in lasso.dropFirst() { path.addLine(to: point.applying(t)) }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.setLineDash([6, 4], count: 2, phase: 0)
            tintColor.setStroke()
            path.stroke()
        }

        if let selection, let page = selectionPage {
            let box = selection.applying(transform(from: page)).insetBy(dx: -6, dy: -6)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 8)
            tintColor.withAlphaComponent(0.08).setFill()
            path.fill()
            path.lineWidth = 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            tintColor.setStroke()
            path.stroke()
        }

        if let eraser, let page = eraserPage {
            let t = transform(from: page)
            let center = eraser.center.applying(t)
            let radius = eraser.radius * hypot(t.a, t.b)
            let circle = UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                     width: radius * 2, height: radius * 2))
            UIColor.white.withAlphaComponent(0.35).setFill()
            circle.fill()
            UIColor.black.withAlphaComponent(0.45).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
    }

    /// 페이지 좌표 → 이 뷰 좌표
    func transform(from page: UIView) -> CGAffineTransform {
        let origin = page.convert(CGPoint.zero, to: self)
        let x = page.convert(CGPoint(x: 1, y: 0), to: self)
        let y = page.convert(CGPoint(x: 0, y: 1), to: self)
        return CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                 c: y.x - origin.x, d: y.y - origin.y,
                                 tx: origin.x, ty: origin.y)
    }

    // MARK: 내부

    /// 획 영역이 타일로 다 덮였는지 (영역 안 격자 점이 모두 덮인 영역 안에 있으면)
    private static func isCovered(_ bounds: CGRect, by rects: [CGRect]) -> Bool {
        guard !rects.isEmpty, !bounds.isNull else { return false }
        let steps = 6
        for i in 0...steps {
            for j in 0...steps {
                let point = CGPoint(x: bounds.minX + bounds.width * CGFloat(i) / CGFloat(steps),
                                    y: bounds.minY + bounds.height * CGFloat(j) / CGFloat(steps))
                if !rects.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }

    private func contentBounds() -> CGRect {
        var result = CGRect.null
        func add(_ rect: CGRect, _ page: UIView?) {
            guard let page, !rect.isNull else { return }
            result = result.union(rect.applying(transform(from: page)))
        }
        if let active { add(active.bounds, activePage) }
        for item in settling { add(item.stroke.bounds.offsetBy(dx: item.offset.dx, dy: item.offset.dy), item.page) }
        for stroke in moving { add(stroke.bounds.offsetBy(dx: movingOffset.dx, dy: movingOffset.dy), movingPage) }
        if let first = lasso.first {
            let box = lasso.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            add(box, lassoPage)
        }
        if let selection { add(selection, selectionPage) }
        if let eraser {
            add(CGRect(x: eraser.center.x - eraser.radius, y: eraser.center.y - eraser.radius,
                       width: eraser.radius * 2, height: eraser.radius * 2), eraserPage)
        }
        return result.isNull ? result : result.insetBy(dx: -12, dy: -12)
    }

    private func startTicking() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        settling.removeAll { item in
            let bounds = item.stroke.bounds.offsetBy(dx: item.offset.dx, dy: item.offset.dy)
            let done = item.page == nil
                || now - item.start > Self.settleTimeout
                || Self.isCovered(bounds, by: item.ink.coveredRects(for: item.key))
            if done { item.ink.clearPending(item.key) }
            return done
        }
        if settling.isEmpty {
            link?.invalidate()
            link = nil
        }
        refresh()
    }
}
