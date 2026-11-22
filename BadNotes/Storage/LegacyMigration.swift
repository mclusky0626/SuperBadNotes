//
//  LegacyMigration.swift
//  BadNotes
//
//  옛 저장 방식(<이름>.notes/pageN.drawing)을 PDF 안으로 옮김. 앱 시작할 때 한 번.
//  - 옮기기 전 PDF는 백업 (지워지지 않게 영구 보관)
//  - 옛 폴더는 지우지 않고 Application Support/BadNotes/Migrated 로 옮겨 둠
//  - 실패한 문서는 옛 폴더를 그대로 둬서 다음 실행 때 다시 시도
//

import PDFKit
import PencilKit

nonisolated enum LegacyMigration {
    struct Report: Sendable, CustomStringConvertible {
        var migrated: [String] = []
        var orphans: [String] = []
        var failed: [String] = []

        var description: String { "옮김 \(migrated), PDF 없음 \(orphans), 실패 \(failed)" }
    }

    @MainActor private static var task: Task<Void, Never>?

    @MainActor static func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .userInitiated) {
            let report = run(documents: AppPaths.documents, migratedDir: AppPaths.migrated) { pdf in
                try BackupStore.snapshot(pdf, reason: BackupStore.permanentTag)
            }
            for line in report.migrated { Log.info("옛 필기를 PDF 안으로 옮김: \(line)") }
            for line in report.orphans { Log.warn("PDF가 없는 옛 필기 폴더는 보관함으로 옮김: \(line)") }
            for line in report.failed { Log.error("옛 필기 옮기기 실패: \(line)") }
        }
    }

    /// 문서를 열기 전에 기다림 (옮기는 중인 PDF를 열지 않게)
    @MainActor static func waitUntilDone() async {
        if task == nil { start() }
        await task?.value
    }

    #if DEBUG
    /// 자체 점검이 실제 Documents를 옮기지 않게
    @MainActor static func skipForTesting() {
        if task == nil { task = Task {} }
    }
    #endif

    static func run(documents: URL, migratedDir: URL, backup: (URL) throws -> Void) -> Report {
        var report = Report()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) else {
            return report
        }
        for notes in items where notes.pathExtension == "notes" {
            let name = notes.deletingPathExtension().lastPathComponent
            let pdf = notes.deletingPathExtension().appendingPathExtension("pdf")
            do {
                guard fm.fileExists(atPath: pdf.path) else {
                    try moveAside(notes, into: migratedDir, tag: "orphan")
                    report.orphans.append(name)
                    continue
                }
                let legacy = DrawingJournal(directory: notes).load()
                for problem in legacy.problems { Log.warn("\(name): \(problem)") }
                let pageCount = PDFDocument(url: pdf)?.pageCount ?? 0
                let pages = legacy.pages.filter { !$0.value.strokes.isEmpty }
                let valid = pages.filter { $0.key < pageCount }
                if valid.count < pages.count {
                    Log.warn("\(name): PDF에 없는 쪽의 옛 필기 \(pages.count - valid.count)개는 건너뜀 (보관함에 남음)")
                }
                if !valid.isEmpty {
                    try backup(pdf)
                    _ = try PDFInkWriter.apply(valid, to: pdf)
                }
                try moveAside(notes, into: migratedDir, tag: "migrated")
                report.migrated.append("\(name) (\(valid.count)쪽)")
            } catch {
                report.failed.append("\(name): \(error.localizedDescription)")
            }
        }
        return report
    }

    private static func moveAside(_ dir: URL, into parent: URL, tag: String) throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let base = dir.deletingPathExtension().lastPathComponent
        let dest = parent.appendingPathComponent("\(base)-\(tag)-\(AppPaths.timestamp()).notes", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: dest)
    }
}
