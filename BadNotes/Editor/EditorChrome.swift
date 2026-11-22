//
//  EditorChrome.swift
//  BadNotes
//
//  편집 화면 위에 떠 있는 유리 막대들.
//  - 위: [서재로 · 실행 취소 · 다시 실행 · 페이지 추가]  [도구 · 색 · 굵기]  [테마 · 설정 · 로그]
//  - 아래: 제목 · 쪽수 · 저장 상태 (누르면 페이지 이동)
//

import SwiftUI

struct EditorChrome: View {
    @Environment(ThemeStore.self) private var themes
    @Bindable var tools: InkToolState
    let bridge: EditorBridge
    let mode: AppSettings.EditMode
    let unreadErrors: Int
    let onClose: () -> Void
    let onAddPage: () -> Void
    let onPickPhoto: () -> Void
    let onPickFile: () -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void
    let onLog: () -> Void

    /// 직접 필기 모드에서만 BadNotes 도구 막대 (Apple 도구 모드는 Apple 도구 팔레트가 뜸)
    private var showsInkTools: Bool { mode == .direct }

    var body: some View {
        // 폭이 모자라면(세로 화면, 분할 화면) 색·굵기를 줄인 막대로
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassIconButton(systemImage: "chevron.backward", label: "서재로", size: 40, action: onClose)
                    GlassIconButton(systemImage: "arrow.uturn.backward", label: "실행 취소", size: 40, action: bridge.undo)
                        .disabled(!bridge.canUndo)
                    GlassIconButton(systemImage: "arrow.uturn.forward", label: "다시 실행", size: 40, action: bridge.redo)
                        .disabled(!bridge.canRedo)
                    insertMenu
                }
            }

            Spacer(minLength: 0)
            if showsInkTools {
                ToolPalette(tools: tools, compact: compact)
            }
            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassIconButton(systemImage: "paintpalette", label: "테마", size: 40, action: onTheme)
                    GlassIconButton(systemImage: "gearshape", label: "설정", size: 40, action: onSettings)
                    GlassIconButton(systemImage: unreadErrors > 0 ? "exclamationmark.triangle.fill" : "ladybug",
                                    label: "로그", tint: unreadErrors > 0 ? .red : nil, size: 40, action: onLog)
                }
            }
        }
    }

    /// [+] 넣기: 텍스트 상자, 유리 메모지, 사진, 페이지
    private var insertMenu: some View {
        Menu {
            Section("텍스트") {
                Button("텍스트 상자", systemImage: "character.textbox") { bridge.insert(.text(.none)) }
                Button("유리 텍스트 상자", systemImage: "drop.halffull") { bridge.insert(.text(.glass)) }
                Button("색 바탕 텍스트 상자", systemImage: "square.fill.text.grid.1x2") { bridge.insert(.text(.color)) }
                Button("유리 메모지", systemImage: "note.text") { bridge.insert(.sticky) }
            }
            Section("이미지") {
                Button("사진 보관함", systemImage: "photo.on.rectangle", action: onPickPhoto)
                Button("파일에서 이미지", systemImage: "folder", action: onPickFile)
            }
            Button("페이지 추가", systemImage: "doc.badge.plus", action: onAddPage)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 40 * 0.4, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .glassEffect(themes.glass.interactive(), in: .circle)
        .accessibilityLabel("넣기")
    }
}

/// 펜·형광펜·지우개·올가미·텍스트 + 그 도구의 옵션 (색·굵기 / 지우개 방식·크기 / 글상자 바탕).
/// 고른 도구를 한 번 더 누르면 자세한 설정, 고른 굵기 점을 한 번 더 누르면 굵기 슬라이더
struct ToolPalette: View {
    @Environment(ThemeStore.self) private var themes
    @Bindable var tools: InkToolState
    var compact = false
    @State private var settings = AppSettings.shared

    @State private var showPenOptions = false
    @State private var showHighlighterOptions = false
    @State private var showEraserOptions = false
    @State private var sizeEditor: Int?
    @State private var showCompactSizes = false

    var body: some View {
        HStack(spacing: 2) {
            toolButton(.pen, systemImage: tools.penStyle.icon, options: $showPenOptions) { PenOptions(tools: tools) }
            toolButton(.highlighter, systemImage: InkToolState.Tool.highlighter.icon, options: $showHighlighterOptions) {
                HighlighterOptions(tools: tools, settings: settings)
            }
            toolButton(.eraser, systemImage: tools.eraserMode.icon, options: $showEraserOptions) { EraserOptions(tools: tools) }
            toolButton(.lasso, systemImage: InkToolState.Tool.lasso.icon, options: nil) { EmptyView() }
            toolButton(.text, systemImage: InkToolState.Tool.text.icon, options: nil) { EmptyView() }

            separator

            switch tools.tool {
            case .eraser: eraserBar
            case .text: textBar
            default: inkBar
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassEffect(themes.glass, in: .capsule)
        .animation(.smooth(duration: 0.2), value: tools.tool)
    }

    // MARK: 도구 버튼

    private func toolButton<Options: View>(_ tool: InkToolState.Tool, systemImage: String, options: Binding<Bool>?,
                                           @ViewBuilder content: @escaping () -> Options) -> some View {
        Button {
            if tools.tool == tool, let options {
                options.wrappedValue = true
            } else {
                tools.tool = tool
            }
        } label: {
            toolIcon(tool, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .popover(isPresented: options ?? .constant(false), arrowEdge: .top) {
            content()
                .padding(18)
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityHint(options == nil ? "" : "한 번 더 누르면 설정")
    }

    private func toolIcon(_ tool: InkToolState.Tool, systemImage: String) -> some View {
        let selected = tools.tool == tool
        return Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 38, height: 38)
            .background {
                if selected { Circle().fill(themes.accent) }
            }
            .contentShape(Circle())
            .accessibilityLabel(tool.title)
    }

    // MARK: 펜·형광펜: 색 + 굵기

    @ViewBuilder
    private var inkBar: some View {
        if !compact {
            ForEach(Array(tools.paletteColors.enumerated()), id: \.offset) { index, color in
                Button { tools.selectColor(index) } label: {
                    swatch(color, selected: index == tools.paletteColorIndex && tools.tool == tools.inkTool)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("색 \(index + 1)")
            }
        }
        colorPicker
        separator
        sizeDots
    }

    private var colorPicker: some View {
        ColorPicker("색 고르기", selection: Binding(
            get: { tools.currentColor.color },
            set: { tools.setCurrentSlotColor(RGBAColor($0)) }
        ), supportsOpacity: false)
        .labelsHidden()
        .frame(width: 32, height: 32)
    }

    /// 굵기 점 3개. 고른 점을 한 번 더 누르면 슬라이더
    @ViewBuilder
    private var sizeDots: some View {
        if compact {
            Button { showCompactSizes = true } label: { sizeDot(tools.sizeIndex, selected: true) }
                .buttonStyle(.plain)
                .popover(isPresented: $showCompactSizes, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("굵기", selection: Binding(get: { tools.sizeIndex }, set: { tools.selectSize($0) })) {
                            ForEach(0..<tools.sizeOptions.count, id: \.self) { index in
                                Text(SizeEditor.label(tools.sizeOptions[index])).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        SizeEditor(tools: tools, index: tools.sizeIndex)
                    }
                    .padding(18)
                    .frame(width: 300)
                    .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("굵기")
        } else {
            ForEach(Array(tools.sizeOptions.enumerated()), id: \.offset) { index, _ in
                Button {
                    if index == tools.sizeIndex { sizeEditor = index } else { tools.selectSize(index) }
                } label: {
                    sizeDot(index, selected: index == tools.sizeIndex)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { sizeEditor == index }, set: { if !$0 { sizeEditor = nil } }),
                         arrowEdge: .top) {
                    SizeEditor(tools: tools, index: index)
                        .padding(18)
                        .frame(width: 300)
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel(tools.tool == .eraser ? "지우개 크기 \(index + 1)" : "굵기 \(index + 1)")
                .accessibilityHint("한 번 더 누르면 굵기 조절")
            }
        }
    }

    // MARK: 지우개: 부분/획 + 크기 + 형광펜만

    @ViewBuilder
    private var eraserBar: some View {
        ForEach(InkToolState.EraserMode.allCases) { mode in
            chip(compact ? nil : mode.shortTitle, systemImage: mode.icon, selected: tools.eraserMode == mode) {
                tools.eraserMode = mode
            }
            .accessibilityLabel(mode.title)
        }
        separator
        sizeDots
        separator
        chip(compact ? nil : "형광펜만", systemImage: "highlighter", selected: tools.eraserHighlighterOnly) {
            tools.eraserHighlighterOnly.toggle()
        }
        .accessibilityLabel("형광펜만 지우기")
    }

    // MARK: 텍스트: 바탕 + 글자 색

    @ViewBuilder
    private var textBar: some View {
        ForEach(PageElement.Fill.allCases) { fill in
            chip(compact ? nil : fill.shortTitle, systemImage: fill.icon, selected: tools.textFill == fill) {
                tools.textFill = fill
            }
            .accessibilityLabel(fill.title)
        }
        separator
        Menu {
            Picker("글자 크기", selection: $tools.textSize) {
                ForEach([14, 18, 20, 24, 28, 36, 48] as [CGFloat], id: \.self) { size in
                    Text("\(Int(size))pt").tag(size)
                }
            }
        } label: {
            Text("\(Int(tools.textSize))")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.primary)
                .frame(minWidth: 34, minHeight: 34)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("글자 크기")
    }

    // MARK: 부품

    private func chip(_ title: String?, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, title == nil ? 9 : 11)
            .frame(height: 32)
            .background {
                Capsule().fill(selected ? AnyShapeStyle(themes.accent) : AnyShapeStyle(Color.primary.opacity(0.07)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 1)
    }

    private func swatch(_ color: RGBAColor, selected: Bool) -> some View {
        Circle()
            .fill(color.color)
            .frame(width: 22, height: 22)
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
            .padding(4)
            .overlay {
                if selected { Circle().strokeBorder(themes.accent, lineWidth: 2.5) }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
    }

    /// 굵기 점: 실제 굵기 순서대로 크게
    private func sizeDot(_ index: Int, selected: Bool) -> some View {
        let options = tools.sizeOptions
        let sorted = options.sorted()
        let rank = sorted.firstIndex(of: options[min(index, options.count - 1)]) ?? index
        let diameter: CGFloat = [7, 11, 16][min(rank, 2)]
        return Circle()
            .fill(selected ? themes.accent : Color.primary.opacity(0.5))
            .frame(width: diameter, height: diameter)
            .frame(width: 26, height: 38)
            .contentShape(Rectangle())
    }

    private var separator: some View {
        Capsule()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }
}

/// 굵기 칸 하나의 값을 슬라이더로. 미리보기 획 + 숫자
struct SizeEditor: View {
    @Bindable var tools: InkToolState
    let index: Int

    static func label(_ value: CGFloat) -> String {
        value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    private var value: CGFloat {
        let options = tools.sizeOptions
        return options.indices.contains(index) ? options[index] : 1
    }

    /// 가는 쪽을 섬세하게 고르게 제곱 눈금
    private var position: Binding<Double> {
        let range = tools.sizeRange
        return Binding(
            get: { Double(sqrt(max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))) },
            set: { t in
                let v = range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(t * t)
                tools.setSize((v * 10).rounded() / 10, at: index)
            })
    }

    private var title: String {
        switch tools.tool {
        case .eraser: "지우개 크기"
        default: tools.inkTool == .highlighter ? "형광펜 굵기" : "펜 굵기"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(Self.label(value)) pt")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            preview
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            Slider(value: position, in: 0...1)
            HStack {
                Text("칸 \(index + 1)").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("기본값으로") { tools.resetSizes() }
                    .font(.footnote)
            }
        }
    }

    private var preview: some View {
        Canvas { context, size in
            let width = min(value, size.height - 8)
            if tools.tool == .eraser {
                let d = min(value, size.height - 6)
                let rect = CGRect(x: size.width / 2 - d / 2, y: size.height / 2 - d / 2, width: d, height: d)
                context.stroke(Path(ellipseIn: rect), with: .color(.gray), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                return
            }
            var path = Path()
            let steps = 60
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let x = 18 + (size.width - 36) * t
                let y = size.height / 2 + (tools.inkTool == .highlighter ? 0 : sin(t * .pi * 2) * (size.height / 2 - width / 2 - 6))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let color = tools.currentColor.color.opacity(tools.inkTool == .highlighter ? 0.5 : 1)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 펜을 한 번 더 누르면: 펜 종류 + 굵기
struct PenOptions: View {
    @Environment(ThemeStore.self) private var themes
    @Bindable var tools: InkToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("펜 종류").font(.headline)
            HStack(spacing: 8) {
                ForEach(InkToolState.PenStyle.allCases) { style in
                    Button { tools.penStyle = style } label: {
                        VStack(spacing: 6) {
                            Image(systemName: style.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 52, height: 44)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(tools.penStyle == style ? AnyShapeStyle(themes.accent) : AnyShapeStyle(Color.primary.opacity(0.07))))
                                .foregroundStyle(tools.penStyle == style ? Color.white : Color.primary)
                            Text(style.title).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            SizeEditor(tools: tools, index: tools.penWidthIndex)
        }
    }
}

/// 형광펜을 한 번 더 누르면: 굵기 + 곧게 긋기
struct HighlighterOptions: View {
    @Bindable var tools: InkToolState
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SizeEditor(tools: tools, index: tools.highlighterWidthIndex)
            Divider()
            Toggle("거의 곧게 그으면 곧은 선으로", isOn: $settings.straightHighlighter)
                .font(.subheadline)
        }
    }
}

/// 지우개를 한 번 더 누르면: 방식 + 크기 + 형광펜만
struct EraserOptions: View {
    @Bindable var tools: InkToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("지우개", selection: $tools.eraserMode) {
                ForEach(InkToolState.EraserMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(tools.eraserMode == .partial ? "지나간 자리만 지워요. 남은 부분 모양은 그대로예요."
                                              : "닿은 획을 통째로 지워요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            SizeEditor(tools: tools, index: tools.eraserSizeIndex)
            Divider()
            Toggle("형광펜만 지우기", isOn: $tools.eraserHighlighterOnly)
                .font(.subheadline)
        }
    }
}

/// 아래 가운데: 제목 · 쪽수 · 저장 상태
struct StatusCapsule: View {
    @Environment(ThemeStore.self) private var themes
    let title: String
    let page: Int
    let pageCount: Int
    let saveState: NoteDocument.SaveState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if pageCount > 0 {
                    Text("\(page + 1) / \(pageCount)쪽")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SaveStatusLabel(state: saveState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: 560)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(themes.glass.interactive(), in: .capsule)
        .accessibilityHint("눌러서 페이지 이동")
    }
}

struct SaveStatusLabel: View {
    let state: NoteDocument.SaveState

    var body: some View {
        Group {
            switch state {
            case .saved(nil):
                EmptyView()
            case .saved:
                Label("저장됨", systemImage: "checkmark.circle")
            case .pending:
                Label("저장 대기", systemImage: "circle.dashed")
            case .saving:
                Label("저장 중", systemImage: "arrow.triangle.2.circlepath")
            case .failed:
                Label("저장 실패", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
