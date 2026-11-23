//
//  InkToolState.swift
//  BadNotes
//
//  직접 필기 모드의 도구 상태: 펜, 형광펜, 지우개, 올가미 + 색, 굵기. 앱을 껐다 켜도 유지.
//

import SwiftUI
import PencilKit
import Observation

@Observable
final class InkToolState {
    static let shared = InkToolState()

    enum Tool: String, Codable, CaseIterable, Identifiable {
        case pen, highlighter, eraser, lasso, text, sticky, image
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pen: "펜"
            case .highlighter: "형광펜"
            case .eraser: "지우개"
            case .lasso: "올가미"
            case .text: "텍스트"
            case .sticky: "메모지"
            case .image: "이미지"
            }
        }

        var icon: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .eraser: "eraser"
            case .lasso: "lasso"
            case .text: "character.textbox"
            case .sticky: "note.text"
            case .image: "photo"
            }
        }

        /// 페이지를 눌러서 무언가를 놓는 도구 (펜슬·손가락 탭으로)
        var places: Bool { self == .text || self == .sticky || self == .image }

        /// 펜슬로 긋는 도구 (펜슬이 페이지에 닿으면 이 도구가 받음)
        var draws: Bool { self == .pen || self == .highlighter || self == .eraser || self == .lasso }
    }

    enum PenStyle: String, Codable, CaseIterable, Identifiable {
        case ballpoint, fountain, brush, pencil, glass
        var id: String { rawValue }

        var title: String {
            switch self {
            case .ballpoint: "볼펜"
            case .fountain: "만년필"
            case .brush: "붓펜"
            case .pencil: "연필"
            case .glass: "Liquid Glass 펜"
            }
        }

        var icon: String {
            switch self {
            case .ballpoint: "pencil.line"
            case .fountain: "pencil.tip"
            case .brush: "paintbrush.pointed"
            case .pencil: "pencil"
            case .glass: "drop.halffull"
            }
        }

        /// 만년필은 Apple의 납작한 캘리그라피 펜촉 대신, 굿노트처럼 필압으로 굵기가 변하는 펜
        var inkType: PKInk.InkType {
            switch self {
            case .ballpoint, .glass: .monoline
            case .fountain, .brush: .pen
            case .pencil: .pencil
            }
        }

        /// 필압에 따라 굵기가 몇 배까지 변하는지
        var pressureRange: ClosedRange<CGFloat> {
            switch self {
            case .ballpoint, .pencil, .glass: 1...1
            case .fountain: 0.7...1.3
            case .brush: 0.3...1.6
            }
        }
    }

    enum EraserMode: String, Codable, CaseIterable, Identifiable {
        case partial, stroke
        var id: String { rawValue }

        var title: String {
            switch self {
            case .partial: "부분 지우개"
            case .stroke: "획 지우개"
            }
        }

        var shortTitle: String {
            switch self {
            case .partial: "부분"
            case .stroke: "획"
            }
        }

        var icon: String {
            switch self {
            case .partial: "eraser"
            case .stroke: "eraser.line.dashed"
            }
        }
    }

    /// 굵기 칸 3개의 처음 값. 칸마다 슬라이더로 바꿀 수 있음 (페이지 pt)
    static let defaultPenWidths: [CGFloat] = [1.2, 2.2, 3.8]
    static let defaultHighlighterWidths: [CGFloat] = [10, 16, 24]
    /// 지우개 지름 (페이지 pt)
    static let defaultEraserSizes: [CGFloat] = [10, 22, 48]
    static let penWidthRange: ClosedRange<CGFloat> = 0.4...16
    static let highlighterWidthRange: ClosedRange<CGFloat> = 4...48
    static let eraserSizeRange: ClosedRange<CGFloat> = 4...120

    var penWidths = InkToolState.defaultPenWidths { didSet { save() } }
    var highlighterWidths = InkToolState.defaultHighlighterWidths { didSet { save() } }
    var eraserSizes = InkToolState.defaultEraserSizes { didSet { save() } }
    /// 지우개가 형광펜 획만 지움 (글씨는 그대로 두고 밑줄만 지울 때)
    var eraserHighlighterOnly = false { didSet { save() } }

    /// 텍스트 도구로 새로 만드는 상자의 바탕과 글자 크기
    var textFill: PageElement.Fill = .none { didSet { save() } }
    var textSize: CGFloat = 20 { didSet { save() } }
    var textFont = "system" { didSet { save() } }
    var textColor = RGBAColor(hex: 0x1C1C1E) { didSet { save() } }
    var textBold = false { didSet { save() } }
    /// 0 왼쪽, 1 가운데, 2 오른쪽
    var textAlignment = 0 { didSet { save() } }
    /// 유리 바탕: 맑게(뒤가 비침) / 뿌옇게
    var textGlassClear = false { didSet { save() } }

    /// 메모지 도구: 색, Liquid Glass로 만들지(끄면 종이 메모지), 맑게
    var stickyColor = PageElement.stickyColors[2].1 { didSet { save() } }
    var stickyGlass = true { didSet { save() } }
    var stickyGlassClear = true { didSet { save() } }

    /// Liquid Glass 펜 진하기 (0 투명 ~ 1 진한 색 유리)
    var glassPenStrength: Double = 0.35 { didSet { save() } }
    /// 유리 글자 (글자 자체가 유리) + 진하기
    var textGlass = false { didSet { save() } }
    var textGlassStrength: Double = 0.4 { didSet { save() } }

    /// 지금 긋는 획의 씨앗값: 유리펜이면 유리 표시를 넣음 (임시 획은 고정)
    func strokeSeed(preview: Bool) -> UInt32 {
        guard inkTool == .pen, penStyle == .glass else { return InkOrigin.badNotesSeed(preview: preview) }
        return GlassInk.seed(strength: glassPenStrength, salt: preview ? 0 : UInt32.random(in: 0...255))
    }

    var tool: Tool = .pen {
        didSet {
            guard tool != oldValue else { return }
            previousTool = oldValue
            if tool == .pen || tool == .highlighter { inkTool = tool }
            save()
        }
    }
    /// 직전 도구 (Apple Pencil 두 번 탭으로 오갈 때)
    private(set) var previousTool: Tool = .pen
    /// 마지막으로 쓴 펜/형광펜. 색·굵기 칸이 이걸 따라감
    private(set) var inkTool: Tool = .pen

    var penStyle: PenStyle = .fountain { didSet { save() } }
    var eraserMode: EraserMode = .partial { didSet { save() } }

    var penColors: [RGBAColor] = [RGBAColor(hex: 0x1C1C1E), RGBAColor(hex: 0x1F5FD6), RGBAColor(hex: 0xD93025)] { didSet { save() } }
    var penColorIndex = 0 { didSet { save() } }
    var penWidthIndex = 1 { didSet { save() } }

    var highlighterColors: [RGBAColor] = [RGBAColor(hex: 0xFFD60A), RGBAColor(hex: 0x7CE07C), RGBAColor(hex: 0xFF8AC6)] { didSet { save() } }
    var highlighterColorIndex = 0 { didSet { save() } }
    var highlighterWidthIndex = 1 { didSet { save() } }

    var eraserSizeIndex = 1 { didSet { save() } }

    // MARK: 지금 쓰는 값

    /// 형광펜은 PencilKit의 납작한 마커 대신 반투명 볼펜(일정한 굵기·둥근 끝)으로 그림.
    /// 방향에 따라 굵기가 들쭉날쭉하지 않고, 레이어 모드에서도 같은 모양
    var currentInkType: PKInk.InkType { inkTool == .highlighter ? .monoline : penStyle.inkType }

    /// 획에 넣을 색. 형광펜은 반투명
    var currentInkColor: UIColor {
        inkTool == .highlighter ? currentColor.uiColor.withAlphaComponent(0.5) : currentColor.uiColor
    }

    var currentPressureRange: ClosedRange<CGFloat> { inkTool == .highlighter ? 1...1 : penStyle.pressureRange }

    var currentColor: RGBAColor {
        inkTool == .highlighter ? highlighterColors[safe: highlighterColorIndex] : penColors[safe: penColorIndex]
    }

    var currentWidth: CGFloat {
        inkTool == .highlighter
            ? highlighterWidths[min(highlighterWidthIndex, highlighterWidths.count - 1)]
            : penWidths[min(penWidthIndex, penWidths.count - 1)]
    }

    var eraserRadius: CGFloat { eraserSizes[min(eraserSizeIndex, eraserSizes.count - 1)] / 2 }

    // MARK: 도구 막대에 보이는 색·굵기

    var paletteColors: [RGBAColor] { inkTool == .highlighter ? highlighterColors : penColors }
    var paletteColorIndex: Int { inkTool == .highlighter ? highlighterColorIndex : penColorIndex }

    /// 색을 고르면 그 색의 펜/형광펜으로 바뀜
    func selectColor(_ index: Int) {
        if inkTool == .highlighter { highlighterColorIndex = index } else { penColorIndex = index }
        if tool != inkTool { tool = inkTool }
    }

    /// 지금 고른 칸의 색을 바꿈 (색 고르기 창)
    func setCurrentSlotColor(_ color: RGBAColor) {
        if inkTool == .highlighter {
            highlighterColors[highlighterColorIndex] = color
        } else {
            penColors[penColorIndex] = color
        }
        if tool != inkTool { tool = inkTool }
    }

    var sizeOptions: [CGFloat] {
        if tool == .eraser { return eraserSizes }
        return inkTool == .highlighter ? highlighterWidths : penWidths
    }

    /// 지금 도구의 굵기 범위 (슬라이더)
    var sizeRange: ClosedRange<CGFloat> {
        if tool == .eraser { return Self.eraserSizeRange }
        return inkTool == .highlighter ? Self.highlighterWidthRange : Self.penWidthRange
    }

    /// 지금 고른 굵기 칸의 값을 바꿈
    func setSize(_ value: CGFloat, at index: Int) {
        let range = sizeRange
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if tool == .eraser {
            if eraserSizes.indices.contains(index) { eraserSizes[index] = clamped }
        } else if inkTool == .highlighter {
            if highlighterWidths.indices.contains(index) { highlighterWidths[index] = clamped }
        } else if penWidths.indices.contains(index) {
            penWidths[index] = clamped
        }
    }

    /// 굵기 칸들을 처음 값으로
    func resetSizes() {
        if tool == .eraser { eraserSizes = Self.defaultEraserSizes }
        else if inkTool == .highlighter { highlighterWidths = Self.defaultHighlighterWidths }
        else { penWidths = Self.defaultPenWidths }
    }

    var sizeIndex: Int {
        if tool == .eraser { return eraserSizeIndex }
        return inkTool == .highlighter ? highlighterWidthIndex : penWidthIndex
    }

    func selectSize(_ index: Int) {
        if tool == .eraser {
            eraserSizeIndex = index
        } else if inkTool == .highlighter {
            highlighterWidthIndex = index
        } else {
            penWidthIndex = index
        }
    }

    func toggleEraser() {
        if tool == .eraser {
            tool = previousTool == .eraser ? inkTool : previousTool
        } else {
            tool = .eraser
        }
    }

    func switchToPrevious() {
        tool = previousTool
    }

    /// 글상자·메모지를 고치기 시작하면 도구 막대가 그 상자의 모양을 보여 줌
    func adopt(_ element: PageElement) {
        switch element.kind {
        case .text:
            textFont = element.font
            textSize = element.fontSize
            textColor = element.textColor
            textBold = element.bold
            textAlignment = element.alignment
            textFill = element.fill
            if element.fill == .glass { textGlassClear = element.glassClear }
            textGlass = element.glassText
            if element.glassText { textGlassStrength = element.glassTextStrength }
            if tool != .text { tool = .text }
        case .sticky:
            stickyColor = element.fillColor
            stickyGlass = element.usesGlass
            if element.usesGlass { stickyGlassClear = element.glassClear }
            if tool != .sticky { tool = .sticky }
        case .image:
            break
        }
    }

    // MARK: 저장

    private struct Stored: Codable {
        var tool: Tool
        var inkTool: Tool
        var penStyle: PenStyle
        var eraserMode: EraserMode
        var penColors: [RGBAColor]
        var penColorIndex: Int
        var penWidthIndex: Int
        var highlighterColors: [RGBAColor]
        var highlighterColorIndex: Int
        var highlighterWidthIndex: Int
        var eraserSizeIndex: Int
        // 나중에 더한 값 (예전 저장본에는 없음)
        var penWidths: [CGFloat]?
        var highlighterWidths: [CGFloat]?
        var eraserSizes: [CGFloat]?
        var eraserHighlighterOnly: Bool?
        var textFill: PageElement.Fill?
        var textSize: CGFloat?
        var textFont: String?
        var textColor: RGBAColor?
        var textBold: Bool?
        var textAlignment: Int?
        var textGlassClear: Bool?
        var stickyColor: RGBAColor?
        var stickyGlass: Bool?
        var stickyGlassClear: Bool?
        var glassPenStrength: Double?
        var textGlass: Bool?
        var textGlassStrength: Double?
    }

    private static let key = "inkTools"
    @ObservationIgnored private var loading = false

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        loading = true
        tool = s.tool
        inkTool = s.inkTool
        penStyle = s.penStyle
        eraserMode = s.eraserMode
        if s.penColors.count == 3 { penColors = s.penColors }
        penColorIndex = min(max(0, s.penColorIndex), 2)
        if let w = s.penWidths, w.count == 3 { penWidths = w }
        if let w = s.highlighterWidths, w.count == 3 { highlighterWidths = w }
        if let w = s.eraserSizes, w.count == 3 { eraserSizes = w }
        eraserHighlighterOnly = s.eraserHighlighterOnly ?? false
        textFill = s.textFill ?? .none
        textSize = s.textSize ?? 20
        textFont = s.textFont ?? "system"
        textColor = s.textColor ?? RGBAColor(hex: 0x1C1C1E)
        textBold = s.textBold ?? false
        textAlignment = s.textAlignment ?? 0
        textGlassClear = s.textGlassClear ?? false
        stickyColor = s.stickyColor ?? PageElement.stickyColors[2].1
        stickyGlass = s.stickyGlass ?? true
        stickyGlassClear = s.stickyGlassClear ?? true
        glassPenStrength = s.glassPenStrength ?? 0.35
        textGlass = s.textGlass ?? false
        textGlassStrength = s.textGlassStrength ?? 0.4
        penWidthIndex = min(max(0, s.penWidthIndex), penWidths.count - 1)
        if s.highlighterColors.count == 3 { highlighterColors = s.highlighterColors }
        highlighterColorIndex = min(max(0, s.highlighterColorIndex), 2)
        highlighterWidthIndex = min(max(0, s.highlighterWidthIndex), highlighterWidths.count - 1)
        eraserSizeIndex = min(max(0, s.eraserSizeIndex), eraserSizes.count - 1)
        previousTool = inkTool
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(tool: tool, inkTool: inkTool, penStyle: penStyle, eraserMode: eraserMode,
                       penColors: penColors, penColorIndex: penColorIndex, penWidthIndex: penWidthIndex,
                       highlighterColors: highlighterColors, highlighterColorIndex: highlighterColorIndex,
                       highlighterWidthIndex: highlighterWidthIndex, eraserSizeIndex: eraserSizeIndex,
                       penWidths: penWidths, highlighterWidths: highlighterWidths, eraserSizes: eraserSizes,
                       eraserHighlighterOnly: eraserHighlighterOnly, textFill: textFill, textSize: textSize,
                       textFont: textFont, textColor: textColor, textBold: textBold, textAlignment: textAlignment,
                       textGlassClear: textGlassClear, stickyColor: stickyColor, stickyGlass: stickyGlass,
                       stickyGlassClear: stickyGlassClear, glassPenStrength: glassPenStrength,
                       textGlass: textGlass, textGlassStrength: textGlassStrength)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

private extension Array where Element == RGBAColor {
    subscript(safe index: Int) -> RGBAColor {
        indices.contains(index) ? self[index] : (first ?? RGBAColor(hex: 0x000000))
    }
}
