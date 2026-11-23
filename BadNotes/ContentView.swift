//
//  ContentView.swift
//  BadNotes
//
//  첫 화면은 서재(노트북·PDF 고르기). 문서를 누르면 편집 화면, ‹ 누르면 다시 서재.
//  테마·설정·로그 창과 오류 배너는 두 화면이 같이 씀.
//

import SwiftUI
import PencilKit

struct ContentView: View {
    @Environment(ThemeStore.self) private var themes
    @State private var note: NoteDocument?
    @State private var isOpening = false
    @State private var showTheme = false
    @State private var showSettings = false
    @State private var showLog = false
    var log = AppLog.shared

    var body: some View {
        ZStack {
            if let note {
                EditorScreen(note: note,
                             onClose: { Task { await closeNote() } },
                             onTheme: { showTheme = true },
                             onSettings: { showSettings = true },
                             onLog: { showLog = true })
                    .id(ObjectIdentifier(note))
                    // 노트를 펼치면 살짝 커지며 나타나고, 닫으면 서재가 뒤에서 다가옴
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                            removal: .scale(scale: 1.03).combined(with: .opacity)))
            } else {
                LibraryView(onOpen: { url in Task { await openNote(url) } },
                            onTheme: { showTheme = true },
                            onSettings: { showSettings = true })
                    .transition(.asymmetric(insertion: .scale(scale: 1.04).combined(with: .opacity),
                                            removal: .scale(scale: 0.97).combined(with: .opacity)))
            }
            if isOpening {
                ProgressView("여는 중…")
                    .padding(24)
                    .glassEffect(themes.glass, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: note == nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOpening)
        .overlay(alignment: .bottom) {
            errorBanner
                .padding(.horizontal, 16)
                .padding(.bottom, note == nil ? 20 : 130)
        }
        .animation(.spring(duration: 0.35), value: log.latestError?.id)
        .sheet(isPresented: $showTheme) { ThemeSettingsView() }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: AppSettings.shared,
                         openTheme: { switchFromSettings { showTheme = true } },
                         openLog: { switchFromSettings { showLog = true } })
        }
        .sheet(isPresented: $showLog) { LogView() }
        .task { await startup() }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let e = log.latestError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("오류").font(.subheadline.bold())
                    Text(e.message).font(.caption).lineLimit(3)
                }
                Spacer()
                Button("로그") { showLog = true }
                    .buttonStyle(.glass)
                Button { log.markRead() } label: {
                    Image(systemName: "xmark")
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: 640)
            .glassEffect(Glass.regular.tint(.red.opacity(0.75)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 설정 창을 닫고 다른 창을 띄움 (동시에 띄우면 안 뜰 때가 있음)
    private func switchFromSettings(_ action: @escaping () -> Void) {
        showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
    }

    // MARK: 문서 열고 닫기

    func openNote(_ url: URL, remember: Bool = true) async {
        if let old = note {
            await old.flush(reason: "다른 문서 열기")
        }
        isOpening = true
        defer { isOpening = false }
        do {
            let opened = try await NoteDocument.open(url)
            note = opened
            if remember { LastOpened.remember(url) }
        } catch {
            log.error("열기 실패: \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// 서재로 돌아감. 남은 필기를 다 저장한 뒤 표지 썸네일이 새로 그려지게 목록을 다시 읽음
    func closeNote() async {
        guard let current = note else { return }
        await current.flush(reason: "문서 닫기")
        note = nil
        LibraryStore.shared.changed()
    }

    private func startup() async {
        #if DEBUG
        // 점검용 실행 인자
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-BNPreset"), i + 1 < args.count,
           let n = Int(args[i + 1]), Theme.presets.indices.contains(n) {
            themes.apply(Theme.presets[n])
        }
        if args.contains("-BNPhotoTest") {
            // 점검용 바탕 사진: 노을 하늘 같은 그라데이션 + 둥근 빛
            let size = CGSize(width: 1200, height: 1600)
            let image = UIGraphicsImageRenderer(size: size).image { ctx in
                let colors = [UIColor(red: 0.98, green: 0.64, blue: 0.45, alpha: 1).cgColor,
                              UIColor(red: 0.42, green: 0.45, blue: 0.86, alpha: 1).cgColor,
                              UIColor(red: 0.08, green: 0.16, blue: 0.36, alpha: 1).cgColor]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                             locations: [0, 0.55, 1]) {
                    ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
                for i in 0..<16 {
                    let r = CGFloat(40 + (i * 37) % 120)
                    let x = CGFloat((i * 271) % 1200), y = CGFloat((i * 523) % 1600)
                    UIColor.white.withAlphaComponent(0.12 + CGFloat(i % 4) * 0.05).setFill()
                    UIBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
                }
            }
            if let data = image.jpegData(compressionQuality: 0.9) { themes.setPhoto(data) }
        }
        if args.contains("-BNShowTheme") { showTheme = true }
        if args.contains("-BNShowSettings") { showSettings = true }
        if args.contains("-BNInkDemo") || args.contains("-BNCurlDemo") {
            do {
                await openNote(try DemoDocument.make(), remember: false)
            } catch {
                log.error("시연 문서 만들기 실패: \(error.localizedDescription)")
            }
            return
        }
        if args.contains("-BNGlassDemo") {
            // 유리 글자 + 유리펜 시연 노트 (.badnote)
            do {
                let url = try LibraryStore.shared.createNotebook(
                    name: "유리 시연", cover: nil, paper: PaperSpec(template: .ruledWide, tone: .white, size: .a4Portrait),
                    format: .badnote, in: LibraryStore.shared.root)
                var word = PageElement(kind: .text, x: 50, y: 130, width: 500, height: 120)
                word.text = "Liquid 유리"
                word.fontSize = 84
                word.bold = true
                word.glassText = true
                word.glassTextStrength = 0.35
                word.textColor = RGBAColor(hex: 0x1F5FD6)
                word.height = ElementRenderer.fittedHeight(word)
                let points = (0...60).map { i -> PKStrokePoint in
                    let t = CGFloat(i) / 60
                    return PKStrokePoint(location: CGPoint(x: 60 + 460 * t, y: 360 + sin(t * .pi * 2) * 50), timeOffset: Double(i) * 0.01,
                                         size: CGSize(width: 20, height: 20), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let stroke = PKStroke(ink: PKInk(.monoline, color: UIColor(red: 0.85, green: 0.19, blue: 0.15, alpha: 1)),
                                      path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: .identity,
                                      mask: nil, randomSeed: GlassInk.seed(strength: 0.4))
                // 굴절이 잘 보이게 유리 뒤에 사진: 색 줄무늬 + 격자 + 동그라미 + 글씨
                let photoSize = CGSize(width: 1200, height: 900)
                let photo = UIGraphicsImageRenderer(size: photoSize).image { ctx in
                    let cg = ctx.cgContext
                    let colors = [UIColor.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple]
                    for (i, color) in colors.enumerated() {
                        color.setFill()
                        cg.fill(CGRect(x: 0, y: CGFloat(i) * photoSize.height / 7, width: photoSize.width, height: photoSize.height / 7 + 1))
                    }
                    cg.setStrokeColor(UIColor.black.withAlphaComponent(0.55).cgColor)
                    cg.setLineWidth(3)
                    for x in stride(from: 0, through: photoSize.width, by: 40) {
                        cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: photoSize.height))
                    }
                    for y in stride(from: 0, through: photoSize.height, by: 40) {
                        cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: photoSize.width, y: y))
                    }
                    cg.strokePath()
                    UIColor.white.setFill()
                    for i in 0..<9 {
                        let r: CGFloat = 50 + CGFloat(i % 3) * 20
                        cg.fillEllipse(in: CGRect(x: CGFloat(i) * 135, y: CGFloat((i * 211) % 800), width: r, height: r))
                    }
                    let label = NSAttributedString(string: "REFRACTION 굴절 TEST 0123456789", attributes: [
                        .font: UIFont.systemFont(ofSize: 70, weight: .black), .foregroundColor: UIColor.black])
                    label.draw(at: CGPoint(x: 30, y: 380))
                }
                guard let prepared = ElementImages.prepare(photo.pngData() ?? Data()) else { return }
                var picture = PageElement(kind: .image, x: 20, y: 60, width: 555, height: 416)
                picture.imageID = prepared.id
                _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: PKDrawing(strokes: [stroke]), elements: [picture, word])],
                                           images: [prepared.id: prepared.data], to: url)
                await openNote(url)
            } catch {
                log.error("유리 시연 노트 실패: \(error.localizedDescription)")
            }
            return
        }
        if args.contains("-BNMakeNotebook") {
            do {
                let url = try LibraryStore.shared.createNotebook(
                    name: "시연 노트북", cover: .navy,
                    paper: PaperSpec(template: .ruledWide, tone: .yellow, size: .a4Portrait),
                    in: LibraryStore.shared.root)
                await openNote(url)
            } catch {
                log.error("시연 노트북 만들기 실패: \(error.localizedDescription)")
            }
            return
        }
        if args.contains("-BNOpenLast"), let url = LastOpened.url, FileManager.default.fileExists(atPath: url.path) {
            await openNote(url)
        }
        #endif
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

/// 문서마다 마지막으로 보던 페이지 (다시 열면 거기서부터)
enum ReadingPosition {
    private static let key = "readingPositions"

    static func page(for url: URL) -> Int? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[AppPaths.relativePath(url)]
    }

    static func set(_ page: Int, for url: URL) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        all[AppPaths.relativePath(url)] = page
        UserDefaults.standard.set(all, forKey: key)
    }
}

#Preview {
    ContentView()
        .environment(ThemeStore.shared)
}
