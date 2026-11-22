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
        let key = "v2#\(url.path)#\(Int(modified.timeIntervalSince1970 * 1000))#\(Int(maxPixel))"
        if let hit = memory[key] { return hit }

        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent("\(name).png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            remember(image, key)
            return image
        }

        guard let document = PDFDocument(url: url), let page = document.page(at: 0),
              let image = Self.render(page, maxPixel: maxPixel) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 손실 없는 PNG (JPEG는 글자·선 둘레가 뭉개짐)
        try? image.pngData()?.write(to: file, options: .atomic)
        remember(image, key)
        return image
    }

    /// 화면 픽셀 그대로 직접 그림 (PDFKit 썸네일은 배율이 들쭉날쭉하고 흐림)
    private static func render(_ page: PDFPage, maxPixel: CGFloat) -> UIImage? {
        let size = PageGeometry(page: page).canvasSize
        guard size.width > 0, size.height > 0, maxPixel > 0 else { return nil }
        let scale = maxPixel / max(size.width, size.height)
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: pixels))
            cg.interpolationQuality = .high
            cg.setShouldAntialias(true)
            cg.translateBy(x: 0, y: pixels.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: cg)
        }
        return image
    }

    private func remember(_ image: UIImage, _ key: String) {
        if memory.count > 200 { memory.removeAll() }
        memory[key] = image
    }
}
