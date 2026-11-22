//
//  ThemeStore.swift
//  BadNotes
//
//  지금 테마 + 내 테마 목록 + 배경 사진. Application Support/BadNotes/Theme 에 저장.
//  화면 어디서든 @Environment(ThemeStore.self)로 꺼내서 유리·강조색을 씀.
//

import SwiftUI
import Observation

@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var theme: Theme {
        didSet { if theme != oldValue { scheduleSave() } }
    }

    var myThemes: [Theme] {
        didSet { Self.write(myThemes, to: Self.mineURL) }
    }

    private(set) var photo: UIImage?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        theme = Self.read(Theme.self, from: Self.themeURL) ?? .standard
        myThemes = Self.read([Theme].self, from: Self.mineURL) ?? []
        photo = UIImage(contentsOfFile: Self.photoURL.path)
    }

    // MARK: 지금 테마에서 나오는 값

    /// 앱 전체 유리 재질
    var glass: Glass { theme.glass }

    var accent: Color { theme.accent.color }

    var colorScheme: ColorScheme? {
        switch theme.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: 바꾸기

    func apply(_ preset: Theme) {
        theme = preset
    }

    func saveCurrent(named name: String) {
        var copy = theme
        copy.id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        copy.name = trimmed.isEmpty ? "내 테마 \(myThemes.count + 1)" : trimmed
        myThemes.append(copy)
    }

    func deleteMine(at offsets: IndexSet) {
        myThemes.remove(atOffsets: offsets)
    }

    /// 배경 사진. 너무 크면 줄여서 저장
    func setPhoto(_ data: Data) {
        guard let image = UIImage(data: data) else {
            Log.error("배경 사진을 읽을 수 없음")
            return
        }
        let scaled = Self.downscale(image, maxSide: 2400)
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            guard let jpeg = scaled.jpegData(compressionQuality: 0.88) else { throw CocoaError(.fileWriteUnknown) }
            try jpeg.write(to: Self.photoURL, options: .atomic)
            photo = scaled
            theme.base = .photo
        } catch {
            Log.error("배경 사진 저장 실패: \(error.localizedDescription)")
        }
    }

    // MARK: 파일

    private static var folder: URL { AppPaths.support.appendingPathComponent("Theme", isDirectory: true) }
    private static var themeURL: URL { folder.appendingPathComponent("theme-v2.json") }
    private static var mineURL: URL { folder.appendingPathComponent("my-themes-v2.json") }
    private static var photoURL: URL { folder.appendingPathComponent("background.jpg") }

    /// 슬라이더를 끄는 동안 계속 쓰지 않게 잠깐 모았다가 저장
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = theme
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: Self.themeURL)
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Log.error("테마 저장 실패: \(error.localizedDescription)")
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
