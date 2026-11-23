//
//  NoteDocument.swift
//  BadNotes
//
//  열려 있는 PDF 한 권.
//  - 화면용 PDFDocument (필기 주석은 떼어 낸 상태. 필기는 페이지 위 캔버스가 그림)
//  - 페이지별 필기와 바뀐 페이지 추적
//  - 획이 바뀌면: 0.4초 뒤 복구 기록(가벼움) → 몇 초 모아서 PDF 저장(무거움, 백그라운드)
//  - 앱 전환/문서 닫기: 남은 것 전부 저장
//

import SwiftUI
import PDFKit
import PencilKit
import Observation

@Observable
final class NoteDocument {
    enum SaveState: Equatable {
        case saved(Date?)
        case pending
        case saving
        case failed(String)
    }

    let url: URL
    @ObservationIgnored let pdf: PDFDocument
    private(set) var saveState: SaveState = .saved(nil)

    var title: String { url.deletingPathExtension().lastPathComponent }
    var pageCount: Int { pdf.pageCount }
    var hasUnsavedChanges: Bool { !dirty.isEmpty || !pendingAppends.isEmpty }
    /// 노트북이면 종이 정보 (PDF 키워드에서 읽음). 그냥 PDF면 nil
    @ObservationIgnored private(set) var paperSpec: PaperSpec?
    var isNotebook: Bool { paperSpec != nil }
    /// 첫 장이 표지인 노트북 (처음 열 때 표지 다음 장부터 보여 줌)
    @ObservationIgnored private(set) var hasCover = false
    /// 무한 화이트보드 (아주 큰 한 장, 페이지 추가 없음)
    @ObservationIgnored private(set) var isBoard = false
    /// PDF 타일을 그리는 동안 페이지가 들어오지 않게 (읽기 여럿 / 쓰기 하나)
    nonisolated let renderLock = ReadWriteLock()

    /// 계속 그리고 있어도 이 시간이 지나면 저장
    private static let maxUnsavedSeconds: TimeInterval = 20

    @ObservationIgnored private var drawings: [Int: PKDrawing]
    /// 텍스트 상자·메모지·사진 (페이지별)
    @ObservationIgnored private var elementsByPage: [Int: [PageElement]]
    /// 요소가 쓰는 사진 원본 (번호 → 데이터)
    @ObservationIgnored private var imageStore: [String: Data]
    @ObservationIgnored private var decodedImages: [String: CGImage] = [:]
    @ObservationIgnored private var revision: [Int: Int] = [:]
    @ObservationIgnored private var dirty: Set<Int> = []
    @ObservationIgnored private var dirtySince: Date?
    @ObservationIgnored private let journal: DrawingJournal
    @ObservationIgnored private let journalQueue = DispatchQueue(label: "BadNotes.journal", qos: .utility)
    @ObservationIgnored private var journalTimers: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTimer: Task<Void, Never>?
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var backedUpThisSession = false
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var retryDelay: Duration = .seconds(5)
    /// 아직 파일에 안 붙인 새 페이지 (한 장짜리 PDF 데이터)
    @ObservationIgnored private var pendingAppends: [Data] = []
    @ObservationIgnored private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    // MARK: 열기

    static func open(_ url: URL) async throws -> NoteDocument {
        await LegacyMigration.waitUntilDone()
        let journal = DrawingJournal(documentURL: url)
        let opened = try await Task.detached(priority: .userInitiated) {
            let loaded = try NoteLoader.load(url)
            let recovered = journal.load()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return OpenResult(loaded: loaded, recovered: recovered,
                              recoveryProblems: recovered.problems, fileSize: size)
        }.value
        return NoteDocument(url: url, opened: opened, journal: journal)
    }

    private init(url: URL, opened: OpenResult, journal: DrawingJournal) {
        self.url = url
        self.pdf = opened.loaded.pdf
        self.drawings = opened.loaded.drawings
        self.elementsByPage = opened.loaded.elements
        self.imageStore = opened.loaded.images.merging(opened.recovered.images) { a, _ in a }
        self.journal = journal
        self.paperSpec = PaperSpec.from(documentAttributes: opened.loaded.pdf.documentAttributes)
        self.hasCover = PaperSpec.hasCover(opened.loaded.pdf.documentAttributes)
        self.isBoard = PaperSpec.isBoard(opened.loaded.pdf.documentAttributes)
        // 큰 파일일수록 저장 간격을 늘림 (10MB당 1.5초, 3~15초)
        let seconds = min(15, max(3, Double(opened.fileSize) / 10_000_000 * 1.5))
        self.saveDelay = .milliseconds(Int(seconds * 1000))

        let pageCount = opened.loaded.pdf.pageCount
        Log.info("열림: \(url.lastPathComponent) (\(pageCount)쪽, 필기 있는 쪽 \(opened.loaded.drawings.count)개)")
        for problem in opened.loaded.problems + opened.recoveryProblems {
            Log.error("필기 읽기 문제 — \(problem)")
        }

        let recovered = opened.recovered.allPages.filter { $0 >= 0 && $0 < pageCount }
        for page in recovered {
            if let drawing = opened.recovered.drawings[page] { drawings[page] = drawing }
            if let elements = opened.recovered.elements[page] { elementsByPage[page] = elements.isEmpty ? nil : elements }
            revision[page] = 1
            dirty.insert(page)
        }
        observeLifecycle()
        if !recovered.isEmpty {
            dirtySince = Date()
            saveState = .pending
            Log.warn("지난번에 PDF에 못 넣은 필기 \(recovered.count)쪽을 복구 기록에서 되살림")
            scheduleSave(after: .seconds(1))
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: 필기

    /// 화이트보드에서 처음 보여 줄 곳: 필기·요소가 있는 영역 (없으면 nil)
    func contentBounds(page: Int) -> CGRect? {
        var rect = drawings[page]?.bounds ?? .null
        for element in elementsByPage[page] ?? [] { rect = rect.union(element.frame) }
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    func drawing(for page: Int) -> PKDrawing {
        drawings[page] ?? PKDrawing()
    }

    func update(_ drawing: PKDrawing, page: Int) {
        drawings[page] = drawing
        markChanged(page)
    }

    // MARK: 텍스트 상자·메모지·사진

    func elements(for page: Int) -> [PageElement] {
        elementsByPage[page] ?? []
    }

    func updateElements(_ elements: [PageElement], page: Int) {
        elementsByPage[page] = elements.isEmpty ? nil : elements
        markChanged(page)
    }

    /// 사진 원본을 문서에 넣어 둠 (같은 사진이면 한 번만)
    func addImage(id: String, data: Data) {
        if imageStore[id] == nil { imageStore[id] = data }
    }

    func image(for id: String) -> CGImage? {
        if let hit = decodedImages[id] { return hit }
        guard let data = imageStore[id], let image = ElementImages.decode(data) else { return nil }
        decodedImages[id] = image
        return image
    }

    private func markChanged(_ page: Int) {
        revision[page, default: 0] += 1
        dirty.insert(page)
        if dirtySince == nil { dirtySince = Date() }
        if !isSaving { saveState = .pending }
        scheduleJournal(page)
        scheduleSave()
    }

    /// 남은 변경을 전부 PDF에 반영 (앱 전환, 문서 닫기, 다른 문서 열기)
    func flush(reason: String) async {
        for (page, timer) in journalTimers {
            timer.cancel()
            writeJournal(page)
        }
        saveTimer?.cancel()
        saveTimer = nil
        while isSaving {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if hasUnsavedChanges {
            Log.info("저장 (\(reason))")
            await save()
        }
    }

    // MARK: 페이지 추가

    /// 맨 뒤에 새 페이지. 노트북이면 같은 종이, 그냥 PDF면 마지막 페이지 크기의 흰 종이.
    /// 화면용 문서에는 바로 넣고, 파일에는 곧 저장. 새 페이지 번호를 돌려줌
    @discardableResult
    func appendPage() -> Int? {
        guard !isBoard else { return nil }
        let spec = paperSpec ?? blankPaperMatchingLastPage()
        let data = PaperRenderer.pagePDF(spec)
        guard let source = PDFDocument(data: data), let page = source.page(at: 0) else {
            Log.error("새 페이지를 만들지 못함")
            return nil
        }
        renderLock.write {
            pdf.insert(page, at: pdf.pageCount)
        }
        pendingAppends.append(data)
        if dirtySince == nil { dirtySince = Date() }
        if !isSaving { saveState = .pending }
        Log.info("페이지 추가: \(pdf.pageCount)쪽")
        scheduleSave(after: .milliseconds(300))
        return pdf.pageCount - 1
    }

    private func blankPaperMatchingLastPage() -> PaperSpec {
        let size = pdf.page(at: pdf.pageCount - 1).map { PageGeometry(page: $0).canvasSize }
            ?? PaperSpec.Size.a4Portrait.points
        return PaperSpec(template: .blank, tone: .white, width: size.width, height: size.height)
    }

    // MARK: 복구 기록

    private func scheduleJournal(_ page: Int) {
        journalTimers[page]?.cancel()
        journalTimers[page] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeJournal(page)
        }
    }

    private func writeJournal(_ page: Int) {
        journalTimers[page] = nil
        guard dirty.contains(page) else { return }
        let drawing = drawing(for: page)
        let elements = elements(for: page)
        let used = Set(elements.compactMap(\.imageID))
        let images = imageStore.filter { used.contains($0.key) }
        let journal = journal
        journalQueue.async {
            do {
                try journal.write(drawing, page: page)
                try journal.write(elements, images: images, page: page)
            } catch {
                Log.error("복구 기록 실패 (\(page + 1)쪽): \(error.localizedDescription)")
            }
        }
    }

    // MARK: PDF 저장

    private func scheduleSave(after delay: Duration? = nil) {
        guard hasUnsavedChanges else { return }
        let overdue = dirtySince.map { Date().timeIntervalSince($0) > Self.maxUnsavedSeconds } ?? false
        let wait = delay ?? (overdue ? .zero : saveDelay)
        saveTimer?.cancel()
        saveTimer = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private func save() async {
        guard hasUnsavedChanges, !isSaving else { return }
        isSaving = true
        saveState = .saving
        let pages = Dictionary(uniqueKeysWithValues: dirty.map {
            ($0, PageContent(drawing: drawing(for: $0), elements: elements(for: $0)))
        })
        let used = Set(pages.values.flatMap { $0.elements ?? [] }.compactMap(\.imageID))
        let images = imageStore.filter { used.contains($0.key) }
        let revisions = Dictionary(uniqueKeysWithValues: dirty.map { ($0, revision[$0] ?? 0) })
        let appends = pendingAppends
        let url = url
        let needsBackup = !backedUpThisSession

        let result = await Task.detached(priority: .utility) { () -> Result<PDFInkWriter.Report, Error> in
            if needsBackup {
                do {
                    try BackupStore.snapshot(url, reason: "session")
                } catch {
                    Log.warn("백업 실패 (저장은 계속함): \(error.localizedDescription)")
                }
            }
            return Result { try PDFInkWriter.apply(content: pages, images: images, appending: appends, to: url) }
        }.value
        isSaving = false

        switch result {
        case .success(let report):
            backedUpThisSession = true
            retryDelay = .seconds(5)
            pendingAppends.removeFirst(min(appends.count, pendingAppends.count))
            for (page, saved) in revisions where revision[page] == saved {
                dirty.remove(page)
                journalTimers[page]?.cancel()
                journalTimers[page] = nil
                let journal = journal
                journalQueue.async { journal.remove(page: page) }
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(report.bytes), countStyle: .file)
            Log.info("PDF 저장: \(report.pages)쪽 반영, \(size), \(String(format: "%.2f", report.seconds))초")
            if !hasUnsavedChanges {
                dirtySince = nil
                saveState = .saved(Date())
            } else {
                dirtySince = Date()
                saveState = .pending
                scheduleSave()
            }
        case .failure(let error):
            saveState = .failed(error.localizedDescription)
            Log.error("PDF 저장 실패: \(error.localizedDescription) — 필기는 복구 기록에 남아 있고 다시 시도함")
            for page in dirty { writeJournal(page) }
            scheduleSave(after: retryDelay)
            retryDelay = min(retryDelay * 2, .seconds(120))
        }
    }

    // MARK: 앱 전환

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushInBackground() }
            })
        }
    }

    /// 앱이 백그라운드로 가도 저장을 끝낼 시간을 받아 둠
    private func flushInBackground() {
        guard hasUnsavedChanges || !journalTimers.isEmpty else { return }
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "BadNotes 저장") { task.end() }
        Task {
            await flush(reason: "앱 전환")
            task.end()
        }
    }
}

private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// 백그라운드에서 연 결과를 메인으로 넘기는 상자
nonisolated private struct OpenResult: @unchecked Sendable {
    let loaded: LoadedNote
    let recovered: DrawingJournal.Recovered
    let recoveryProblems: [String]
    let fileSize: Int
}
