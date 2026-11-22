//
//  RGBAColor.swift
//  BadNotes
//
//  저장할 수 있는 색 (sRGB 0~1). 테마와 필기 도구 설정에서 씀.
//

import SwiftUI
import UIKit

nonisolated struct RGBAColor: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    /// 다크 모드용 색이 섞여 있어도 라이트 기준으로 고정해서 저장
    init(_ uiColor: UIColor) {
        let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 1
        if !resolved.getRed(&rr, green: &gg, blue: &bb, alpha: &aa) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &aa)
            rr = white; gg = white; bb = white
        }
        r = Double(min(1, max(0, rr)))
        g = Double(min(1, max(0, gg)))
        b = Double(min(1, max(0, bb)))
        a = Double(min(1, max(0, aa)))
    }

    init(_ color: Color) {
        self.init(UIColor(color))
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// 밝은 색인지 (위에 올릴 글자색 고를 때)
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.62 }
}
