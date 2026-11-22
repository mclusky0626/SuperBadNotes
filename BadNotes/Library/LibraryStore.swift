//
//  LibraryStore.swift
//  BadNotes
//
//  서재 = Documents 폴더 (파일 앱 › 나의 iPad › BadNotes 와 같은 곳).
//  폴더는 진짜 폴더, 문서는 PDF (노트북도 PDF). 즐겨찾기와 정렬만 따로 기억.
//  지우기는 바로 없애지 않고 앱 안 보관함(Application Support/BadNotes/Deleted)으로 옮김.
//

import SwiftUI
import Observation

nonisolated struct LibraryItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let modified: Date
    let isFolder: Bool
    /// 폴더 안 항목 수
    let childCount: Int
    var id: URL { url }
}

@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    nonisolated enum Sort: String, CaseIterable, Identifiable, Sendable {
        case modified, name
        var id: String { rawValue }
        var title: String { self == .modified ? "최근 수정순" : "이름순" }
    }

    enum LibraryError: LocalizedError {
        case invalidMove
        var errorDescription: String? { "폴더를 자기 안으로 옮길 수 없음" }
    }

    var sort: Sort {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: "librarySort")
            changed()
        }
    }

    private(set) var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }

    /// 바뀌면 화면이 목록을 다시 읽음
    private(set) var revision = 0

    var root: URL { AppPaths.documents }

    private init() {
        sort = Sort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .modified
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    }

    func changed() {
        revision += 1
    }

    // MARK: 읽기

    func items(in folder: URL) async -> [LibraryItem] {
        let sort = sort
        return await Task.detached(priority: .userInitiated) {
            Self.sorted(Self.scan(folder), by: sort)
        }.value
    }

    func favoriteItems() async -> [LibraryItem] {
        let sort = sort, favorites = favorites, root = root
        return await Task.detached(priority: .userInitiated) {
            Self.sorted(Self.scanAll(root).filter { favorites.contains(AppPaths.relativePath($0.url)) }, by: sort)
        }.value
    }

    /// 옮길 수 있는 곳: 맨 위 + 모든 하위 폴더
    func allFolders() async -> [URL] {
        let root = root
        return await Task.detached(priority: .userInitiated) { Self.folders(under: root) }.value
    }

    nonisolated static func folders(under root: URL) -> [URL] {
        var result = [root]
        var queue = [root]
        while let folder = queue.popLast() {
            for item in scan(folder) where item.isFolder {
                result.append(item.url)
                queue.append(item.url)
            }
        }
        return result
    }

    nonisolated static func scan(_ folder: URL) -> [LibraryItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            if values?.isDirectory == true {
                guard url.pathExtension != "notes" else { return nil }
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles])) ?? []
                let count = children.filter {
                    $0.pathExtension.lowercased() == "pdf"
                        || ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                }.count
                return LibraryItem(url: url, name: url.lastPathComponent, modified: modified, isFolder: true, childCount: count)
            }
            guard url.pathExtension.lowercased() == "pdf" else { return nil }
            return LibraryItem(url: url, name: url.deletingPathExtension().lastPathComponent, modified: modified,
                               isFolder: false, childCount: 0)
        }
    }

    /// 하위 폴더까지 모든 문서
    nonisolated static func scanAll(_ root: URL) -> [LibraryItem] {
        var result: [LibraryItem] = []
        var queue = [root]
        while let folder = queue.popLast() {
            for item in scan(folder) {
                if item.isFolder { queue.append(item.url) } else { result.append(item) }
            }
        }
        return result
    }

    /// 폴더 먼저, 그다음 정렬 기준대로
    nonisolated static func sorted(_ items: [LibraryItem], by sort: Sort) -> [LibraryItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .modified:
                return a.modified > b.modified
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: 즐겨찾기

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains(AppPaths.relativePath(url))
    }

    func toggleFavorite(_ url: URL) {
        let key = AppPaths.relativePath(url)
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
    }

    /// 이름을 바꾸거나 옮기면 즐겨찾기도 따라감 (폴더면 안에 있는 것까지)
    private func moveFavorites(from old: URL, to new: URL) {
        let oldKey = AppPaths.relativePath(old), newKey = AppPaths.relativePath(new)
        favorites = Set(favorites.map { key in
            if key == oldKey { return newKey }
            if key.hasPrefix(oldKey + "/") { return newKey + key.dropFirst(oldKey.count) }
            return key
        })
    }

    private func dropFavorites(under url: URL) {
        let key = AppPaths.relativePath(url)
        favorites = favorites.filter { $0 != key && !$0.hasPrefix(key + "/") }
    }

    // MARK: 만들기·고치기

    func createFolder(named name: String, in folder: URL) throws -> URL {
        let url = uniqueURL(base: cleaned(name, fallback: "새 폴더"), ext: nil, in: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        changed()
        return url
    }

    func createNotebook(name: String, cover: CoverStyle?, paper: PaperSpec, in folder: URL) throws -> URL {
        let title = cleaned(name, fallback: "이름 없는 노트북")
        let url = uniqueURL(base: title, ext: "pdf", in: folder)
        try PaperRenderer.notebookPDF(name: title, cover: cover, paper: paper).write(to: url, options: .atomic)
        Log.info("노트북 만듦: \(url.lastPathComponent) (\(paper.template.title), \(paper.tone.title))")
        changed()
        return url
    }

    /// 파일 앱에서 고른 PDF를 지금 폴더로 복사. 이미 서재 안에 있는 파일이면 그대로 씀
    func importPDF(_ source: URL, into folder: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if AppPaths.isInsideDocuments(source) { return source }
        let url = uniqueURL(base: source.deletingPathExtension().lastPathComponent, ext: "pdf", in: folder)
        try FileManager.default.copyItem(at: source, to: url)
        Log.info("PDF 가져옴: \(url.lastPathComponent)")
        changed()
        return url
    }

    func rename(_ item: LibraryItem, to newName: String) throws -> URL {
        let name = cleaned(newName, fallback: item.name)
        guard name != item.name else { return item.url }
        let target = uniqueURL(base: name, ext: item.isFolder ? nil : "pdf", in: item.url.deletingLastPathComponent())
        try coordinatedMove(item.url, to: target)
        moveFavorites(from: item.url, to: target)
        changed()
        return target
    }

    func move(_ item: LibraryItem, to folder: URL) throws -> URL {
        let from = item.url.standardizedFileURL.path, to = folder.standardizedFileURL.path
        guard to != item.url.deletingLastPathComponent().standardizedFileURL.path else { return item.url }
        if item.isFolder, to == from || to.hasPrefix(from + "/") { throw LibraryError.invalidMove }
        let target = uniqueURL(base: item.name, ext: item.isFolder ? nil : "pdf", in: folder)
        try coordinatedMove(item.url, to: target)
        moveFavorites(from: item.url, to: target)
        changed()
        return target
    }

    func delete(_ item: LibraryItem) throws {
        let bin = try AppPaths.ensure(AppPaths.support.appendingPathComponent("Deleted", isDirectory: true),
                                      excludeFromBackup: true)
        try coordinatedMove(item.url, to: bin.appendingPathComponent("\(AppPaths.timestamp())-\(item.url.lastPathComponent)"))
        dropFavorites(under: item.url)
        Log.info("보관함으로 옮김: \(item.name)")
        changed()
    }

    // MARK: 도구

    func uniqueURL(base: String, ext: String?, in folder: URL) -> URL {
        func make(_ name: String) -> URL {
            if let ext { return folder.appendingPathComponent(name).appendingPathExtension(ext) }
            return folder.appendingPathComponent(name, isDirectory: true)
        }
        var candidate = make(base)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(number)")
            number += 1
        }
        return candidate
    }

    private func cleaned(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func coordinatedMove(_ source: URL, to target: URL) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forMoving,
                                                         writingItemAt: target, options: .forReplacing,
                                                         error: &coordinationError) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }
}

extension Date {
    /// 오늘 오후 2:03 / 어제 오후 8:05 / 2026. 11. 17. 오후 2:40
    var libraryLabel: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return "오늘 \(time)" }
        if calendar.isDateInYesterday(self) { return "어제 \(time)" }
        return formatted(date: .numeric, time: .shortened)
    }
}
