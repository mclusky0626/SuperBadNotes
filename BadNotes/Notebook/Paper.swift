//
//  Paper.swift
//  BadNotes
//
//  노트북 종이와 표지.
//  노트북도 그냥 PDF. 어떤 종이인지는 PDF 키워드에 "BadNotesPaper=..."로 넣어 두고,
//  페이지를 더할 때 그걸 읽어서 같은 종이를 만듦 (파일만 있으면 정보가 따라다님).
//

import UIKit

nonisolated struct PaperSpec: Codable, Hashable, Sendable {
    enum Template: String, Codable, CaseIterable, Identifiable, Sendable {
        case blank, dotted, grid, ruledNarrow, ruledWide
        var id: String { rawValue }
        var title: String {
            switch self {
            case .blank: "백지"
            case .dotted: "점선지"
            case .grid: "모눈 종이"
            case .ruledNarrow: "줄친 종이 (좁은 간격)"
            case .ruledWide: "줄친 종이 (넓은 간격)"
            }
        }
    }

    enum Tone: String, Codable, CaseIterable, Identifiable, Sendable {
        case yellow, white, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .yellow: "노란색"
            case .white: "흰색"
            case .dark: "검은색"
            }
        }
        var paper: UIColor {
            switch self {
            case .yellow: UIColor(red: 0.988, green: 0.969, blue: 0.906, alpha: 1)
            case .white: .white
            case .dark: UIColor(red: 0.13, green: 0.135, blue: 0.15, alpha: 1)
            }
        }
        var line: UIColor {
            switch self {
            case .yellow: UIColor(red: 0.85, green: 0.81, blue: 0.70, alpha: 1)
            case .white: UIColor(red: 0.80, green: 0.83, blue: 0.88, alpha: 1)
            case .dark: UIColor(red: 0.30, green: 0.31, blue: 0.34, alpha: 1)
            }
        }
    }

    enum Size: String, Codable, CaseIterable, Identifiable, Sendable {
        case a4Portrait, a4Landscape, tabletPortrait, tabletLandscape
        var id: String { rawValue }
        var title: String {
            switch self {
            case .a4Portrait: "A4, 세로"
            case .a4Landscape: "A4, 가로"
            case .tabletPortrait: "iPad, 세로"
            case .tabletLandscape: "iPad, 가로"
            }
        }
        var points: CGSize {
            switch self {
            case .a4Portrait: CGSize(width: 595, height: 842)
            case .a4Landscape: CGSize(width: 842, height: 595)
            case .tabletPortrait: CGSize(width: 768, height: 1024)
            case .tabletLandscape: CGSize(width: 1024, height: 768)
            }
        }
    }

    var template: Template
    var tone: Tone
    var width: CGFloat
    var height: CGFloat

    init(template: Template, tone: Tone, size: Size) {
        self.template = template
        self.tone = tone
        width = size.points.width
        height = size.points.height
    }

    init(template: Template, tone: Tone, width: CGFloat, height: CGFloat) {
        self.template = template
        self.tone = tone
        self.width = width
        self.height = height
    }

    var pageSize: CGSize { CGSize(width: width, height: height) }

    // MARK: PDF 키워드로 저장

    static let keywordPrefix = "BadNotesPaper="
    /// 첫 장이 표지인 노트북
    static let coverPrefix = "BadNotesCover="

    var keyword: String {
        "\(Self.keywordPrefix)\(template.rawValue);\(tone.rawValue);\(Int(width.rounded()));\(Int(height.rounded()))"
    }

    init?(keyword: String) {
        guard keyword.hasPrefix(Self.keywordPrefix) else { return nil }
        let parts = keyword.dropFirst(Self.keywordPrefix.count).split(separator: ";")
        guard parts.count == 4, let template = Template(rawValue: String(parts[0])),
              let tone = Tone(rawValue: String(parts[1])),
              let width = Double(parts[2]), let height = Double(parts[3]), width > 0, height > 0 else { return nil }
        self.init(template: template, tone: tone, width: width, height: height)
    }

    /// PDF 문서 속성의 키워드(배열이거나 문자열)에서 찾음
    static func from(documentAttributes: [AnyHashable: Any]?) -> PaperSpec? {
        keywords(documentAttributes).lazy.compactMap { PaperSpec(keyword: $0) }.first
    }

    static func hasCover(_ documentAttributes: [AnyHashable: Any]?) -> Bool {
        keywords(documentAttributes).contains { $0.hasPrefix(coverPrefix) }
    }

    static func keywords(_ documentAttributes: [AnyHashable: Any]?) -> [String] {
        guard let value = documentAttributes?["Keywords"] else { return [] }
        if let list = value as? [String] { return list.map { $0.trimmingCharacters(in: .whitespaces) } }
        if let text = value as? String {
            return text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        }
        return []
    }
}

/// 노트북 표지 (전부 코드로 그림: `CoverArt`). rawValue는 PDF 키워드에 들어가니 바꾸지 말 것
nonisolated enum CoverStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    // 클래식
    case navy, burgundy, forest, charcoal, cream, sky, lemon, blush
    // 패턴
    case stripes, dots, gingham, linen, terrazzo, memphis, kraft
    // 그림
    case waves, mountains, sunset, night, leaves, bauhaus

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case classic, pattern, art
        var id: String { rawValue }
        var title: String {
            switch self {
            case .classic: "클래식"
            case .pattern: "패턴"
            case .art: "그림"
            }
        }
    }

    var group: Group {
        switch self {
        case .navy, .burgundy, .forest, .charcoal, .cream, .sky, .lemon, .blush: .classic
        case .stripes, .dots, .gingham, .linen, .terrazzo, .memphis, .kraft: .pattern
        case .waves, .mountains, .sunset, .night, .leaves, .bauhaus: .art
        }
    }

    var title: String {
        switch self {
        case .navy: "남색"
        case .burgundy: "버건디"
        case .forest: "숲"
        case .charcoal: "먹색"
        case .cream: "크림"
        case .sky: "하늘"
        case .lemon: "레몬"
        case .blush: "분홍"
        case .stripes: "사선"
        case .dots: "물방울"
        case .gingham: "깅엄 체크"
        case .linen: "리넨"
        case .terrazzo: "테라조"
        case .memphis: "멤피스"
        case .kraft: "크라프트"
        case .waves: "바다"
        case .mountains: "산"
        case .sunset: "노을"
        case .night: "밤하늘"
        case .leaves: "잎사귀"
        case .bauhaus: "바우하우스"
        }
    }

    static func styles(in group: Group) -> [CoverStyle] {
        allCases.filter { $0.group == group }
    }
}
