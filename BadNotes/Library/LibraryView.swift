//
//  LibraryView.swift
//  BadNotes
//
//  첫 화면 = 서재. 왼쪽 사이드바(문서·즐겨찾기), 오른쪽 문서 카드 격자.
//  [+ 신규] → 노트북 / PDF 불러오기 / 폴더. 카드를 누르면 편집기로.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @State private var library = LibraryStore.shared
    @State private var section: Section? = .documents
    @State private var path: [URL] = []

    let onOpen: (URL) -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void

    enum Section: Hashable {
        case documents, favorites
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("문서", systemImage: "folder").tag(Section.documents)
                Label("즐겨찾기", systemImage: "star").tag(Section.favorites)
            }
            .navigationTitle("BadNotes")
            .scrollContentBackground(.hidden)
            .containerBackground(.clear, for: .navigationSplitView)
        } detail: {
            NavigationStack(path: $path) {
                LibraryFolderView(mode: section == .favorites ? .favorites : .folder(library.root),
                                  onOpen: onOpen, onTheme: onTheme, onSettings: onSettings)
                    .navigationDestination(for: URL.self) { folder in
                        LibraryFolderView(mode: .folder(folder), onOpen: onOpen, onTheme: onTheme, onSettings: onSettings)
                    }
            }
            .containerBackground(.clear, for: .navigationSplitView)
        }
        .onChange(of: section) { path = [] }
    }
}

/// 폴더 하나(또는 즐겨찾기)의 카드 격자
struct LibraryFolderView: View {
    enum Mode: Hashable {
        case folder(URL)
        case favorites
    }

    @Environment(ThemeStore.self) private var themes
    @State private var library = LibraryStore.shared

    let mode: Mode
    let onOpen: (URL) -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void

    @State private var items: [LibraryItem] = []
    @State private var loaded = false
    @State private var showNewMenu = false
    @State private var showNewNotebook = false
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: LibraryItem?
    @State private var renameText = ""
    @State private var deleting: LibraryItem?
    @State private var moving: LibraryItem?
    @State private var recovering: LibraryItem?

    private var folder: URL {
        if case .folder(let url) = mode { return url }
        return library.root
    }

    private var title: String {
        switch mode {
        case .favorites: "즐겨찾기"
        case .folder(let url): url.standardizedFileURL == library.root.standardizedFileURL ? "문서" : url.lastPathComponent
        }
    }

    var body: some View {
        let cardWidth = 128 * themes.theme.cardSize
        ScrollView {
            if loaded && items.isEmpty {
                emptyState
                    .padding(.top, 90)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth + 34, maximum: cardWidth + 70), spacing: 16)],
                      alignment: .center, spacing: 30) {
                ForEach(items) { item in
                    card(for: item)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .navigationTitle(title)
        .containerBackground(.clear, for: .navigation)
        .toolbar { toolbar }
        .task(id: library.revision) { await reload() }
        .sheet(isPresented: $showNewNotebook) {
            NewNotebookSheet(folder: folder) { url in onOpen(url) }
        }
        .sheet(item: $recovering) { item in
            ChangeCoverSheet(item: item) { style in
                act("표지 바꾸기") {
                    let inserted = try PDFInkWriter.replaceCover(of: item.url, with: style, title: item.name)
                    // 표지를 새로 넣었으면 보던 페이지가 한 장씩 밀림
                    if inserted, let page = ReadingPosition.page(for: item.url) { ReadingPosition.set(page + 1, for: item.url) }
                    Log.info("표지 바꿈: \(item.name) → \(style.title)")
                    library.changed()
                }
            }
        }
        .sheet(item: $moving) { item in
            MoveSheet(item: item) { destination in
                act("옮기기") { _ = try library.move(item, to: destination) }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            importPDFs(result)
        }
        .alert("새 폴더", isPresented: $showNewFolder) {
            TextField("이름", text: $newFolderName)
            Button("만들기") { act("폴더 만들기") { _ = try library.createFolder(named: newFolderName, in: folder) } }
            Button("취소", role: .cancel) {}
        }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $renameText)
            Button("바꾸기") {
                if let item = renaming { act("이름 바꾸기") { _ = try library.rename(item, to: renameText) } }
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("'\(deleting?.name ?? "")'을(를) 지울까요?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let item = deleting { act("삭제") { try library.delete(item) } }
            }
        } message: {
            Text("앱 안 보관함으로 옮겨요. 파일 앱에서는 사라져요.")
        }
        #if DEBUG
        .onAppear {
            if case .folder(let url) = mode, url == library.root,
               ProcessInfo.processInfo.arguments.contains("-BNShowNewNotebook") {
                showNewNotebook = true
            }
        }
        #endif
    }

    // MARK: 조각

    @ViewBuilder
    private func card(for item: LibraryItem) -> some View {
        let favorite = library.isFavorite(item.url)
        let content = LibraryCard(item: item, isFavorite: favorite,
                                  onFavorite: { library.toggleFavorite(item.url) },
                                  onRename: { renameText = item.name; renaming = item },
                                  onMove: { moving = item },
                                  onCover: { recovering = item },
                                  onDelete: { deleting = item })
        if item.isFolder {
            NavigationLink(value: item.url) { content }
                .buttonStyle(.plain)
        } else {
            content
                .onTapGesture { onOpen(item.url) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("정렬", selection: Binding(get: { library.sort }, set: { library.sort = $0 })) {
                    ForEach(LibraryStore.Sort.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label("정렬", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onTheme) { Label("테마", systemImage: "paintpalette") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onSettings) { Label("설정", systemImage: "gearshape") }
        }
        if case .folder = mode {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewMenu = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("신규")
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .accessibilityLabel("신규")
                .popover(isPresented: $showNewMenu, arrowEdge: .top) {
                    NewMenuView(onNotebook: { afterMenu { showNewNotebook = true } },
                                onImport: { afterMenu { showImporter = true } },
                                onFolder: { afterMenu { newFolderName = ""; showNewFolder = true } })
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: mode == .favorites ? "star" : "books.vertical")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(themes.accent)
            Text(mode == .favorites ? "즐겨찾기한 문서가 없어요" : "아직 문서가 없어요")
                .font(.title3.bold())
            if case .folder = mode {
                Text("[+ 신규]에서 노트북을 만들거나 PDF를 불러오세요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { showNewNotebook = true } label: { Label("노트북 만들기", systemImage: "book.closed") }
                        .buttonStyle(.glassProminent)
                    Button { showImporter = true } label: { Label("PDF 불러오기", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.glass)
                }
                .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: 460)
        .glassEffect(themes.glass, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    // MARK: 동작

    private func reload() async {
        switch mode {
        case .folder(let url): items = await library.items(in: url)
        case .favorites: items = await library.favoriteItems()
        }
        loaded = true
    }

    /// 팝오버가 닫힌 뒤에 다음 화면을 띄움 (동시에 띄우면 안 뜰 때가 있음)
    private func afterMenu(_ action: @escaping () -> Void) {
        showNewMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    private func act(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Log.error("\(name) 실패: \(error.localizedDescription)")
        }
    }

    private func importPDFs(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            Log.error("파일 선택 실패: \(error.localizedDescription)")
        case .success(let urls):
            var imported: [URL] = []
            for url in urls {
                act("PDF 불러오기") { imported.append(try library.importPDF(url, into: folder)) }
            }
            // 하나만 골랐으면 바로 엶
            if imported.count == 1, let only = imported.first { onOpen(only) }
        }
    }
}

/// 문서·폴더 카드: 표지 + 이름 ⌄ + 날짜. 표지 오른쪽 위 별 = 즐겨찾기
struct LibraryCard: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.displayScale) private var displayScale

    let item: LibraryItem
    let isFavorite: Bool
    let onFavorite: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onCover: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        let scale = themes.theme.cardSize
        let box = CGSize(width: 128 * scale, height: 168 * scale)
        VStack(spacing: 8) {
            Group {
                if item.isFolder {
                    FolderIcon(box: box)
                } else {
                    CoverFrame(image: thumbnail, placeholder: [Color.gray.opacity(0.35), Color.gray.opacity(0.15)],
                               style: themes.theme.cardStyle, box: box) {
                        Button(action: onFavorite) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isFavorite ? Color.yellow : Color.white)
                                .shadow(color: .black.opacity(0.45), radius: 2)
                                .padding(9)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isFavorite ? "즐겨찾기 해제" : "즐겨찾기")
                    }
                }
            }
            .frame(width: box.width, height: box.height, alignment: .bottom)

            HStack(spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Menu { menuItems } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("더 보기")
            }
            Text(item.isFolder ? "\(item.childCount)개 항목" : item.modified.libraryLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: box.width + 40)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        // 카드 크기를 키우면 그 크기에 맞게 다시 그림 (작은 그림을 늘리면 흐려짐). 64픽셀 단위로 묶어서 슬라이더 끌 때 덜 그림
        .task(id: ThumbnailRequest(modified: item.modified, pixels: (box.height * displayScale / 64).rounded(.up) * 64)) {
            guard !item.isFolder else { return }
            let pixels = (box.height * displayScale / 64).rounded(.up) * 64
            thumbnail = await ThumbnailCache.shared.image(for: item.url, modified: item.modified, maxPixel: pixels)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if !item.isFolder {
            Button(isFavorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: isFavorite ? "star.slash" : "star", action: onFavorite)
        }
        Button("이름 바꾸기", systemImage: "pencil", action: onRename)
        Button("옮기기", systemImage: "folder", action: onMove)
        if !item.isFolder {
            Button("표지 바꾸기", systemImage: "book.closed", action: onCover)
        }
        Divider()
        Button("삭제", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

/// 폴더 카드 그림
private struct ThumbnailRequest: Equatable {
    let modified: Date
    let pixels: CGFloat
}

struct FolderIcon: View {
    @Environment(ThemeStore.self) private var themes
    let box: CGSize

    var body: some View {
        Image(systemName: "folder.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(themes.accent.gradient)
            .frame(width: box.width * 1.15)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            .frame(width: box.width, height: box.height, alignment: .bottom)
    }
}

/// [+ 신규] 팝오버
struct NewMenuView: View {
    @Environment(ThemeStore.self) private var themes
    let onNotebook: () -> Void
    let onImport: () -> Void
    let onFolder: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                tile("노트북", systemImage: "book.closed", action: onNotebook)
                tile("PDF 불러오기", systemImage: "square.and.arrow.down", action: onImport)
            }
            Button(action: onFolder) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title3)
                        .foregroundStyle(themes.accent)
                    Text("폴더")
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 30))
                    .foregroundStyle(themes.accent)
                Text(title)
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 108)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 옮길 폴더 고르기
struct MoveSheet: View {
    let item: LibraryItem
    let onMove: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []

    var body: some View {
        NavigationStack {
            List(folders, id: \.self) { folder in
                let current = folder.standardizedFileURL == item.url.deletingLastPathComponent().standardizedFileURL
                let inside = item.isFolder && (folder.standardizedFileURL.path + "/").hasPrefix(item.url.standardizedFileURL.path + "/")
                Button {
                    onMove(folder)
                    dismiss()
                } label: {
                    Label(label(for: folder), systemImage: AppPaths.isInsideDocuments(folder) ? "folder" : "tray.full")
                }
                .disabled(current || inside)
            }
            .navigationTitle("'\(item.name)' 옮기기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .task { folders = await LibraryStore.shared.allFolders() }
    }

    private func label(for folder: URL) -> String {
        AppPaths.isInsideDocuments(folder) ? AppPaths.relativePath(folder) : "문서 (맨 위)"
    }
}
