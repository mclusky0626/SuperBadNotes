//
//  Theme.swift
//  BadNotes
//
//  테마 = 바탕(내 사진 / 단색 / 그라데이션) + 그 위 Liquid Glass 한 겹 + 강조색 + 카드 모양 + 편집기 배경 + 화면 모드.
//  바탕 이미지 위에 유리 레이어를 씌우고, 앱의 모든 화면이 그 위에 떠 있음.
//

import SwiftUI

nonisolated struct Theme: Codable, Equatable, Identifiable, Sendable {
    enum Base: String, Codable, CaseIterable, Identifiable, Sendable {
        case photo, color, gradient
        var id: String { rawValue }
        var title: String {
            switch self {
            case .photo: "내 사진"
            case .color: "단색"
            case .gradient: "그라데이션"
            }
        }
    }

    enum GlassStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case regular, clear
        var id: String { rawValue }
        var title: String { self == .regular ? "기본 (뿌옇게)" : "투명 (맑게)" }
    }

    enum CardStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case book, glass
        var id: String { rawValue }
        var title: String { self == .book ? "책" : "유리" }
    }

    enum EditorBackground: String, Codable, CaseIterable, Identifiable, Sendable {
        case theme, dimmed, plain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .theme: "테마 그대로"
            case .dimmed: "어둡게"
            case .plain: "단색"
            }
        }
    }

    enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "시스템"
            case .light: "라이트"
            case .dark: "다크"
            }
        }
    }

    var id: UUID
    var name: String
    /// 맨 아래 바탕
    var base: Base
    /// 단색은 첫 번째, 그라데이션은 앞 두 개
    var colors: [RGBAColor]
    var photoBlur: Double
    var photoDim: Double
    /// 바탕 위에 Liquid Glass 한 겹을 씌울지
    var glassLayer: Bool
    var glassStyle: GlassStyle
    var glassTint: RGBAColor
    /// 0이면 색 없음
    var glassTintStrength: Double
    var accent: RGBAColor
    var cardStyle: CardStyle
    /// 0.8 ~ 1.3
    var cardSize: Double
    var editorBackground: EditorBackground
    var appearance: Appearance
    /// 기울이면 바탕이 살짝 따라 움직임
    var parallax: Bool

    /// 항상 두 개로 맞춘 바탕 색
    var baseColors: [Color] {
        var list = colors.map(\.color)
        while list.count < 2 { list.append(list.last ?? .gray) }
        return Array(list.prefix(2))
    }

    /// 앱 전체 유리 재질 (바탕 유리 레이어, 버튼, 막대, 카드)
    var glass: Glass {
        let base: Glass = glassStyle == .clear ? .clear : .regular
        guard glassTintStrength > 0.01 else { return base }
        return base.tint(glassTint.color.opacity(glassTintStrength))
    }

    // MARK: 프리셋 (차분한 것만)

    private static func preset(_ number: Int, _ name: String, _ base: Base, _ colors: [UInt32], accent: UInt32,
                               appearance: Appearance, card: CardStyle = .book) -> Theme {
        Theme(id: UUID(uuidString: String(format: "7A2D3B5F-0000-4000-8000-%012d", number))!,
              name: name, base: base, colors: colors.map { RGBAColor(hex: $0) },
              photoBlur: 0, photoDim: 0.1, glassLayer: true, glassStyle: .regular,
              glassTint: RGBAColor(hex: 0xFFFFFF), glassTintStrength: 0,
              accent: RGBAColor(hex: accent), cardStyle: card, cardSize: 1,
              editorBackground: .theme, appearance: appearance, parallax: false)
    }

    static let presets: [Theme] = [
        preset(1, "기본", .gradient, [0xF4F4F7, 0xE4E5EB], accent: 0x3B5BDB, appearance: .system),
        preset(2, "다크", .gradient, [0x1C1C1F, 0x2B2C32], accent: 0x8AB4FF, appearance: .dark),
        preset(3, "종이", .color, [0xF3EEE3], accent: 0xB5651D, appearance: .light),
        preset(4, "바다", .gradient, [0x0F2A44, 0x1F5F8B], accent: 0x6CC4FF, appearance: .dark),
        preset(5, "숲", .gradient, [0x1E3B2F, 0x3E6B4E], accent: 0x8FD19E, appearance: .dark),
    ]

    static var standard: Theme { presets[0] }
}
