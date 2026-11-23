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

        // 확장자가 .badnote여도 속은 PDF라서 데이터로 엶
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let document = PDFDocument(data: data),
              let page = document.page(at: 0) else { return nil }
        let board = PaperSpec.isBoard(document.documentAttributes)
        guard let image = board ? Self.renderBoard(page, maxPixel: maxPixel) : Self.render(page, maxPixel: maxPixel) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 손실 없는 PNG (JPEG는 글자·선 둘레가 뭉개짐)
        try? image.pngData()?.write(to: file, options: .atomic)
        remember(image, key)
        return image
    }

    /// 화이트보드는 판 전체가 아니라 쓴 곳 둘레만 (세로 카드 비율로)
    private static func renderBoard(_ page: PDFPage, maxPixel: CGFloat) -> UIImage? {
        let box = page.bounds(for: .cropBox)
        var content = page.annotations.reduce(CGRect.null) { $0.union($1.bounds) }
        if content.isNull || content.isEmpty {
            content = CGRect(x: box.midX - 450, y: box.midY - 600, width: 900, height: 1200)
        }
        // 카드 비율(3:4)로 넓히고 여백
        var region = content.insetBy(dx: -100, dy: -100)
        let ratio: CGFloat = 0.75
        if region.width / region.height > ratio {
            let h = region.width / ratio
            region = region.insetBy(dx: 0, dy: -(h - region.height) / 2)
        } else {
            let w = region.height * ratio
            region = region.insetBy(dx: -(w - region.width) / 2, dy: 0)
        }
        let scale = maxPixel / max(region.width, region.height)
        let pixels = CGSize(width: (region.width * scale).rounded(), height: (region.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(red: 0.985, green: 0.983, blue: 0.975, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: pixels))
            // 점 무늬
            cg.setFillColor(UIColor(white: 0.75, alpha: 1).cgColor)
            let step = 32 * scale
            if step >= 5 {
                var y = (32 - region.minY.truncatingRemainder(dividingBy: 32)) * scale
                while y < pixels.height {
                    var x = (32 - region.minX.truncatingRemainder(dividingBy: 32)) * scale
                    while x < pixels.width {
                        cg.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                        x += step
                    }
                    y += step
                }
            }
            cg.translateBy(x: 0, y: pixels.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -region.minX, y: -region.minY)
            page.draw(with: .cropBox, to: cg)
        }
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
