//
//  DrawingJournal.swift
//  BadNotes
//
//  획이 바뀔 때마다 곧바로 남기는 복구 기록 (페이지별 PKDrawing 파일).
//  PDF 저장은 무거워서 몇 초 모아서 하는데, 그 사이 앱이 죽거나 PDF 저장이 실패해도
//  다음에 열 때 여기서 되살림. PDF 저장에 성공한 페이지는 지움.
//

import Foundation
import PencilKit

nonisolated struct DrawingJournal: Sendable {
    let directory: URL

    init(documentURL: URL) {
        directory = AppPaths.journal.appendingPathComponent(AppPaths.key(for: documentURL), isDirectory: true)
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// 빈 필기(전부 지움)도 기록해야 복구할 때 지운 상태가 살아남음
    func write(_ drawing: PKDrawing, page: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try drawing.dataRepresentation().write(to: file(for: page), options: .atomic)
    }

    func remove(page: Int) {
        try? FileManager.default.removeItem(at: file(for: page))
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    func load() -> (pages: [Int: PKDrawing], problems: [String]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ([:], [])
        }
        var pages: [Int: PKDrawing] = [:]
        var problems: [String] = []
        for file in files where file.pathExtension == "drawing" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("page"), let index = Int(name.dropFirst(4)) else { continue }
            do {
                pages[index] = try PKDrawing(data: Data(contentsOf: file))
            } catch {
                problems.append("\(index + 1)쪽 필기 파일 읽기 실패: \(error.localizedDescription)")
            }
        }
        return (pages, problems)
    }

    private func file(for page: Int) -> URL {
        directory.appendingPathComponent("page\(page).drawing")
    }
}
