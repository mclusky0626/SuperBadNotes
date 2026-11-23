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
    @State private var settings = AppSettings.shared

    /// BadNotes 도구 모드에서만 BadNotes 도구 막대 (Apple 도구 모드는 Apple 도구 팔레트가 뜸)
    private var showsInkTools: Bool { mode == .direct }

    var body: some View {
        // 폭이 모자라면(분할 화면 등) 색·굵기를 하나로 접은 막대로
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
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if unreadErrors > 0 {
                        GlassIconButton(systemImage: "exclamationmark.triangle.fill", label: "로그", tint: .red, size: 40,
                                        action: onLog)
                            .transition(.scale.combined(with: .opacity))
                    }
                    moreMenu
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
            glassCircle("plus")
        }
        .menuIndicator(.hidden)
        .glassEffect(themes.glass.interactive(), in: .circle)
        .accessibilityLabel("넣기")
    }

    /// [⋯] 보기·테마·설정·로그를 한 곳에 (도구 막대 자리를 넓힘)
    private var moreMenu: some View {
        Menu {
            Section("페이지 보기") {
                Toggle(isOn: $settings.pageTurn) { Label("책처럼 넘기기", systemImage: "book.pages") }
                    .disabled(mode != .direct)
                Toggle(isOn: $settings.twoUpLandscape) { Label("가로 화면에서 두 쪽", systemImage: "rectangle.split.2x1") }
            }
            Button("테마", systemImage: "paintpalette", action: onTheme)
            Button("설정", systemImage: "gearshape", action: onSettings)
            Button("로그", systemImage: "ladybug", action: onLog)
        } label: {
            glassCircle("ellipsis")
        }
        .menuIndicator(.hidden)
        .glassEffect(themes.glass.interactive(), in: .circle)
        .accessibilityLabel("더 보기")
    }

    private func glassCircle(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.primary)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
    }
}

/// 펜·형광펜·지우개·올가미·텍스트 + 그 도구의 옵션.
/// - 고른 도구를 한 번 더 누르면 자세한 설정 (도구 밑 점이 '설정 있음' 표시)
/// - 고른 색을 한 번 더 누르면 색 고르기, 고른 굵기를 한 번 더 누르면 굵기 슬라이더
struct ToolPalette: View {
    @Environment(ThemeStore.self) private var themes
    @Bindable var tools: InkToolState
    var compact = false
    @State private var settings = AppSettings.shared
    @Namespace private var selection

    @State private var showPenOptions = false
    @State private var showHighlighterOptions = false
    @State private var showEraserOptions = false
    @State private var sizeEditor: Int?
    @State private var colorEditor: Int?
    @State private var showCompactSizes = false

    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.78)

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                toolButton(.pen, systemImage: tools.penStyle.icon, options: $showPenOptions) { PenOptions(tools: tools) }
                toolButton(.highlighter, systemImage: InkToolState.Tool.highlighter.icon, options: $showHighlighterOptions) {
                    HighlighterOptions(tools: tools, settings: settings)
                }
                toolButton(.eraser, systemImage: tools.eraserMode.icon, options: $showEraserOptions) { EraserOptions(tools: tools) }
                toolButton(.lasso, systemImage: InkToolState.Tool.lasso.icon, options: nil) { EmptyView() }
                toolButton(.text, systemImage: InkToolState.Tool.text.icon, options: nil) { EmptyView() }
            }

            separator

            Group {
                switch tools.tool {
                case .eraser: eraserBar
                case .text: textBar
                default: inkBar
                }
            }
            .id(contextID)
            .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity),
                                    removal: .opacity))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassEffect(themes.glass, in: .capsule)
        .animation(spring, value: tools.tool)
        .animation(spring, value: tools.inkTool)
    }

    /// 옵션 막대가 바뀌는 단위 (펜↔형광펜도 색이 달라서 새로 그림)
    private var contextID: String {
        switch tools.tool {
        case .eraser, .text: tools.tool.rawValue
        default: "ink-\(tools.inkTool.rawValue)"
        }
    }

    // MARK: 도구 버튼

    private func toolButton<Options: View>(_ tool: InkToolState.Tool, systemImage: String, options: Binding<Bool>?,
                                           @ViewBuilder content: @escaping () -> Options) -> some View {
        let selected = tools.tool == tool
        return Button {
            if selected, let options {
                options.wrappedValue = true
            } else {
                withAnimation(spring) { tools.tool = tool }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .symbolEffect(.bounce, value: selected)
                .frame(width: 40, height: 38)
                .background {
                    if selected {
                        Capsule()
                            .fill(themes.accent.gradient)
                            .shadow(color: themes.accent.opacity(0.35), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "tool", in: selection)
                    }
                }
                .overlay(alignment: .bottom) {
                    // 한 번 더 누르면 설정이 있다는 표시
                    if selected, options != nil {
                        Capsule().fill(Color.white.opacity(0.9)).frame(width: 10, height: 3).offset(y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .popover(isPresented: options ?? .constant(false), arrowEdge: .top) {
            content()
                .padding(18)
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(tool.title)
        .accessibilityHint(options == nil ? "" : "한 번 더 누르면 설정")
    }

    // MARK: 펜·형광펜: 색 + 굵기

    @ViewBuilder
    private var inkBar: some View {
        if compact {
            swatchButton(tools.paletteColorIndex)
        } else {
            ForEach(0..<tools.paletteColors.count, id: \.self) { index in
                swatchButton(index)
            }
        }
        separator
        sizeDots
    }

    /// 색 칸. 고른 칸을 한 번 더 누르면 색 고르기
    private func swatchButton(_ index: Int) -> some View {
        let colors = tools.paletteColors
        let color = colors.indices.contains(index) ? colors[index] : RGBAColor(hex: 0)
        let selected = index == tools.paletteColorIndex && tools.tool == tools.inkTool
        return Button {
            if selected || compact { colorEditor = index } else { withAnimation(spring) { tools.selectColor(index) } }
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 22, height: 22)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
                .padding(4)
                .overlay {
                    if selected {
                        Circle().strokeBorder(themes.accent, lineWidth: 2.5)
                            .transition(.scale(scale: 1.3).combined(with: .opacity))
                    }
                }
                .frame(width: 32, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .popover(isPresented: Binding(get: { colorEditor == index }, set: { if !$0 { colorEditor = nil } }),
                 arrowEdge: .top) {
            ColorPalette(tools: tools, index: index)
                .padding(18)
                .frame(width: 320)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("색 \(index + 1)")
        .accessibilityHint("한 번 더 누르면 색 고르기")
    }

    /// 굵기 점 3개 (실제 굵기 비율대로). 고른 점을 한 번 더 누르면 슬라이더
    @ViewBuilder
    private var sizeDots: some View {
        if compact {
            Button { showCompactSizes = true } label: { sizeDot(tools.sizeIndex, selected: true) }
                .buttonStyle(PressScaleStyle())
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
                    if index == tools.sizeIndex { sizeEditor = index } else { withAnimation(spring) { tools.selectSize(index) } }
                } label: {
                    sizeDot(index, selected: index == tools.sizeIndex)
                }
                .buttonStyle(PressScaleStyle())
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

    /// 굵기 점: 칸 값에 맞춰 크기가 변함 (가장 가는 칸 6pt ~ 가장 굵은 칸 18pt)
    private func sizeDot(_ index: Int, selected: Bool) -> some View {
        let options = tools.sizeOptions
        let value = options[min(max(index, 0), options.count - 1)]
        let range = tools.sizeRange
        let t = sqrt(max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound))))
        let diameter = 5 + 14 * t
        return ZStack {
            if selected {
                Circle().fill(themes.accent.opacity(0.15)).frame(width: 28, height: 28)
                    .transition(.scale.combined(with: .opacity))
            }
            Circle()
                .fill(selected ? AnyShapeStyle(themes.accent) : AnyShapeStyle(Color.primary.opacity(0.55)))
                .frame(width: diameter, height: diameter)
        }
        .frame(width: 30, height: 38)
        .contentShape(Rectangle())
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

    // MARK: 텍스트: 바탕 + 글꼴 + 크기 + 글자 색

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
            Picker("글꼴", selection: $tools.textFont) {
                ForEach(TextFonts.available) { option in
                    Text(option.title).font(Font(TextFonts.font(option.id, size: 17, bold: false))).tag(option.id)
                }
            }
        } label: {
            Text("가A")
                .font(Font(TextFonts.font(tools.textFont, size: 16, bold: false)))
                .foregroundStyle(Color.primary)
                .frame(minWidth: 40, minHeight: 34)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("글꼴: \(TextFonts.title(tools.textFont))")
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
        if !compact {
            separator
            // 글자 색 = 펜 색 칸
            ForEach(0..<tools.penColors.count, id: \.self) { index in
                Button { withAnimation(spring) { tools.penColorIndex = index } } label: {
                    Circle().fill(tools.penColors[index].color).frame(width: 18, height: 18)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
                        .padding(5)
                        .overlay {
                            if index == tools.penColorIndex { Circle().strokeBorder(themes.accent, lineWidth: 2) }
                        }
                        .frame(width: 30, height: 34)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("글자 색 \(index + 1)")
            }
        }
    }

    // MARK: 부품

    private func chip(_ title: String?, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(spring) { action() }
        } label: {
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
                Capsule().fill(selected ? AnyShapeStyle(themes.accent.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .padding(.horizontal, 1)
    }

    private var separator: some View {
        Capsule()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }
}

/// 누르는 동안 살짝 작아지는 버튼
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// 색 칸 하나의 색 고르기: 자주 쓰는 색 + 직접 고르기
struct ColorPalette: View {
    @Environment(ThemeStore.self) private var themes
    @Bindable var tools: InkToolState
    let index: Int

    private static let pen: [UInt32] = [
        0x1C1C1E, 0x5E5E63, 0x9A9AA0, 0x0A2A66, 0x1F5FD6, 0x32ADE6, 0x30B0C7, 0x2E7D32,
        0x34C759, 0xA2845E, 0xFFCC00, 0xFF9500, 0xD93025, 0xFF2D55, 0xAF52DE, 0x6E3FC3,
    ]
    private static let highlighter: [UInt32] = [
        0xFFD60A, 0xFFE57A, 0x7CE07C, 0xA8F0C6, 0x64D2FF, 0xA9DEFF, 0xFF8AC6, 0xFFB3D9,
        0xBF5AF2, 0xD7B4FF, 0xFF9F0A, 0xFFC680,
    ]

    private var isHighlighter: Bool { tools.inkTool == .highlighter }
    private var current: RGBAColor {
        let colors = tools.paletteColors
        return colors.indices.contains(index) ? colors[index] : RGBAColor(hex: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isHighlighter ? "형광펜 색" : "펜 색").font(.headline)
                Spacer()
                Text("칸 \(index + 1)").font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 8), spacing: 8) {
                ForEach(isHighlighter ? Self.highlighter : Self.pen, id: \.self) { hex in
                    let color = RGBAColor(hex: hex)
                    Button { apply(color) } label: {
                        Circle().fill(color.color).frame(width: 26, height: 26)
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
                            .overlay {
                                if same(color, current) { Circle().strokeBorder(themes.accent, lineWidth: 2.5).padding(-3) }
                            }
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            Divider()
            ColorPicker("직접 고르기", selection: Binding(get: { current.color }, set: { apply(RGBAColor($0)) }),
                        supportsOpacity: false)
                .font(.subheadline)
        }
    }

    private func apply(_ color: RGBAColor) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if isHighlighter {
                tools.highlighterColors[index] = color
                tools.highlighterColorIndex = index
            } else {
                tools.penColors[index] = color
                tools.penColorIndex = index
            }
            if tools.tool != tools.inkTool { tools.tool = tools.inkTool }
        }
    }

    private func same(_ a: RGBAColor, _ b: RGBAColor) -> Bool {
        abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) < 0.02
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

/// 아래 가운데: 제목 · 쪽수 · 저장 상태 (누르면 페이지 이동). 책 보기면 양옆에 ‹ ›
struct StatusCapsule: View {
    @Environment(ThemeStore.self) private var themes
    let title: String
    let page: Int
    let pageCount: Int
    let saveState: NoteDocument.SaveState
    var isBook = false
    var canBack = false
    var canForward = false
    var onTurn: (Int) -> Void = { _ in }
    let onTap: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if isBook {
                    turnButton(-1, "chevron.backward", enabled: canBack)
                        .transition(.scale.combined(with: .opacity))
                }
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if pageCount > 0 {
                            Text("\(page + 1) / \(pageCount)쪽")
                                .font(.subheadline)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(page)))
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
                .buttonStyle(PressScaleStyle())
                .glassEffect(themes.glass.interactive(), in: .capsule)
                .accessibilityHint("눌러서 페이지 이동")
                if isBook {
                    turnButton(1, "chevron.forward", enabled: canForward)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: page)
        .animation(.easeInOut(duration: 0.2), value: saveState)
    }

    private func turnButton(_ delta: Int, _ systemImage: String, enabled: Bool) -> some View {
        Button { onTurn(delta) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .glassEffect(themes.glass.interactive(), in: .circle)
        .accessibilityLabel(delta > 0 ? "다음 쪽" : "앞 쪽")
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
