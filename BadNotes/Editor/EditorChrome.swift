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
    let isBoard: Bool
    let unreadErrors: Int
    let onClose: () -> Void
    let onAddPage: () -> Void
    let onPickPhoto: () -> Void
    let onPickFile: () -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void
    let onLog: () -> Void
    @State private var settings = AppSettings.shared
    @Namespace private var selection

    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.8)

    /// 위 막대에 보이는 도구. Apple 도구 모드는 필기를 Apple 팔레트가 맡아서 놓는 도구만
    private var shownTools: [[InkToolState.Tool]] {
        mode == .direct ? [[.lasso, .pen, .highlighter, .eraser], [.text, .sticky, .image]] : [[.text, .sticky, .image]]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // 넓은 창에서는 도구·실행 취소·옵션이 한 줄을 함께 쓴다.
            HStack(spacing: 6) {
                topBar
                undoPill
                if showsOptions { optionsBar.fixedSize(horizontal: true, vertical: false) }
            }
            VStack(spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    topBar
                    ScrollView(.horizontal, showsIndicators: false) { topBar.fixedSize() }
                }
                HStack(spacing: 6) {
                    undoPill
                    if showsOptions {
                        ViewThatFits(in: .horizontal) {
                            optionsBar
                            ScrollView(.horizontal, showsIndicators: false) { optionsBar.fixedSize() }
                                .scrollClipDisabled()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .animation(spring, value: optionsID)
    }

    private var showsOptions: Bool { mode == .direct || tools.tool.places }

    private var optionsBar: some View {
        ToolOptionsBar(tools: tools, bridge: bridge, onPickPhoto: onPickPhoto, onPickFile: onPickFile)
    }

    private var optionsID: String {
        switch tools.tool {
        case .pen, .highlighter: "\(tools.tool.rawValue)-\(tools.inkTool.rawValue)"
        default: tools.tool.rawValue
        }
    }

    // MARK: 위 막대

    private var topBar: some View {
        HStack(spacing: 6) {
            barButton("chevron.backward", label: "서재로", action: onClose)
            if !isBoard {
                barButton("number", label: "페이지 이동") { bridge.requestJump() }
            }
            Spacer(minLength: 8)
            ForEach(Array(shownTools.enumerated()), id: \.offset) { group, items in
                if group > 0 { divider }
                ForEach(items) { tool in toolButton(tool) }
            }
            if mode != .direct {
                Text("필기: Apple 도구")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 8)
            if !isBoard {
                barButton("doc.badge.plus", label: "페이지 추가", action: onAddPage)
            }
            if unreadErrors > 0 {
                barButton("exclamationmark.triangle.fill", label: "로그", tint: .red, action: onLog)
                    .transition(.scale.combined(with: .opacity))
            }
            moreMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .glassEffect(themes.glass, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func toolButton(_ tool: InkToolState.Tool) -> some View {
        let selected = tools.tool == tool
        let icon = tool == .pen ? tools.penStyle.icon : (tool == .eraser ? tools.eraserMode.icon : tool.icon)
        return Button {
            withAnimation(spring) { tools.tool = tool }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .symbolEffect(.bounce, value: selected)
                .frame(width: 44, height: 40)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(themes.accent.gradient)
                            .shadow(color: themes.accent.opacity(0.35), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "tool", in: selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(tool.title)
    }

    private func barButton(_ systemImage: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    private var moreMenu: some View {
        Menu {
            if !isBoard {
                Section("페이지 보기") {
                    Toggle(isOn: $settings.pageTurn) { Label("책처럼 넘기기", systemImage: "book.pages") }
                        .disabled(mode != .direct)
                    Toggle(isOn: $settings.twoUpLandscape) { Label("가로 화면에서 두 쪽", systemImage: "rectangle.split.2x1") }
                }
            }
            Button("도구 막대 숨기기", systemImage: "rectangle.compress.vertical") { bridge.chromeHidden = true }
            Button("테마", systemImage: "paintpalette", action: onTheme)
            Button("설정", systemImage: "gearshape", action: onSettings)
            Button("로그", systemImage: "ladybug", action: onLog)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("더 보기")
    }

    private var divider: some View {
        Capsule().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 24).padding(.horizontal, 6)
    }

    // MARK: 실행 취소 묶음

    private var undoPill: some View {
        HStack(spacing: 0) {
            Button(action: bridge.undo) {
                Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .disabled(!bridge.canUndo)
            .accessibilityLabel("실행 취소")
            Button(action: bridge.redo) {
                Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .disabled(!bridge.canRedo)
            .accessibilityLabel("다시 실행")
        }
        .font(.system(size: 16, weight: .semibold))
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 4)
        .glassEffect(themes.glass, in: .capsule)
    }
}

/// 위 막대 아래 가운데: 고른 도구의 설정 (굿노트처럼 도구마다 한 줄)
struct ToolOptionsBar: View {
    @Environment(ThemeStore.self) private var themes
    @Bindable var tools: InkToolState
    let bridge: EditorBridge
    let onPickPhoto: () -> Void
    let onPickFile: () -> Void
    @State private var settings = AppSettings.shared

    @State private var sizeEditor: Int?
    @State private var colorEditor: Int?
    @State private var textColorEditor = false
    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        HStack(spacing: 4) {
            switch tools.tool {
            case .pen: penBar
            case .highlighter: highlighterBar
            case .eraser: eraserBar
            case .lasso: lassoBar
            case .text: textBar
            case .sticky: stickyBar
            case .image: imageBar
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .glassEffect(themes.glass, in: .capsule)
    }

    // MARK: 펜

    private var penBar: some View {
        Group {
            Menu {
                Picker("펜 종류", selection: $tools.penStyle) {
                    ForEach(InkToolState.PenStyle.allCases) { style in
                        Label(style.title, systemImage: style.icon).tag(style)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: tools.penStyle.icon).font(.system(size: 17, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(themes.accent.opacity(0.15)))
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("펜 종류: \(tools.penStyle.title)")
            if tools.penStyle == .glass {
                GlassStrengthButton(title: "유리 진하기", value: $tools.glassPenStrength, tint: tools.currentColor)
                    .transition(.scale.combined(with: .opacity))
            }
            separator
            widthChoices
            separator
            colorChoices
        }
    }

    private var highlighterBar: some View {
        Group {
            toggleChip(nil, systemImage: "ruler", on: settings.straightHighlighter) { settings.straightHighlighter.toggle() }
                .accessibilityLabel("곧게 긋기")
            separator
            widthChoices
            separator
            colorChoices
        }
    }

    private var eraserBar: some View {
        Group {
            segmented(InkToolState.EraserMode.allCases.map { ($0, $0.shortTitle, $0.icon) }, selection: tools.eraserMode) {
                tools.eraserMode = $0
            }
            separator
            widthChoices
            separator
            toggleChip("형광펜만", systemImage: "highlighter", on: tools.eraserHighlighterOnly) {
                tools.eraserHighlighterOnly.toggle()
            }
        }
    }

    private var lassoBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lasso").foregroundStyle(themes.accent)
            Text("감싸서 고르면 옮기기·복제·색 바꾸기 · 상자는 톡 눌러 고르기")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    // MARK: 굵기 · 색 (펜·형광펜·지우개)

    /// 굵기 3칸: 실제 굵기만큼 두꺼운 선. 고른 칸을 한 번 더 누르면 슬라이더
    private var widthChoices: some View {
        ForEach(Array(tools.sizeOptions.enumerated()), id: \.offset) { index, value in
            let selected = index == tools.sizeIndex
            Button {
                if selected { sizeEditor = index } else { withAnimation(spring) { tools.selectSize(index) } }
            } label: {
                widthGlyph(value)
                    .frame(width: 40, height: 36)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.1))
                                .transition(.opacity)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .popover(isPresented: Binding(get: { sizeEditor == index }, set: { if !$0 { sizeEditor = nil } }), arrowEdge: .top) {
                SizeEditor(tools: tools, index: index)
                    .padding(18)
                    .frame(width: 300)
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(tools.tool == .eraser ? "지우개 크기 \(index + 1)" : "굵기 \(index + 1)")
            .accessibilityHint("한 번 더 누르면 굵기 조절")
        }
    }

    @ViewBuilder
    private func widthGlyph(_ value: CGFloat) -> some View {
        let range = tools.sizeRange
        let t = sqrt(max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound))))
        if tools.tool == .eraser {
            Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5).frame(width: 8 + 16 * t, height: 8 + 16 * t)
        } else {
            Capsule().fill(Color.primary.opacity(0.85)).frame(width: 22, height: 1.5 + 9 * t)
        }
    }

    /// 색 3칸 + (+) 고르기. 고른 칸을 한 번 더 눌러도 색 고르기
    private var colorChoices: some View {
        Group {
            ForEach(0..<tools.paletteColors.count, id: \.self) { index in
                let color = tools.paletteColors[index]
                let selected = index == tools.paletteColorIndex && tools.tool == tools.inkTool
                Button {
                    if selected { colorEditor = index } else { withAnimation(spring) { tools.selectColor(index) } }
                } label: {
                    swatch(color.color, selected: selected)
                }
                .buttonStyle(PressScaleStyle())
                .popover(isPresented: Binding(get: { colorEditor == index }, set: { if !$0 { colorEditor = nil } }), arrowEdge: .top) {
                    ColorPalette(tools: tools, index: index)
                        .padding(18)
                        .frame(width: 320)
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("색 \(index + 1)")
            }
            Button { colorEditor = tools.paletteColorIndex } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .overlay { Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).foregroundStyle(.secondary) }
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("색 고르기")
        }
    }

    private func swatch(_ color: Color, selected: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 24, height: 24)
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
            .padding(4)
            .overlay {
                if selected {
                    Circle().strokeBorder(themes.accent, lineWidth: 2.5).transition(.scale(scale: 1.3).combined(with: .opacity))
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
    }

    // MARK: 텍스트: 색 · 크기 · 글꼴 · 굵게 · 정렬 · 바탕(Liquid Glass)

    private var textBar: some View {
        Group {
            Button { textColorEditor = true } label: { swatch(tools.textColor.color, selected: false) }
                .buttonStyle(PressScaleStyle())
                .popover(isPresented: $textColorEditor, arrowEdge: .top) {
                    SimpleColorGrid(selection: Binding(get: { tools.textColor }, set: { tools.textColor = $0; bridge.restyle() }))
                        .padding(18)
                        .frame(width: 320)
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("글자 색")
            dropdown("\(Int(tools.textSize))") {
                Picker("글자 크기", selection: Binding(get: { tools.textSize }, set: { tools.textSize = $0; bridge.restyle() })) {
                    ForEach([12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64] as [CGFloat], id: \.self) { Text("\(Int($0))").tag($0) }
                }
            }
            .accessibilityLabel("글자 크기")
            dropdown(TextFonts.title(tools.textFont), font: Font(TextFonts.font(tools.textFont, size: 15, bold: false))) {
                Picker("글꼴", selection: Binding(get: { tools.textFont }, set: { tools.textFont = $0; bridge.restyle() })) {
                    ForEach(TextFonts.available) { option in Text(option.title).tag(option.id) }
                }
            }
            .accessibilityLabel("글꼴")
            toggleChip(nil, systemImage: "bold", on: tools.textBold) { tools.textBold.toggle(); bridge.restyle() }
                .accessibilityLabel("굵게")
            // 글자 자체를 Liquid Glass로
            toggleChip("유리 글자", systemImage: "drop.halffull", on: tools.textGlass) { tools.textGlass.toggle(); bridge.restyle() }
            if tools.textGlass {
                GlassStrengthButton(title: "유리 글자 진하기",
                                    value: Binding(get: { tools.textGlassStrength },
                                                   set: { tools.textGlassStrength = $0; bridge.restyle() }),
                                    tint: tools.textColor, sample: "가A")
                    .transition(.scale.combined(with: .opacity))
            }
            Menu {
                Picker("정렬", selection: Binding(get: { tools.textAlignment }, set: { tools.textAlignment = $0; bridge.restyle() })) {
                    Label("왼쪽", systemImage: "text.alignleft").tag(0)
                    Label("가운데", systemImage: "text.aligncenter").tag(1)
                    Label("오른쪽", systemImage: "text.alignright").tag(2)
                }
            } label: {
                Image(systemName: ["text.alignleft", "text.aligncenter", "text.alignright"][min(max(tools.textAlignment, 0), 2)])
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("정렬")
            separator
            segmented(PageElement.Fill.allCases.map { ($0, $0 == .glass ? "Liquid Glass" : $0.shortTitle, $0.icon) },
                      selection: tools.textFill) {
                tools.textFill = $0
                bridge.restyle()
            }
            if tools.textFill == .glass {
                toggleChip("맑게", systemImage: "drop", on: tools.textGlassClear) {
                    tools.textGlassClear.toggle()
                    bridge.restyle()
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(spring, value: tools.textFill)
    }

    // MARK: 메모지: 색 + Liquid Glass

    private var stickyBar: some View {
        Group {
            ForEach(PageElement.stickyColors, id: \.0) { name, color in
                let selected = sameColor(color, tools.stickyColor)
                Button {
                    withAnimation(spring) { tools.stickyColor = color }
                    bridge.restyle()
                } label: {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color.color)
                        .frame(width: 26, height: 26)
                        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)) }
                        .padding(4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.12))
                            }
                        }
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("메모지 \(name)")
            }
            separator
            toggleChip("Liquid Glass", systemImage: "drop.halffull", on: tools.stickyGlass) {
                tools.stickyGlass.toggle()
                bridge.restyle()
            }
            .accessibilityLabel("유리 메모지")
            if tools.stickyGlass {
                toggleChip("맑게", systemImage: "drop", on: tools.stickyGlassClear) {
                    tools.stickyGlassClear.toggle()
                    bridge.restyle()
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(spring, value: tools.stickyGlass)
    }

    // MARK: 이미지

    private var imageBar: some View {
        Group {
            Button(action: onPickPhoto) { Label("사진 보관함", systemImage: "photo.on.rectangle") }
            Button(action: onPickFile) { Label("파일", systemImage: "folder") }
            separator
            Text("페이지를 누르면 그 자리에 넣어요")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 4)
    }

    // MARK: 부품

    private func dropdown<Content: View>(_ title: String, font: Font = .subheadline.weight(.semibold),
                                         @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Text(title).font(font).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
        .menuIndicator(.hidden)
    }

    private func segmented<Value: Hashable>(_ items: [(Value, String, String)], selection: Value,
                                            action: @escaping (Value) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title, icon in
                let selected = value == selection
                Button {
                    withAnimation(spring) { action(value) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                        Text(title).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background {
                        if selected { Capsule().fill(themes.accent.gradient) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func toggleChip(_ title: String?, systemImage: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(spring) { action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, title == nil ? 10 : 11)
            .frame(height: 32)
            .background {
                Capsule().fill(on ? AnyShapeStyle(themes.accent.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var separator: some View {
        Capsule().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 22).padding(.horizontal, 5)
    }

    private func sameColor(_ a: RGBAColor, _ b: RGBAColor) -> Bool {
        abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) < 0.02
    }
}

/// 유리 진하기(투명도) 고르기: 막대에는 % 칩, 누르면 미리보기 + 슬라이더
struct GlassStrengthButton: View {
    @Environment(ThemeStore.self) private var themes
    let title: String
    @Binding var value: Double
    let tint: RGBAColor
    var sample: String? = nil
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "drop.halffull").font(.system(size: 12, weight: .semibold))
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.headline)
                Image(uiImage: GlassPreview.image(tint: tint, strength: value, sample: sample))
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.97)))
                HStack {
                    Text("투명").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $value, in: 0...1)
                    Text("진하게").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach([("투명", 0.1), ("맑게", 0.25), ("보통", 0.4), ("진하게", 0.65)], id: \.0) { name, preset in
                        Button(name) { withAnimation { value = preset } }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .tint(abs(value - preset) < 0.02 ? themes.accent : .secondary)
                    }
                }
            }
            .padding(18)
            .frame(width: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// 유리 미리보기 그림 (줄 친 종이 위에 유리 획 또는 유리 글자)
enum GlassPreview {
    static func image(tint: RGBAColor, strength: Double, sample: String?) -> UIImage {
        let size = CGSize(width: 284, height: 84)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            UIColor(white: 0.98, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setStrokeColor(UIColor(red: 0.75, green: 0.8, blue: 0.9, alpha: 1).cgColor)
            cg.setLineWidth(1)
            for y in stride(from: 14.0, to: size.height, by: 14) {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: size.width, y: y))
            }
            cg.strokePath()
            let outline: CGPath
            let thickness: CGFloat
            if let sample {
                let font = UIFont.systemFont(ofSize: 56, weight: .heavy)
                outline = GlyphOutline.path(text: sample, attributes: [.font: font], in: CGRect(x: 20, y: 6, width: 260, height: 80))
                thickness = 5
            } else {
                let line = CGMutablePath()
                line.move(to: CGPoint(x: 24, y: 52))
                line.addCurve(to: CGPoint(x: 260, y: 36), control1: CGPoint(x: 100, y: 0), control2: CGPoint(x: 170, y: 90))
                thickness = 14
                outline = GlassInk.outline(centerline: line, width: thickness)
            }
            GlassInk.draw(outline: outline, tint: tint.uiColor.withAlphaComponent(1).cgColor, strength: CGFloat(strength),
                          thickness: thickness, forPDF: false, in: cg)
        }
    }
}

/// 색 하나 고르기 (글자 색 등): 자주 쓰는 색 + 직접 고르기
struct SimpleColorGrid: View {
    @Environment(ThemeStore.self) private var themes
    @Binding var selection: RGBAColor

    private static let colors: [UInt32] = [
        0x1C1C1E, 0x5E5E63, 0x9A9AA0, 0xFFFFFF, 0x0A2A66, 0x1F5FD6, 0x32ADE6, 0x30B0C7,
        0x2E7D32, 0x34C759, 0xA2845E, 0xFFCC00, 0xFF9500, 0xD93025, 0xFF2D55, 0xAF52DE,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("글자 색").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 8), spacing: 8) {
                ForEach(Self.colors, id: \.self) { hex in
                    let color = RGBAColor(hex: hex)
                    Button { selection = color } label: {
                        Circle().fill(color.color).frame(width: 26, height: 26)
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
                            .overlay {
                                if abs(color.r - selection.r) + abs(color.g - selection.g) + abs(color.b - selection.b) < 0.02 {
                                    Circle().strokeBorder(themes.accent, lineWidth: 2.5).padding(-3)
                                }
                            }
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            Divider()
            ColorPicker("직접 고르기", selection: Binding(get: { selection.color }, set: { selection = RGBAColor($0) }),
                        supportsOpacity: false)
                .font(.subheadline)
        }
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
            var builder = tools.makeStrokeBuilder(startTime: 0, width: width, salt: 17)
            for i in 0...60 {
                let t = CGFloat(i) / 60
                let x = 18 + (size.width - 36) * t
                let amplitude = tools.inkTool == .highlighter ? 0 : max(0, (size.height - width * 2.8) / 2 - 5)
                let y = size.height / 2 + sin(t * .pi * 2) * amplitude
                builder.add(InputSample(location: CGPoint(x: x, y: y), time: Double(i) / 120,
                                        force: 0.06 + 0.62 * sin(t * .pi), azimuth: .pi * 0.75,
                                        altitude: .pi / 2 - sin(t * .pi) * 0.85))
            }
            if let stroke = builder.makeStroke() {
                let sampled = InkRenderer.sample(stroke)
                context.withCGContext { InkRenderer.draw(sampled, in: $0, smooth: true) }
            }
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
