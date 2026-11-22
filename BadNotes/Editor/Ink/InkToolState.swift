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
        case pen, highlighter, eraser, lasso
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pen: "펜"
            case .highlighter: "형광펜"
            case .eraser: "지우개"
            case .lasso: "올가미"
            }
        }

        var icon: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .eraser: "eraser"
            case .lasso: "lasso"
            }
        }
    }

    enum PenStyle: String, Codable, CaseIterable, Identifiable {
        case ballpoint, fountain, brush, pencil
        var id: String { rawValue }

        var title: String {
            switch self {
            case .ballpoint: "볼펜"
            case .fountain: "만년필"
            case .brush: "붓펜"
            case .pencil: "연필"
            }
        }

        var icon: String {
            switch self {
            case .ballpoint: "pencil.line"
            case .fountain: "pencil.tip"
            case .brush: "paintbrush.pointed"
            case .pencil: "pencil"
            }
        }

        /// 만년필은 Apple의 납작한 캘리그라피 펜촉 대신, 굿노트처럼 필압으로 굵기가 변하는 펜
        var inkType: PKInk.InkType {
            switch self {
            case .ballpoint: .monoline
            case .fountain, .brush: .pen
            case .pencil: .pencil
            }
        }

        /// 필압에 따라 굵기가 몇 배까지 변하는지
        var pressureRange: ClosedRange<CGFloat> {
            switch self {
            case .ballpoint, .pencil: 1...1
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

        var icon: String {
            switch self {
            case .partial: "eraser"
            case .stroke: "eraser.line.dashed"
            }
        }
    }

    static let penWidths: [CGFloat] = [1.2, 2.2, 3.8]
    static let highlighterWidths: [CGFloat] = [10, 16, 24]
    /// 지우개 지름 (페이지 pt)
    static let eraserSizes: [CGFloat] = [10, 22, 48]

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
            ? Self.highlighterWidths[min(highlighterWidthIndex, Self.highlighterWidths.count - 1)]
            : Self.penWidths[min(penWidthIndex, Self.penWidths.count - 1)]
    }

    var eraserRadius: CGFloat { Self.eraserSizes[min(eraserSizeIndex, Self.eraserSizes.count - 1)] / 2 }

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
        if tool == .eraser { return Self.eraserSizes }
        return inkTool == .highlighter ? Self.highlighterWidths : Self.penWidths
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
        penWidthIndex = min(max(0, s.penWidthIndex), Self.penWidths.count - 1)
        if s.highlighterColors.count == 3 { highlighterColors = s.highlighterColors }
        highlighterColorIndex = min(max(0, s.highlighterColorIndex), 2)
        highlighterWidthIndex = min(max(0, s.highlighterWidthIndex), Self.highlighterWidths.count - 1)
        eraserSizeIndex = min(max(0, s.eraserSizeIndex), Self.eraserSizes.count - 1)
        previousTool = inkTool
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(tool: tool, inkTool: inkTool, penStyle: penStyle, eraserMode: eraserMode,
                       penColors: penColors, penColorIndex: penColorIndex, penWidthIndex: penWidthIndex,
                       highlighterColors: highlighterColors, highlighterColorIndex: highlighterColorIndex,
                       highlighterWidthIndex: highlighterWidthIndex, eraserSizeIndex: eraserSizeIndex)
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
