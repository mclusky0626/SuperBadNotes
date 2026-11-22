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
    @Bindable var tools: InkToolState
    let bridge: EditorBridge
    let mode: AppSettings.EditMode
    let unreadErrors: Int
    let onClose: () -> Void
    let onAddPage: () -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void
    let onLog: () -> Void

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
                    if showsInkTools {
                        GlassIconButton(systemImage: "arrow.uturn.backward", label: "실행 취소", size: 40, action: bridge.undo)
                            .disabled(!bridge.canUndo)
                        GlassIconButton(systemImage: "arrow.uturn.forward", label: "다시 실행", size: 40, action: bridge.redo)
                            .disabled(!bridge.canRedo)
                    }
                    GlassIconButton(systemImage: "doc.badge.plus", label: "페이지 추가", size: 40, action: onAddPage)
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
}

/// 펜·형광펜·지우개·올가미 + 색 + 굵기. compact면 색은 고르기 창 하나, 굵기는 메뉴로
struct ToolPalette: View {
    @Environment(ThemeStore.self) private var themes
    @Bindable var tools: InkToolState
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Picker("펜 종류", selection: $tools.penStyle) {
                    ForEach(InkToolState.PenStyle.allCases) { style in
                        Label(style.title, systemImage: style.icon).tag(style)
                    }
                }
            } label: {
                toolIcon(.pen, systemImage: tools.penStyle.icon)
            } primaryAction: {
                tools.tool = .pen
            }
            .menuIndicator(.hidden)

            Button { tools.tool = .highlighter } label: {
                toolIcon(.highlighter, systemImage: InkToolState.Tool.highlighter.icon)
            }
            .buttonStyle(.plain)

            Menu {
                Picker("지우개", selection: $tools.eraserMode) {
                    ForEach(InkToolState.EraserMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
            } label: {
                toolIcon(.eraser, systemImage: tools.eraserMode.icon)
            } primaryAction: {
                tools.tool = .eraser
            }
            .menuIndicator(.hidden)

            Button { tools.tool = .lasso } label: {
                toolIcon(.lasso, systemImage: InkToolState.Tool.lasso.icon)
            }
            .buttonStyle(.plain)

            separator

            if !compact {
                ForEach(Array(tools.paletteColors.enumerated()), id: \.offset) { index, color in
                    Button { tools.selectColor(index) } label: {
                        swatch(color, selected: index == tools.paletteColorIndex && tools.tool == tools.inkTool)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("색 \(index + 1)")
                }
            }
            ColorPicker("색 고르기", selection: Binding(
                get: { tools.currentColor.color },
                set: { tools.setCurrentSlotColor(RGBAColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 32, height: 32)

            separator

            if compact {
                Menu {
                    Picker(tools.tool == .eraser ? "지우개 크기" : "굵기",
                           selection: Binding(get: { tools.sizeIndex }, set: { tools.selectSize($0) })) {
                        ForEach(Array(tools.sizeOptions.enumerated()), id: \.offset) { index, _ in
                            Text(["가늘게", "보통", "굵게"][min(index, 2)]).tag(index)
                        }
                    }
                } label: {
                    sizeDot(tools.sizeIndex, selected: true)
                }
                .menuIndicator(.hidden)
            } else {
                ForEach(Array(tools.sizeOptions.enumerated()), id: \.offset) { index, _ in
                    Button { tools.selectSize(index) } label: {
                        sizeDot(index, selected: index == tools.sizeIndex)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tools.tool == .eraser ? "지우개 크기 \(index + 1)" : "굵기 \(index + 1)")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassEffect(themes.glass, in: .capsule)
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

    private func sizeDot(_ index: Int, selected: Bool) -> some View {
        let diameter: CGFloat = [7, 11, 16][min(index, 2)]
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
