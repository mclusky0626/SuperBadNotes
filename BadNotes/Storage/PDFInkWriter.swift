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

/// 한 페이지에 넣을 것. nil이면 그 종류는 손대지 않음
nonisolated struct PageContent: @unchecked Sendable {
    var drawing: PKDrawing?
    var elements: [PageElement]?
}

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

    /// `pages`의 필기로 해당 페이지들을 바꿔서 `url`에 저장 (요소는 그대로 둠)
    static func apply(_ pages: [Int: PKDrawing], appending newPages: [Data] = [], to url: URL) throws -> Report {
        try apply(content: pages.mapValues { PageContent(drawing: $0, elements: nil) }, images: [:],
                  appending: newPages, to: url)
    }

    /// 페이지마다 필기·요소를 바꿔서 `url`에 저장. nil인 쪽은 손대지 않음, 비어 있으면 그 페이지에서 삭제.
    /// `images`: 요소가 쓰는 사진 원본. `appending`: 맨 뒤에 붙일 페이지들 (한 장짜리 PDF 데이터).
    /// 페이지를 먼저 붙여서 새 페이지 내용도 같이 저장됨
    static func apply(content pages: [Int: PageContent], images: [String: Data], appending newPages: [Data] = [],
                      to url: URL) throws -> Report {
        let start = Date()
        let data = try NoteLoader.coordinatedRead(url)
        guard let document = PDFDocument(data: data) else { throw WriteError.unreadable }
        if document.isLocked { throw WriteError.locked }
        let bake = NoteFormat.bakesGlass(url)

        // 페이지를 넘겨준 문서는 쓰기가 끝날 때까지 살려 둠
        var sources: [PDFDocument] = []
        for pageData in newPages {
            guard let source = PDFDocument(data: pageData), let page = source.page(at: 0) else {
                throw WriteError.unreadable
            }
            sources.append(source)
            document.insert(page, at: document.pageCount)
        }

        for (index, content) in pages.sorted(by: { $0.key < $1.key }) {
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
                throw WriteError.pageOutOfRange(index, document.pageCount)
            }
            let geometry = PageGeometry(page: page)
            // 읽을 수 있는 BadNotes 주석만 교체. 깨진 건 손대지 않음.
            // 요소 → 필기 순서로 다시 붙여서 다른 앱에서도 필기가 위에 보이게 함
            let ink = InkPayload.read(from: page)
            let placed = ElementPayload.read(from: page)
            for old in ink.annotations + placed.annotations {
                page.removeAnnotation(old)
            }
            if let elements = content.elements {
                if !elements.isEmpty {
                    let pool = images.merging(placed.images) { a, _ in a }
                    page.addAnnotation(try ElementAnnotation(elements: elements, images: pool, geometry: geometry, bakeGlass: bake))
                }
            } else {
                for old in placed.annotations { page.addAnnotation(old) }
            }
            if let drawing = content.drawing {
                if !drawing.strokes.isEmpty {
                    page.addAnnotation(try InkAnnotation(drawing: drawing, geometry: geometry, bakeGlass: bake))
                }
            } else {
                for old in ink.annotations { page.addAnnotation(old) }
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

    /// 노트북 표지를 새로 그린 것으로 바꿈 (표지가 없으면 맨 앞에 넣음). 표지 위 필기는 새 표지로 옮김.
    /// 돌려주는 값: 표지를 새로 넣었으면 true (페이지 번호가 하나씩 밀림)
    @discardableResult
    static func replaceCover(of url: URL, with cover: CoverStyle, title: String) throws -> Bool {
        try? BackupStore.snapshot(url, reason: "cover")
        let data = try NoteLoader.coordinatedRead(url)
        guard let document = PDFDocument(data: data), let first = document.page(at: 0) else { throw WriteError.unreadable }
        if document.isLocked { throw WriteError.locked }
        if PaperSpec.isBoard(document.documentAttributes) { throw WriteError.verifyFailed("화이트보드에는 표지를 넣을 수 없음") }
        let hadCover = PaperSpec.hasCover(document.documentAttributes)
        let size = PageGeometry(page: first).canvasSize
        let coverData = PaperRenderer.coverPDF(cover, title: title, size: size)
        guard let source = PDFDocument(data: coverData), let page = source.page(at: 0) else { throw WriteError.unreadable }

        // 옛 표지 위의 BadNotes 필기·요소는 읽어서 새 표지에 새로 만들어 붙임
        // (주석 객체를 그대로 옮기면 /BNInk 같은 편집용 원본이 떨어져 나감)
        var ink = InkPayload.ReadResult()
        var placed = ElementPayload.ReadResult()
        var others: [PDFAnnotation] = []
        if hadCover {
            ink = InkPayload.read(from: first)
            placed = ElementPayload.read(from: first)
            let ours = Set((ink.annotations + placed.annotations).map(ObjectIdentifier.init))
            others = first.annotations.filter { !ours.contains(ObjectIdentifier($0)) }
            document.removePage(at: 0)
        }
        document.insert(page, at: 0)
        let geometry = PageGeometry(page: page)
        if !placed.elements.isEmpty {
            page.addAnnotation(try ElementAnnotation(elements: placed.elements, images: placed.images, geometry: geometry,
                                                     bakeGlass: NoteFormat.bakesGlass(url)))
        }
        if !ink.drawing.strokes.isEmpty {
            page.addAnnotation(try InkAnnotation(drawing: ink.drawing, geometry: geometry, bakeGlass: NoteFormat.bakesGlass(url)))
        }
        for annotation in others {
            first.removeAnnotation(annotation)
            page.addAnnotation(annotation)
        }

        var attributes = document.documentAttributes ?? [:]
        var keywords = PaperSpec.keywords(attributes).filter { !$0.hasPrefix(PaperSpec.coverPrefix) }
        if !keywords.contains("BadNotes") { keywords.insert("BadNotes", at: 0) }
        keywords.append("\(PaperSpec.coverPrefix)\(cover.rawValue)")
        attributes[PDFDocumentAttribute.keywordsAttribute] = keywords
        document.documentAttributes = attributes

        let pageCount = document.pageCount
        let fm = FileManager.default
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: tempDir) }
        let temp = tempDir.appendingPathComponent(url.lastPathComponent)
        guard document.write(to: temp) else { throw WriteError.writeFailed }
        guard let checkData = try? Data(contentsOf: temp), let check = PDFDocument(data: checkData),
              check.pageCount == pageCount else {
            throw WriteError.verifyFailed("표지를 바꾼 PDF를 다시 열 수 없음")
        }
        try replace(url, with: temp)
        withExtendedLifetime(source) {}
        return !hadCover
    }

    private static func verify(_ url: URL, pageCount: Int, expected: [Int: PageContent]) throws {
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else {
            throw WriteError.verifyFailed("다시 열 수 없음")
        }
        guard document.pageCount == pageCount else {
            throw WriteError.verifyFailed("쪽수 \(document.pageCount) ≠ \(pageCount)")
        }
        for (index, content) in expected {
            guard let page = document.page(at: index) else {
                throw WriteError.verifyFailed("\(index + 1)쪽 없음")
            }
            if let drawing = content.drawing {
                let read = InkPayload.read(from: page)
                if let problem = read.problems.first {
                    throw WriteError.verifyFailed("\(index + 1)쪽: \(problem)")
                }
                if read.drawing.strokes.count != drawing.strokes.count {
                    throw WriteError.verifyFailed(
                        "\(index + 1)쪽 획 수 \(read.drawing.strokes.count) ≠ \(drawing.strokes.count)")
                }
            }
            if let elements = content.elements {
                let read = ElementPayload.read(from: page)
                if let problem = read.problems.first {
                    throw WriteError.verifyFailed("\(index + 1)쪽: \(problem)")
                }
                if read.elements.count != elements.count {
                    throw WriteError.verifyFailed("\(index + 1)쪽 요소 수 \(read.elements.count) ≠ \(elements.count)")
                }
                let missing = Set(elements.compactMap(\.imageID)).subtracting(read.images.keys)
                if !missing.isEmpty {
                    throw WriteError.verifyFailed("\(index + 1)쪽 사진 \(missing.count)장이 빠짐")
                }
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
