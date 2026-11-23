//
//  GlassShape.swift
//  BadNotes
//
//  진짜 Apple Liquid Glass를 아무 모양으로: SwiftUI `.glassEffect(_:in:)`에 글자·획 윤곽을 모양으로 넘김.
//  → 테두리 굴절·반사광까지 Apple이 그 모양을 따라 그림 (UIGlassEffect는 사각·둥근 모양만 됨).
//  유리 글자와 Liquid Glass 펜 획이 화면에서는 이걸로 그려짐. 흉내 그림은 PDF 파일(다른 앱용)에만.
//

import SwiftUI
import UIKit

/// CGPath를 SwiftUI 모양으로 (좌표 그대로)
struct PathShape: Shape {
    let path: CGPath

    func path(in rect: CGRect) -> Path {
        Path(path)
    }
}

struct GlassShapeView: View {
    let path: CGPath
    let tint: Color
    /// 0 거의 투명 ~ 1 진한 색 유리
    let strength: Double

    var body: some View {
        Color.clear
            .glassEffect(Glass.clear.tint(tint.opacity(0.12 + strength * 0.7)), in: PathShape(path: path))
            .allowsHitTesting(false)
    }
}

/// UIKit 화면(페이지·글상자) 안에 까는 SwiftUI 유리
final class GlassShapeHost: UIView {
    private let host: UIHostingController<GlassShapeView>

    init(path: CGPath, tint: UIColor, strength: Double, frame: CGRect) {
        host = UIHostingController(rootView: GlassShapeView(path: path, tint: Color(uiColor: tint), strength: strength))
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(path: CGPath, tint: UIColor, strength: Double) {
        host.rootView = GlassShapeView(path: path, tint: Color(uiColor: tint), strength: strength)
    }
}
