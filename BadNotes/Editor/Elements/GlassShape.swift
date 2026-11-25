import SwiftUI
import UIKit

/// 윤곽은 자체 프레임의 좌표로 보관하고, 프레임 위치로 페이지 위에 배치한다.
struct GlassMark {
    let path: CGPath
    var frame: CGRect
    let tint: Color
    let strength: Double

    init?(outline: CGPath, tint: UIColor, strength: Double) {
        let box = outline.boundingBoxOfPath
        guard !box.isNull, !box.isEmpty else { return nil }
        frame = box.insetBy(dx: -1, dy: -1).integral
        var local = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        guard let path = outline.copy(using: &local) else { return nil }
        self.path = path
        self.tint = Color(uiColor: tint)
        self.strength = strength
    }

    init?(stroke s: SampledStroke) {
        guard let strength = s.glassStrength, var outline = s.glassOutline else { return nil }
        if s.maskSpace == .path, let mask = s.mask { outline = outline.intersection(mask) }
        var transform = s.transform
        guard var placed = outline.copy(using: &transform) else { return nil }
        if s.maskSpace == .drawing, let mask = s.mask { placed = placed.intersection(mask) }
        self.init(outline: placed, tint: UIColor(cgColor: s.color), strength: Double(strength))
    }
}

private struct PathShape: Shape {
    let outline: CGPath
    func path(in rect: CGRect) -> Path { Path(outline) }
}

struct GlassMarks: View {
    let marks: [GlassMark]
    let frame: CGRect

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(marks.indices, id: \.self) { index in
                    let mark = marks[index]
                    let material = Glass.clear.tint(mark.tint.opacity(mark.strength))
                    Color.clear
                        .frame(width: mark.frame.width, height: mark.frame.height)
                        .glassEffect(material, in: PathShape(outline: mark.path))
                        .offset(x: mark.frame.minX - frame.minX, y: mark.frame.minY - frame.minY)
                }
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

final class GlassShapeHost: UIView {
    private let content: UIView & UIContentView

    init(marks: [GlassMark]) {
        let frame = marks.reduce(CGRect.null) { $0.union($1.frame) }
        content = Self.configuration(marks, frame: frame).makeContentView()
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        content.backgroundColor = .clear
        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ marks: [GlassMark]) {
        frame = marks.reduce(CGRect.null) { $0.union($1.frame) }
        content.configuration = Self.configuration(marks, frame: frame)
    }

    private static func configuration(_ marks: [GlassMark], frame: CGRect) -> some UIContentConfiguration {
        UIHostingConfiguration { GlassMarks(marks: marks, frame: frame) }
            .margins(.all, 0)
    }
}
