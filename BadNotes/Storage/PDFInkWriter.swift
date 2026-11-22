//
//  PDFInkWriter.swift
//  BadNotes
//
//  필기를 PDF 파일에 실제로 써 넣는 곳. 백그라운드 스레드에서 돌림.
//  순서: 디스크의 PDF를 새로 읽음 → 바뀐 페이지의 필기 주석 교체 → 임시 파일에 씀
//        → 임시 파일을 다시 열어서 검증 → 원본과 원자적으로 바꿔치기
//  검증에 실패하면 원본은 그대로 둠.
//

import PDFKit
import PencilKit

nonisolated enum PDFInkWriter {
    struct Report: Sendable {
        var pages: Int
        var bytes: Int
        var seconds: Double
    }

    enum WriteError: LocalizedError {
        case unreadable
        case locked
        case pageOutOfRange(Int, Int)
        case writeFailed
        case verifyFailed(String)
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "PDF를 읽을 수 없음"
            case .locked: "암호가 걸린 PDF는 아직 저장할 수 없음"
            case .pageOutOfRange(let p, let n): "\(p + 1)쪽이 없음 (전체 \(n)쪽)"
            case .writeFailed: "PDF 쓰기 실패"
            case .verifyFailed(let why): "저장한 PDF 검증 실패: \(why)"
            case .replaceFailed(let why): "원본 교체 실패: \(why)"
            }
        }
    }

    /// `pages`의 필기로 해당 페이지들을 바꿔서 `url`에 저장. 빈 PKDrawing은 그 페이지 필기 삭제.
    /// `appending`: 맨 뒤에 붙일 페이지들 (한 장짜리 PDF 데이터). 필기보다 먼저 붙여서 새 페이지 필기도 같이 저장됨
    static func apply(_ pages: [Int: PKDrawing], appending newPages: [Data] = [], to url: URL) throws -> Report {
        let start = Date()
        let data = try NoteLoader.coordinatedRead(url)
        guard let document = PDFDocument(data: data) else { throw WriteError.unreadable }
        if document.isLocked { throw WriteError.locked }

        // 페이지를 넘겨준 문서는 쓰기가 끝날 때까지 살려 둠
        var sources: [PDFDocument] = []
        for pageData in newPages {
            guard let source = PDFDocument(data: pageData), let page = source.page(at: 0) else {
                throw WriteError.unreadable
            }
            sources.append(source)
            document.insert(page, at: document.pageCount)
        }

        for (index, drawing) in pages.sorted(by: { $0.key < $1.key }) {
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
                throw WriteError.pageOutOfRange(index, document.pageCount)
            }
            // 읽을 수 있는 BadNotes 필기만 교체. 깨진 건 손대지 않음
            for old in InkPayload.read(from: page).annotations {
                page.removeAnnotation(old)
            }
            if !drawing.strokes.isEmpty {
                page.addAnnotation(try InkAnnotation(drawing: drawing, geometry: PageGeometry(page: page)))
            }
        }

        let fm = FileManager.default
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: tempDir) }
        let temp = tempDir.appendingPathComponent(url.lastPathComponent)

        guard document.write(to: temp) else { throw WriteError.writeFailed }
        try verify(temp, pageCount: document.pageCount, expected: pages)
        let bytes = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try replace(url, with: temp)
        withExtendedLifetime(sources) {}
        return Report(pages: pages.count + newPages.count, bytes: bytes, seconds: Date().timeIntervalSince(start))
    }

    private static func verify(_ url: URL, pageCount: Int, expected: [Int: PKDrawing]) throws {
        guard let document = PDFDocument(url: url) else {
            throw WriteError.verifyFailed("다시 열 수 없음")
        }
        guard document.pageCount == pageCount else {
            throw WriteError.verifyFailed("쪽수 \(document.pageCount) ≠ \(pageCount)")
        }
        for (index, drawing) in expected {
            guard let page = document.page(at: index) else {
                throw WriteError.verifyFailed("\(index + 1)쪽 없음")
            }
            let read = InkPayload.read(from: page)
            if let problem = read.problems.first {
                throw WriteError.verifyFailed("\(index + 1)쪽: \(problem)")
            }
            if read.drawing.strokes.count != drawing.strokes.count {
                throw WriteError.verifyFailed(
                    "\(index + 1)쪽 획 수 \(read.drawing.strokes.count) ≠ \(drawing.strokes.count)")
            }
        }
    }

    /// 같은 볼륨 안에서 rename으로 교체 → 중간 상태가 없음.
    /// 화면에 열려 있는 문서는 옛 파일을 메모리 매핑으로 들고 있어서 교체돼도 안전함.
    private static func replace(_ url: URL, with temp: URL) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { target in
            if rename(temp.path, target.path) != 0 {
                failure = WriteError.replaceFailed(String(cString: strerror(errno)))
            }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }
}

/// 덮어쓰기 전 PDF 사본. APFS에서는 복제(clone)라서 바로 끝나고, 바뀐 만큼만 공간을 씀.
nonisolated enum BackupStore {
    /// 문서마다 남기는 최근 사본 수 (옮기기 전 사본은 따로 영구 보관)
    static let keep = 5
    static let permanentTag = "before-migration"

    @discardableResult
    static func snapshot(_ url: URL, reason: String) throws -> URL {
        try AppPaths.ensure(AppPaths.backups, excludeFromBackup: true)
        let dir = try AppPaths.ensure(AppPaths.backups.appendingPathComponent(AppPaths.key(for: url),
                                                                              isDirectory: true))
        let dest = dir.appendingPathComponent("\(AppPaths.timestamp())-\(reason).pdf")

        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { source in
            do { try FileManager.default.copyItem(at: source, to: dest) } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
        prune(dir)
        return dest
    }

    static func prune(_ dir: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pdf" && !$0.lastPathComponent.contains(permanentTag) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
