//
//  ContentView.swift
//  BadNotes
//
//  지금은 화면 하나: PDF 열기 + 필기.
//  가져온 PDF는 앱 폴더(Documents)로 복사하고, 필기는 그 PDF 안에 저장됨 (Storage/ 참고).
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var note: NoteDocument?
    @State private var isOpening = false
    @State private var showImporter = false
    @State private var showLog = false
    @State private var barHidden = false
    @State private var page = 0
    @State private var pageCount = 0
    @State private var jumpTarget: Int?
    @State private var showJump = false
    @State private var jumpText = ""
    var log = AppLog.shared

    var body: some View {
        NavigationStack {
            Group {
                if let note {
                    PDFNoteView(document: note,
                                jumpTarget: $jumpTarget,
                                onPage: { p, c in page = p; pageCount = c },
                                onScrollHide: { hide in
                                    if hide != barHidden {
                                        withAnimation(.easeInOut(duration: 0.2)) { barHidden = hide }
                                    }
                                })
                        .id(ObjectIdentifier(note))
                        .ignoresSafeArea(edges: .bottom)
                } else if isOpening {
                    ProgressView("여는 중…")
                } else {
                    ContentUnavailableView("PDF를 열어 주세요",
                                           systemImage: "doc.richtext",
                                           description: Text("오른쪽 위 '열기'를 누르세요"))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(barHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLog = true } label: {
                        Image(systemName: log.unreadErrors > 0
                              ? "exclamationmark.triangle.fill" : "ladybug")
                            .foregroundStyle(log.unreadErrors > 0 ? .red : .accentColor)
                    }
                    .accessibilityLabel("로그")
                }
                ToolbarItem(placement: .principal) {
                    // 제목 영역: 파일 이름 + 페이지 + 저장 상태. 누르면 페이지 이동
                    Button {
                        guard pageCount > 0 else { return }
                        jumpText = ""
                        showJump = true
                    } label: {
                        VStack(spacing: 0) {
                            Text(note?.title ?? "BadNotes")
                                .font(.headline).lineLimit(1)
                            HStack(spacing: 8) {
                                if pageCount > 0 {
                                    Text("\(page + 1) / \(pageCount) 쪽")
                                }
                                if let note {
                                    SaveStatusLabel(state: note.saveState)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("열기") { showImporter = true }
                }
            }
            .alert("페이지 이동", isPresented: $showJump) {
                TextField("1 ~ \(pageCount)", text: $jumpText).keyboardType(.numberPad)
                Button("이동") {
                    if let n = Int(jumpText), (1...pageCount).contains(n) {
                        jumpTarget = n - 1
                    } else {
                        log.warn("잘못된 페이지 번호: \(jumpText)")
                    }
                }
                Button("취소", role: .cancel) {}
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.pdf]) { result in
                importPDF(result)
            }
            .sheet(isPresented: $showLog) { LogView() }
            .overlay(alignment: .bottom) { errorBanner }
            // 바가 숨었을 때 화면 위쪽을 탭하면 다시 보이게
            .overlay(alignment: .top) {
                if barHidden {
                    Color.clear.frame(height: 24).contentShape(Rectangle())
                        .onTapGesture { withAnimation { barHidden = false } }
                }
            }
        }
        .task { await reopenLast() }
    }

    @ViewBuilder var errorBanner: some View {
        if let e = log.latestError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("오류").font(.subheadline.bold())
                    Text(e.message).font(.caption).lineLimit(3)
                }
                Spacer()
                Button("로그") { showLog = true }.buttonStyle(.bordered).tint(.white)
                Button { log.markRead() } label: { Image(systemName: "xmark") }
                    .tint(.white)
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(.red.gradient, in: RoundedRectangle(cornerRadius: 14))
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring, value: e.id)
        }
    }

    /// 파일 앱에서 고른 PDF를 앱 폴더로 복사한 뒤 엶. 같은 이름이 이미 있으면 그걸 엶 (필기 포함)
    func importPDF(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let err):
            log.error("파일 선택 실패: \(err.localizedDescription)")
        case .success(let src):
            let ok = src.startAccessingSecurityScopedResource()
            defer { if ok { src.stopAccessingSecurityScopedResource() } }
            if !ok { log.warn("보안 범위 접근 실패(계속 시도): \(src.lastPathComponent)") }
            let dst = AppPaths.documents.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                log.info("앱 폴더에 있는 파일 사용: \(dst.lastPathComponent)")
            } else {
                do {
                    try FileManager.default.copyItem(at: src, to: dst)
                    log.info("앱 폴더로 복사함: \(dst.lastPathComponent)")
                } catch {
                    log.error("PDF 복사 실패: \(error.localizedDescription)")
                    return
                }
            }
            Task { await openNote(dst) }
        }
    }

    func openNote(_ url: URL) async {
        if let old = note {
            await old.flush(reason: "다른 문서 열기")
        }
        isOpening = true
        defer { isOpening = false }
        do {
            let opened = try await NoteDocument.open(url)
            page = 0
            pageCount = opened.pageCount
            barHidden = false
            note = opened
            LastOpened.remember(url)
        } catch {
            log.error("열기 실패: \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// 라이브러리 화면이 생기기 전까지는 마지막 문서를 다시 열어 줌
    func reopenLast() async {
        guard note == nil, let url = LastOpened.url,
              FileManager.default.fileExists(atPath: url.path) else { return }
        await openNote(url)
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

/// 마지막에 연 문서 (Documents 기준 상대 경로로 기억)
enum LastOpened {
    private static let key = "lastOpenedDocument"

    static var url: URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.hasPrefix("/") else { return nil }
        return AppPaths.documents.appendingPathComponent(path)
    }

    static func remember(_ url: URL) {
        UserDefaults.standard.set(AppPaths.relativePath(url), forKey: key)
    }
}

#Preview {
    ContentView()
}
