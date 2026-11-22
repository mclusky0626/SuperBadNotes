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

    struct Recovered {
        var drawings: [Int: PKDrawing] = [:]
        var elements: [Int: [PageElement]] = [:]
        var images: [String: Data] = [:]
        var problems: [String] = []
        /// 필기만 (옛 코드·자체 점검용 이름)
        var pages: [Int: PKDrawing] { drawings }
        var allPages: Set<Int> { Set(drawings.keys).union(elements.keys) }
    }

    /// 빈 필기(전부 지움)도 기록해야 복구할 때 지운 상태가 살아남음
    func write(_ drawing: PKDrawing, page: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try drawing.dataRepresentation().write(to: file(for: page), options: .atomic)
    }

    /// 페이지 요소(텍스트 상자·메모지·사진). 사진 원본은 한 번만 따로 씀
    func write(_ elements: [PageElement], images: [String: Data], page: Int) throws {
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        for (id, data) in images {
            let url = imageDirectory.appendingPathComponent(id)
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        }
        try JSONEncoder().encode(elements).write(to: elementsFile(for: page), options: .atomic)
    }

    func remove(page: Int) {
        try? FileManager.default.removeItem(at: file(for: page))
        try? FileManager.default.removeItem(at: elementsFile(for: page))
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    func load() -> Recovered {
        var result = Recovered()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return result
        }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("page"), let index = Int(name.dropFirst(4)) else { continue }
            switch file.pathExtension {
            case "drawing":
                do {
                    result.drawings[index] = try PKDrawing(data: Data(contentsOf: file))
                } catch {
                    result.problems.append("\(index + 1)쪽 필기 파일 읽기 실패: \(error.localizedDescription)")
                }
            case "elements":
                do {
                    let elements = try JSONDecoder().decode([PageElement].self, from: Data(contentsOf: file))
                    result.elements[index] = elements
                    for id in Set(elements.compactMap(\.imageID)) {
                        if let data = try? Data(contentsOf: imageDirectory.appendingPathComponent(id)) { result.images[id] = data }
                    }
                } catch {
                    result.problems.append("\(index + 1)쪽 요소 파일 읽기 실패: \(error.localizedDescription)")
                }
            default:
                break
            }
        }
        return result
    }

    private var imageDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    private func elementsFile(for page: Int) -> URL {
        directory.appendingPathComponent("page\(page).elements")
    }

    private func file(for page: Int) -> URL {
        directory.appendingPathComponent("page\(page).drawing")
    }
}
