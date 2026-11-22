//
//  EditorScreen.swift
//  BadNotes
//
//  문서 하나를 연 화면. 테마 바탕 위에 편집기가 깔리고, 그 위에 유리 막대들이 떠 있음.
//  편집기는 설정에 따라 직접 필기(기본) 또는 레이어(PencilKit).
//  마지막 페이지까지 내려가면 [페이지 추가] 버튼이 뜸.
//

import SwiftUI

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
    var log = AppLog.shared

    /// 처음 보여 줄 페이지: 마지막으로 보던 곳, 처음 여는 노트북이면 표지 다음 장
    private var initialPage: Int {
        if let saved = ReadingPosition.page(for: note.url), saved < note.pageCount { return saved }
        return note.hasCover && note.pageCount > 1 ? 1 : 0
    }

    /// 떠 있는 막대 높이 (내용을 이만큼 비켜 둠)
    private static let topBar: CGFloat = 62
    private static let bottomBar: CGFloat = 66

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop
                editor(insets: EdgeInsets(top: geo.safeAreaInsets.top + Self.topBar, leading: 0,
                                          bottom: geo.safeAreaInsets.bottom + Self.bottomBar, trailing: 0))
                    .id(settings.editMode)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if bridge.chromeHidden {
                // 막대가 숨었을 때 위쪽을 탭하면 다시 보임
                Color.clear
                    .frame(height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture { bridge.chromeHidden = false }
            } else {
                EditorChrome(tools: tools, bridge: bridge, mode: settings.editMode, unreadErrors: log.unreadErrors,
                             onClose: onClose, onAddPage: addPage,
                             onTheme: onTheme, onSettings: onSettings, onLog: onLog)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if !bridge.chromeHidden {
                VStack(spacing: 10) {
                    if bridge.atLastPage {
                        Button(action: addPage) {
                            Label("페이지 추가", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                        .transition(.scale.combined(with: .opacity))
                    }
                    StatusCapsule(title: note.title, page: bridge.page, pageCount: bridge.pageCount,
                                  saveState: note.saveState) {
                        guard bridge.pageCount > 0 else { return }
                        jumpText = ""
                        showJump = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.28), value: bridge.chromeHidden)
        .animation(.smooth(duration: 0.25), value: bridge.atLastPage)
        .onChange(of: bridge.page) { _, page in ReadingPosition.set(page, for: note.url) }
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
                         fingerDrawing: settings.fingerDrawing, tapToUndo: settings.tapToUndo, insets: insets)
        case .layer:
            PDFNoteView(document: note, bridge: bridge, initialPage: initialPage)
                .padding(.top, insets.top)
        }
    }

    private func addPage() {
        guard let index = note.appendPage() else { return }
        bridge.pageAdded(index)
    }
}
