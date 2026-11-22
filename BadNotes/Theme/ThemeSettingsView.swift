//
//  ThemeSettingsView.swift
//  BadNotes
//
//  테마 설정. 넓은 화면에서는 왼쪽 옵션 / 오른쪽 실시간 미리보기, 좁으면 위아래.
//  1) 바탕: 내 사진(기본 레이어) 또는 단색·그라데이션
//  2) 그 위 Liquid Glass 레이어: 켜기, 재질, 색
//  바꾸는 즉시 앱 전체와 미리보기에 반영됨.
//

import SwiftUI
import PhotosUI

struct ThemeSettingsView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var newThemeName = ""

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if geo.size.width > 760 {
                    HStack(spacing: 0) {
                        options
                            .frame(width: min(420, geo.size.width * 0.46))
                        ThemePreview()
                            .padding(20)
                    }
                } else {
                    VStack(spacing: 0) {
                        ThemePreview()
                            .frame(height: max(260, geo.size.height * 0.38))
                            .padding(16)
                        options
                    }
                }
            }
            .navigationTitle("테마")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .presentationSizing(.page)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.setPhoto(data)
                } else {
                    Log.error("사진을 불러오지 못함")
                }
                photoItem = nil
            }
        }
    }

    // MARK: 옵션

    private var options: some View {
        @Bindable var store = store
        return Form {
            Section {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack(spacing: 14) {
                        Color.clear
                            .frame(width: 64, height: 64)
                            .overlay {
                                if let photo = store.photo {
                                    // 꽉 채운 사진이 틀 밖으로 넘쳐도 터치는 틀 안에서만
                                    Image(uiImage: photo).resizable().scaledToFill().allowsHitTesting(false)
                                } else {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.title2)
                                        .foregroundStyle(store.accent)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(Color.primary.opacity(0.06))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.photo == nil ? "바탕 이미지 고르기" : "다른 이미지로 바꾸기")
                                .font(.body.weight(.semibold))
                            Text("고른 이미지가 맨 아래 깔리고 그 위에 유리가 씌워져요")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("바탕", selection: $store.theme.base) {
                    ForEach(Theme.Base.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch store.theme.base {
                case .photo:
                    LabeledSlider(title: "흐리게", value: $store.theme.photoBlur, range: 0...30)
                    LabeledSlider(title: "어둡게", value: $store.theme.photoDim, range: 0...0.6)
                case .color:
                    ColorPicker("색", selection: colorBinding(0), supportsOpacity: false)
                case .gradient:
                    ColorPicker("위쪽 색", selection: colorBinding(0), supportsOpacity: false)
                    ColorPicker("아래쪽 색", selection: colorBinding(1), supportsOpacity: false)
                }
            } header: {
                Text("바탕")
            }

            Section {
                Toggle("바탕 위에 유리 씌우기", isOn: $store.theme.glassLayer)
                Picker("재질", selection: $store.theme.glassStyle) {
                    ForEach(Theme.GlassStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ColorPicker("유리 색", selection: Binding(
                    get: { store.theme.glassTint.color },
                    set: { store.theme.glassTint = RGBAColor($0) }
                ), supportsOpacity: false)
                LabeledSlider(title: "색 진하기", value: $store.theme.glassTintStrength, range: 0...0.6)
                Toggle("기울이면 바탕이 따라 움직임", isOn: $store.theme.parallax)
            } header: {
                Text("Liquid Glass")
            } footer: {
                Text("재질과 색은 바탕 유리, 버튼, 막대, 카드에 모두 똑같이 들어가요.")
            }

            Section("프리셋") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Theme.presets) { preset in
                            PresetChip(theme: preset, selected: store.theme.id == preset.id) {
                                store.apply(preset)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("강조색") {
                ColorPicker("강조색", selection: Binding(
                    get: { store.theme.accent.color },
                    set: { store.theme.accent = RGBAColor($0) }
                ), supportsOpacity: false)
            }

            Section("문서 카드") {
                Picker("모양", selection: $store.theme.cardStyle) {
                    ForEach(Theme.CardStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "크기", value: $store.theme.cardSize, range: 0.8...1.3)
            }

            Section("편집기 배경") {
                Picker("편집기 배경", selection: $store.theme.editorBackground) {
                    ForEach(Theme.EditorBackground.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("화면 모드") {
                Picker("화면 모드", selection: $store.theme.appearance) {
                    ForEach(Theme.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("내 테마") {
                HStack {
                    TextField("이름", text: $newThemeName)
                    Button("지금 테마 저장") {
                        store.saveCurrent(named: newThemeName)
                        newThemeName = ""
                    }
                }
                ForEach(store.myThemes) { theme in
                    Button {
                        store.apply(theme)
                    } label: {
                        HStack(spacing: 12) {
                            ThemeSwatch(theme: theme)
                                .frame(width: 34, height: 34)
                            Text(theme.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if store.theme.id == theme.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(store.accent)
                            }
                        }
                    }
                }
                .onDelete { store.deleteMine(at: $0) }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { store.theme.baseColors[index] },
            set: { newValue in
                var colors = store.theme.colors
                while colors.count < 2 { colors.append(colors.last ?? RGBAColor(hex: 0xCCCCCC)) }
                colors[index] = RGBAColor(newValue)
                store.theme.colors = colors
            }
        )
    }
}

/// 실시간 미리보기: 바탕 + 유리 레이어 + 유리 버튼 + 문서 카드
struct ThemePreview: View {
    @Environment(ThemeStore.self) private var store

    private let samples: [(String, String, [Color])] = [
        ("통합과학", "오늘 오후 2:03", [Color(red: 0.36, green: 0.42, blue: 0.75), Color(red: 0.55, green: 0.45, blue: 0.8)]),
        ("화학", "어제 오후 8:05", [Color(red: 0.96, green: 0.96, blue: 0.95), Color(red: 0.86, green: 0.87, blue: 0.9)]),
        ("물리", "어제 오후 5:07", [Color(red: 0.85, green: 0.35, blue: 0.25), Color(red: 0.95, green: 0.6, blue: 0.35)]),
        ("영어 학습지", "11월 16일", [Color(red: 0.15, green: 0.35, blue: 0.7), Color(red: 0.35, green: 0.6, blue: 0.85)]),
        ("국어", "11월 16일", [Color(red: 0.2, green: 0.5, blue: 0.45), Color(red: 0.55, green: 0.7, blue: 0.4)]),
        ("수학", "11월 8일", [Color(red: 0.3, green: 0.28, blue: 0.4), Color(red: 0.5, green: 0.4, blue: 0.55)]),
    ]

    var body: some View {
        ZStack {
            ThemeBackground(theme: store.theme, photo: store.photo, allowMotion: false)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            GlassIconButton(systemImage: "paintpalette", label: "테마", size: 38) {}
                            GlassIconButton(systemImage: "gearshape", label: "설정", size: 38) {}
                        }
                    }
                    Spacer()
                    Button {} label: {
                        Label("신규", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                }
                Text("문서")
                    .font(.largeTitle.bold())
                ScrollView {
                    let width = 104 * store.theme.cardSize
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: width + 24), spacing: 14)], spacing: 18) {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                            VStack(spacing: 6) {
                                CoverFrame(image: nil, placeholder: sample.2, style: store.theme.cardStyle,
                                           box: CGSize(width: width, height: width * 1.32))
                                Text(sample.0).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(sample.1).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        // 보여 주기만 하는 화면. 안의 가짜 버튼이 옆 옵션 터치를 가로채지 않게
        .allowsHitTesting(false)
    }
}

/// 프리셋 고르는 칩
private struct PresetChip: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ThemeSwatch(theme: theme)
                    .frame(width: 64, height: 64)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selected ? theme.accent.color : Color.primary.opacity(0.12),
                                          lineWidth: selected ? 3 : 1)
                    }
                Text(theme.name)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 테마 바탕 색을 작게 보여 주는 네모
struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        let colors = theme.baseColors
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.base == .color
                  ? AnyShapeStyle(colors[0])
                  : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(theme.accent.color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .padding(6)
            }
    }
}

/// 이름 + 슬라이더
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
        }
    }
}
