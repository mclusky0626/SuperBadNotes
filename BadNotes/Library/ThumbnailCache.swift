//
//  ThumbnailCache.swift
//  BadNotes
//
//  서재 카드 표지 = PDF 첫 페이지 (노트북이면 표지, 필기도 같이 보임).
//  파일이 바뀌면(수정 시각) 새로 그림. 메모리 + Caches 폴더에 기억.
//

import UIKit
import PDFKit
import CryptoKit

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private var memory: [String: UIImage] = [:]

    private var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    func image(for url: URL, modified: Date, maxPixel: CGFloat) -> UIImage? {
        let key = "\(url.path)#\(Int(modified.timeIntervalSince1970 * 1000))#\(Int(maxPixel))"
        if let hit = memory[key] { return hit }

        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent("\(name).jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            remember(image, key)
            return image
        }

        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let size = PageGeometry(page: page).canvasSize
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxPixel / max(size.width, size.height)
        let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.jpegData(compressionQuality: 0.85)?.write(to: file, options: .atomic)
        remember(image, key)
        return image
    }

    private func remember(_ image: UIImage, _ key: String) {
        if memory.count > 200 { memory.removeAll() }
        memory[key] = image
    }
}
