//
//  NoteLoader.swift
//  BadNotes
//
//  문서를 열 때: PDF를 읽고, BadNotes 필기 주석을 꺼내서 PKDrawing으로 바꿈.
//  화면에서는 캔버스가 필기를 그리므로, 화면용 PDFDocument에서는 그 주석을 떼어 냄
//  (안 떼면 같은 필기가 두 번 그려지고, 지운 획이 주석에 남아 보임).
//

import PDFKit
import PencilKit

/// 백그라운드에서 읽은 결과를 메인 스레드로 넘기기 위한 상자
nonisolated final class LoadedNote: @unchecked Sendable {
    let pdf: PDFDocument
    let drawings: [Int: PKDrawing]
    let problems: [String]

    init(pdf: PDFDocument, drawings: [Int: PKDrawing], problems: [String]) {
        self.pdf = pdf
        self.drawings = drawings
        self.problems = problems
    }
}

nonisolated enum NoteLoader {
    enum LoadError: LocalizedError {
        case unreadable
        case locked

        var errorDescription: String? {
            switch self {
            case .unreadable: "PDF를 열 수 없음 (손상됐거나 PDF가 아님)"
            case .locked: "암호가 걸린 PDF는 아직 지원 안 함"
            }
        }
    }

    static func load(_ url: URL) throws -> LoadedNote {
        let data = try coordinatedRead(url)
        guard let pdf = PDFDocument(data: data) else { throw LoadError.unreadable }
        if pdf.isLocked { throw LoadError.locked }

        var drawings: [Int: PKDrawing] = [:]
        var problems: [String] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let read = InkPayload.read(from: page)
            for annotation in read.annotations {
                page.removeAnnotation(annotation)
            }
            if !read.drawing.strokes.isEmpty {
                drawings[index] = read.drawing
            }
            problems += read.problems.map { "\(index + 1)쪽: \($0)" }
        }
        return LoadedNote(pdf: pdf, drawings: drawings, problems: problems)
    }

    /// 파일 앱 등 다른 프로세스와 겹치지 않게 조율해서 읽음.
    /// 메모리 매핑이라 큰 PDF도 메모리를 거의 안 쓰고, 나중에 파일이 교체돼도 옛 내용을 계속 읽을 수 있음.
    static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(LoadError.unreadable)
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { source in
            result = Result { try Data(contentsOf: source, options: .alwaysMapped) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
