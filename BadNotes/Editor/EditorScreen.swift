//
//  EditorScreen.swift
//  BadNotes
//
//  문서 하나를 연 화면. 테마 바탕 위에 편집기가 깔리고, 그 위에 유리 막대들이 떠 있음.
//  편집기는 설정에 따라 BadNotes 필기 도구(기본) 또는 Apple 필기 도구(PencilKit).
//  마지막 페이지까지 내려가면 [페이지 추가] 버튼이 뜸.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct EditorScreen: View {
    @Environment(ThemeStore.self) private var themes

    let note: NoteDocument
    let onClose: () -> Void
    let onTheme: () -> Void
    let onSettings: () -> Void
    let onLog: () -> Void

    @State private var settings = AppSettings.shared
    @State private var tools = InkToolState.shared
    @State private var bridge = EditorBridge()
    @State private var showJump = false
    @State private var jumpText = ""
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showImageFiles = false
    var log = AppLog.shared

    /// 처음 보여 줄 페이지: 마지막으로 보던 곳, 처음 여는 노트북이면 표지 다음 장
    private var initialPage: Int {
        if let saved = ReadingPosition.page(for: note.url), saved < note.pageCount { return saved }
        return note.hasCover && note.pageCount > 1 ? 1 : 0
    }

    @State private var topBarHeight: CGFloat = 0
    @State private var bottomBarHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop
                editor(insets: EdgeInsets(top: geo.safeAreaInsets.top + (bridge.chromeHidden ? 0 : topBarHeight), leading: 0,
                                          bottom: geo.safeAreaInsets.bottom + (bridge.chromeHidden ? 0 : bottomBarHeight), trailing: 0))
                    .id(settings.editMode)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if bridge.chromeHidden {
                // 막대가 숨었을 때 위쪽을 탭하면 다시 보임
                Color.clear
                    .frame(width: 110, height: 30)
                    .contentShape(Rectangle())
                    .overlay { Capsule().fill(.secondary.opacity(0.65)).frame(width: 32, height: 4) }
                    .onTapGesture { bridge.chromeHidden = false }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("도구 막대 보기")
            } else {
                EditorChrome(tools: tools, bridge: bridge, mode: settings.editMode, isBoard: note.isBoard,
                             unreadErrors: log.unreadErrors,
                             onClose: onClose, onAddPage: addPage,
                             onPickPhoto: { showPhotos = true }, onPickFile: { showImageFiles = true },
                             onTheme: onTheme, onSettings: onSettings, onLog: onLog)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { topBarHeight = $0 }
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            if !bridge.chromeHidden {
                HStack(spacing: 6) {
                    ZoomChip(bridge: bridge, settings: settings)
                    StatusCapsule(title: note.title, page: bridge.page, pageCount: bridge.pageCount,
                                  saveState: note.saveState, isBook: bridge.isBook,
                                  canBack: bridge.canTurnBack, canForward: bridge.canTurnForward,
                                  onTurn: { bridge.turn($0) }) {
                        guard bridge.pageCount > 0 else { return }
                        jumpText = ""
                        showJump = true
                    }
                    if bridge.atLastPage && !note.isBoard {
                        Button(action: addPage) {
                            Image(systemName: "plus").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(themes.glass.interactive(), in: .circle)
                        .accessibilityLabel("페이지 추가")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottomBarHeight = $0 }
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: bridge.chromeHidden)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: bridge.atLastPage)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bridge.isBook)
        .onChange(of: bridge.page) { _, page in ReadingPosition.set(page, for: note.url) }
        .onChange(of: bridge.imageRequest) { _, _ in showPhotos = true }
        .onChange(of: bridge.jumpRequest) { _, _ in
            guard bridge.pageCount > 0 else { return }
            jumpText = ""
            showJump = true
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    bridge.insert(.image(data))
                } else {
                    log.error("사진을 불러오지 못함")
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showImageFiles, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    bridge.insert(.image(try Data(contentsOf: url)))
                } catch {
                    log.error("이미지 파일을 읽지 못함: \(error.localizedDescription)")
                }
            case .failure(let error):
                log.error("파일 선택 실패: \(error.localizedDescription)")
            }
        }
        .alert("페이지 이동", isPresented: $showJump) {
            TextField("1 ~ \(bridge.pageCount)", text: $jumpText).keyboardType(.numberPad)
            Button("이동") {
                if let n = Int(jumpText), (1...max(1, bridge.pageCount)).contains(n) {
                    bridge.jump(to: n - 1)
                } else {
                    log.warn("잘못된 페이지 번호: \(jumpText)")
                }
            }
            Button("취소", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        switch themes.theme.editorBackground {
        case .theme: Color.clear
        case .dimmed: Color.black.opacity(0.35)
        case .plain: Color(uiColor: .secondarySystemBackground)
        }
    }

    @ViewBuilder
    private func editor(insets: EdgeInsets) -> some View {
        switch settings.editMode {
        case .direct:
            DirectEditor(document: note, bridge: bridge, initialPage: initialPage, tool: tools.tool,
                         fingerDrawing: settings.fingerDrawing, tapToUndo: settings.tapToUndo,
                         pageTurn: settings.pageTurn, twoUp: settings.twoUpLandscape, zoomLocked: settings.zoomLocked,
                         insets: insets)
        case .pencilKit:
            PencilKitEditor(document: note, bridge: bridge, initialPage: initialPage,
                            fingerDrawing: settings.fingerDrawing, twoUp: settings.twoUpLandscape,
                            zoomLocked: settings.zoomLocked, insets: insets)
        }
    }

    private func addPage() {
        guard let index = note.appendPage() else { return }
        bridge.pageAdded(index)
    }
}

/// 아래 왼쪽: 지금 배율. 누르면 페이지 맞춤·배율 고르기·확대 고정
struct ZoomChip: View {
    @Environment(ThemeStore.self) private var themes
    let bridge: EditorBridge
    @Bindable var settings: AppSettings

    var body: some View {
        Menu {
            Button("페이지에 맞추기", systemImage: "arrow.down.right.and.arrow.up.left") { bridge.zoom(nil) }
            Section("배율") {
                ForEach([125, 150, 200, 300], id: \.self) { percent in
                    Button("\(percent)%") { bridge.zoom(Double(percent)) }
                }
            }
            Toggle(isOn: $settings.zoomLocked) {
                Label("확대 고정 (핀치 끄기)", systemImage: "lock")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: settings.zoomLocked ? "lock.fill" : "plus.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(bridge.zoomPercent)%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(bridge.zoomPercent)))
            }
            .foregroundStyle(settings.zoomLocked ? themes.accent : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .glassEffect(themes.glass.interactive(), in: .capsule)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: bridge.zoomPercent)
        .accessibilityLabel("배율 \(bridge.zoomPercent)%")
    }
}
