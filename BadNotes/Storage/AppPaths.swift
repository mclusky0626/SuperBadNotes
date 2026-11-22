//
//  AppPaths.swift
//  BadNotes
//
//  앱이 쓰는 폴더.
//  - Documents: 사용자 PDF (파일 앱에 그대로 보임)
//  - Application Support/BadNotes: 백업, 복구 기록, 옮겨 둔 옛 데이터 (파일 앱에 안 보임)
//

import Foundation
import CryptoKit

nonisolated enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BadNotes", isDirectory: true)
    }

    /// 덮어쓰기 전 PDF 사본. 용량이 커서 iCloud 백업에서는 뺌
    static var backups: URL { support.appendingPathComponent("Backups", isDirectory: true) }
    /// 획 단위 복구 기록
    static var journal: URL { support.appendingPathComponent("Journal", isDirectory: true) }
    /// PDF 안으로 옮기고 남은 옛 `.notes` 폴더
    static var migrated: URL { support.appendingPathComponent("Migrated", isDirectory: true) }

    @discardableResult
    static func ensure(_ dir: URL, excludeFromBackup: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if excludeFromBackup {
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return dir
    }

    /// Documents 기준 상대 경로 (Documents 밖이면 전체 경로)
    static func relativePath(_ url: URL) -> String {
        let root = documents.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// 문서마다 고유한 폴더 이름: 읽을 수 있는 이름 + 경로 해시
    static func key(for documentURL: URL) -> String {
        let digest = SHA256.hash(data: Data(relativePath(documentURL).utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = documentURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(name.prefix(40))-\(digest)"
    }

    /// 파일 이름에 쓰는 시각 (밀리초까지라 같은 초에 여러 번 찍어도 안 겹침)
    static func timestamp(_ date: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d-%03d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, (c.nanosecond ?? 0) / 1_000_000)
    }
}
