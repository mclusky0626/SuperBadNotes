//
//  NewNotebookSheet.swift
//  BadNotes
//
//  새로운 노트북: 왼쪽 위 [표지] [종이] 미리보기를 눌러 아래 격자를 바꿈.
//  오른쪽: 이름, 표지 켜기, 크기, 종이 색. 아래: 종이 템플릿 또는 표지 고르기.
//  만들면 Documents(지금 폴더)에 PDF로 생기고 바로 열림.
//

import SwiftUI

struct NewNotebookSheet: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.dismiss) private var dismiss

    let folder: URL
    let onCreated: (URL) -> Void

    @State private var name = ""
    @State private var hasCover = true
    @State private var cover: CoverStyle = .navy
    @State private var template: PaperSpec.Template = .ruledWide
    @State private var tone: PaperSpec.Tone = .yellow
    @State private var size: PaperSpec.Size = .a4Portrait
    @State private var part: Part = .paper

    enum Part {
        case cover, paper
    }

    private var paper: PaperSpec { PaperSpec(template: template, tone: tone, size: size) }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "이름 없는 노트북" : trimmed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top, spacing: 16) {
                        partTile(.cover)
                        partTile(.paper)
                        settings
                            .frame(maxWidth: .infinity)
                    }
                    Divider()
                    if part == .cover { covers } else { papers }
                }
                .padding(24)
            }
            .navigationTitle("새로운 노트북")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("취소")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { create() } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("만들기")
                }
            }
        }
        .presentationSizing(.page)
    }

    // MARK: 위쪽

    private func partTile(_ which: Part) -> some View {
        let selected = part == which
        let height: CGFloat = 190
        return Button {
            withAnimation(.smooth(duration: 0.2)) { part = which }
        } label: {
            VStack(spacing: 8) {
                Text(which == .cover ? "표지" : "종이")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Group {
                    if which == .paper {
                        Image(uiImage: PaperPreviews.paper(paper, height: height))
                    } else if hasCover {
                        Image(uiImage: PaperPreviews.cover(cover, title: displayName, page: paper.pageSize, height: height))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: height * paper.pageSize.width / paper.pageSize.height, height: height)
                            .overlay { Text("표지 없음").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                Text(which == .cover ? (hasCover ? cover.title : "없음") : template.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: 170)
                Capsule()
                    .fill(selected ? themes.accent : Color.clear)
                    .frame(width: 40, height: 3)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.06) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settings: some View {
        VStack(spacing: 0) {
            row {
                Text("이름")
                TextField("이름 없는 노트북", text: $name)
                    .multilineTextAlignment(.trailing)
            }
            Divider()
            row { Toggle("표지", isOn: $hasCover) }
            Divider()
            row {
                Text("크기")
                Spacer()
                Picker("크기", selection: $size) {
                    ForEach(PaperSpec.Size.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Divider()
            row {
                Text("종이 색")
                Spacer()
                Picker("종이 색", selection: $tone) {
                    ForEach(PaperSpec.Tone.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }
            .frame(minHeight: 52)
    }

    // MARK: 아래 격자

    private var papers: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("종이 템플릿")
                .font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 24) {
                ForEach(PaperSpec.Template.allCases) { item in
                    VStack(spacing: 8) {
                        Button { template = item } label: {
                            Image(uiImage: PaperPreviews.paper(PaperSpec(template: item, tone: tone, size: size), height: 170))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                                .overlay(alignment: .bottomTrailing) {
                                    if template == item { checkmark }
                                }
                        }
                        .buttonStyle(.plain)
                        Text(item.title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        HStack(spacing: 8) {
                            ForEach(PaperSpec.Tone.allCases) { option in
                                Button {
                                    tone = option
                                    template = item
                                } label: {
                                    Circle()
                                        .fill(Color(uiColor: option.paper))
                                        .frame(width: 16, height: 16)
                                        .overlay {
                                            Circle().strokeBorder(tone == option && template == item ? themes.accent : Color.primary.opacity(0.25),
                                                                  lineWidth: tone == option && template == item ? 2 : 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.title)
                            }
                        }
                    }
                }
            }
        }
    }

    private var covers: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("표지")
                    .font(.title2.bold())
                Spacer()
                Toggle("표지 넣기", isOn: $hasCover)
                    .fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 18)], spacing: 24) {
                ForEach(CoverStyle.allCases) { style in
                    Button {
                        cover = style
                        hasCover = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(uiImage: PaperPreviews.cover(style, title: displayName, page: paper.pageSize, height: 160))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
                                .overlay(alignment: .bottomTrailing) {
                                    if hasCover && cover == style { checkmark }
                                }
                            Text(style.title)
                                .font(.subheadline)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, themes.accent)
            .padding(8)
    }

    // MARK: 만들기

    private func create() {
        do {
            let url = try LibraryStore.shared.createNotebook(name: name, cover: hasCover ? cover : nil,
                                                             paper: paper, in: folder)
            dismiss()
            onCreated(url)
        } catch {
            Log.error("노트북 만들기 실패: \(error.localizedDescription)")
        }
    }
}
