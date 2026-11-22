//
//  SelfTest.swift
//  BadNotes
//
//  저장 엔진 자체 점검 (디버그 빌드에만 들어감).
//  실행 인자 -BNSelfTest 를 주면 앱 화면 대신 이것만 돌고 콘솔에 [SELFTEST] 결과를 찍음.
//  실제 Documents는 건드리지 않고 임시 폴더에서만 함.
//
//    xcrun simctl launch --console-pty booted com.geonu9xpy.BadNotes -BNSelfTest
//

#if DEBUG
import PDFKit
import PencilKit
import UIKit

nonisolated enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-BNSelfTest") }

    private final class Results: @unchecked Sendable {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[SELFTEST] \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — \(detail())")")
        }
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String
    }

    static func run() async {
        let results = Results()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bn-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try engineTests(root: root, results)
            try migrationTests(root: root, results)
            journalTests(root: root, results)
            try await documentTests(root: root, results)
        } catch {
            results.check("예외 없이 끝남", false, "\(error)")
        }
        try? FileManager.default.removeItem(at: root)
        print("[SELFTEST] DONE passed=\(results.passed) failed=\(results.failed)")
    }

    // MARK: 저장 엔진

    private static func engineTests(root: URL, _ r: Results) throws {
        let url = root.appendingPathComponent("Test.pdf")
        try makePDF(url)
        guard let original = PDFDocument(url: url) else { throw TestError(description: "테스트 PDF 못 염") }
        let geometries = (0..<3).compactMap { original.page(at: $0).map(PageGeometry.init(page:)) }
        r.check("테스트 PDF 준비 (회전 90, 잘린 페이지)",
                geometries.count == 3 && geometries[1].rotation == 90 && geometries[2].box.minX == 50,
                "\(geometries)")

        let d0 = PKDrawing(strokes: [
            line(.pen, .black, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), width: 8),
            line(.marker, .systemYellow, CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 300), width: 20),
            line(.pencil, .blue, CGPoint(x: 100, y: 500), CGPoint(x: 400, y: 600), width: 4),
        ])
        let d1 = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100), width: 8)])
        let d2 = PKDrawing(strokes: [line(.monoline, .black, CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 50), width: 8)])

        let report = try PDFInkWriter.apply([0: d0, 1: d1, 2: d2], to: url)
        r.check("백그라운드 스레드에서 저장", !Thread.isMainThread && report.pages == 3)
        print("[SELFTEST] INFO 저장 \(report.bytes) bytes, \(String(format: "%.3f", report.seconds))초")
        keep(url, as: "stage1.pdf")

        // BadNotes로 다시 열기: 획과 위치가 그대로여야 함
        let loaded = try NoteLoader.load(url)
        for (index, expected) in [(0, d0), (1, d1), (2, d2)] {
            let got = loaded.drawings[index]
            r.check("\(index + 1)쪽 획 수 유지", got?.strokes.count == expected.strokes.count,
                    "\(got?.strokes.count ?? -1) ≠ \(expected.strokes.count)")
            r.check("\(index + 1)쪽 위치 유지", got.map { close($0.bounds, expected.bounds, 0.5) } ?? false,
                    "\(got?.bounds ?? .null) ≠ \(expected.bounds)")
            r.check("\(index + 1)쪽 화면용 문서에서 필기 주석 떼어 냄",
                    loaded.pdf.page(at: index)?.annotations.allSatisfy { !isInk($0) } ?? false)
        }

        // 다른 앱처럼 보기: 데이터가 아니라 appearance만으로 그려지는지
        guard let fresh = PDFDocument(url: url) else { throw TestError(description: "저장한 PDF 못 염") }
        let probes: [(Int, CGPoint, String)] = [
            (0, CGPoint(x: 200, y: 100), "회전 0"),
            (1, CGPoint(x: 300, y: 100), "회전 90"),
            (2, CGPoint(x: 175, y: 50), "잘린 페이지"),
        ]
        for (index, point, label) in probes {
            guard let page = fresh.page(at: index) else { continue }
            let image = render(page)
            keep(image, as: "page\(index).png")
            let ink = luminance(image, at: point)
            let blank = luminance(image, at: CGPoint(x: point.x, y: point.y + 60))
            r.check("다른 앱에서도 보임 (\(label))", ink < 0.5 && blank > 0.9,
                    "획 자리 밝기 \(ink), 빈 자리 밝기 \(blank)")
        }
        // 반투명 잉크: 노란 형광펜(곱하기 0.55) → 파랑 성분만 빠짐, 파란 연필(0.85) → 빨강 성분이 빠짐
        let page0Image = fresh.page(at: 0).flatMap(render)
        let marker = rgb(page0Image, at: CGPoint(x: 250, y: 300))
        r.check("다른 앱에서도 보임 (형광펜)", marker.r > 0.8 && marker.b < 0.75, "\(marker)")
        let pencil = rgb(page0Image, at: CGPoint(x: 250, y: 550))
        r.check("다른 앱에서도 보임 (연필)", pencil.r < 0.5 && pencil.b > 0.6, "\(pencil)")

        // 한 페이지만 고쳐도 나머지 페이지 필기(데이터와 모양)는 유지
        _ = try PDFInkWriter.apply([0: PKDrawing(strokes: [d0.strokes[0]])], to: url)
        let afterEdit = try NoteLoader.load(url)
        r.check("고친 페이지 반영", afterEdit.drawings[0]?.strokes.count == 1)
        r.check("안 고친 페이지 데이터 유지",
                afterEdit.drawings[1]?.strokes.count == 1 && afterEdit.drawings[2]?.strokes.count == 1)
        if let page1 = PDFDocument(url: url)?.page(at: 1) {
            r.check("안 고친 페이지 모양 유지", luminance(render(page1), at: CGPoint(x: 300, y: 100)) < 0.5)
        }

        // 필기를 다 지우면 주석도 사라짐
        _ = try PDFInkWriter.apply([2: PKDrawing()], to: url)
        r.check("빈 필기는 주석 삭제",
                PDFDocument(url: url)?.page(at: 2)?.annotations.allSatisfy { !isInk($0) } ?? false)

        // 다른 앱이 페이지를 회전시켜도 필기가 같이 돌아감
        guard let rotate = PDFDocument(url: url), let page0 = rotate.page(at: 0) else {
            throw TestError(description: "회전 테스트용 PDF 못 염")
        }
        page0.rotation = 90
        guard rotate.write(to: url) else { throw TestError(description: "회전 테스트용 PDF 못 씀") }
        let rotated = try NoteLoader.load(url)
        let b = rotated.drawings[0]?.bounds ?? .null
        // 회전 전 (100,100)-(300,100) 가로선 → 회전 후 (700,100)-(700,300) 세로선
        r.check("페이지 회전 후 필기 위치 따라감", abs(b.midX - 700) < 3 && abs(b.midY - 200) < 3, "\(b)")
        if let page = PDFDocument(url: url)?.page(at: 0) {
            r.check("페이지 회전 후 모양도 따라감", luminance(render(page), at: CGPoint(x: 700, y: 200)) < 0.5)
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        print("[SELFTEST] INFO 최종 파일 크기 \(size) bytes")
    }

    // MARK: 옛 데이터 옮기기

    private static func migrationTests(root: URL, _ r: Results) throws {
        let fm = FileManager.default
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        let migrated = root.appendingPathComponent("Migrated", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)

        let pdf = docs.appendingPathComponent("Mig.pdf")
        try makePDF(pdf)
        let notes = docs.appendingPathComponent("Mig.notes", isDirectory: true)
        let orphan = docs.appendingPathComponent("Orphan.notes", isDirectory: true)
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)

        let d = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), width: 8)])
        try d.dataRepresentation().write(to: notes.appendingPathComponent("page0.drawing"))
        try PKDrawing().dataRepresentation().write(to: notes.appendingPathComponent("page1.drawing"))
        try d.dataRepresentation().write(to: notes.appendingPathComponent("page9.drawing"))  // PDF에 없는 쪽
        try d.dataRepresentation().write(to: orphan.appendingPathComponent("page0.drawing"))

        var backedUp: [String] = []
        let report = LegacyMigration.run(documents: docs, migratedDir: migrated) { backedUp.append($0.lastPathComponent) }
        r.check("옮기기 결과", report.migrated.count == 1 && report.orphans.count == 1 && report.failed.isEmpty, "\(report)")
        r.check("옮기기 전에 백업", backedUp == ["Mig.pdf"], "\(backedUp)")

        let loaded = try NoteLoader.load(pdf)
        r.check("옛 필기가 PDF 안으로 들어감",
                loaded.drawings[0]?.strokes.count == 1 && loaded.drawings[1] == nil,
                "\(loaded.drawings.mapValues(\.strokes.count))")
        r.check("옛 폴더는 Documents에서 치움", !fm.fileExists(atPath: notes.path) && !fm.fileExists(atPath: orphan.path))
        let kept = (try? fm.contentsOfDirectory(atPath: migrated.path)) ?? []
        r.check("옛 폴더는 보관함에 남김", kept.count == 2, "\(kept)")
    }

    // MARK: 복구 기록

    private static func journalTests(root: URL, _ r: Results) {
        let journal = DrawingJournal(directory: root.appendingPathComponent("Journal", isDirectory: true))
        let d = PKDrawing(strokes: [line(.pen, .black, .zero, CGPoint(x: 10, y: 10), width: 2)])
        do {
            try journal.write(d, page: 3)
            try journal.write(PKDrawing(), page: 5)
            let loaded = journal.load()
            r.check("복구 기록 읽기 (빈 필기 포함)",
                    loaded.pages[3]?.strokes.count == 1 && loaded.pages[5]?.strokes.isEmpty == true && loaded.problems.isEmpty)
            journal.remove(page: 3)
            r.check("복구 기록 지우기", journal.load().pages[3] == nil)
        } catch {
            r.check("복구 기록 쓰기", false, "\(error)")
        }
    }

    // MARK: 열린 문서 (자동 저장, 복구 기록, 실패 후 재시도)

    @MainActor
    private static func documentTests(root: URL, _ r: Results) async throws {
        LegacyMigration.skipForTesting()
        let url = root.appendingPathComponent("Doc.pdf")
        try makePDF(url)
        defer {
            // 이 테스트가 앱 Application Support에 남긴 백업·복구 기록 정리
            let key = AppPaths.key(for: url)
            try? FileManager.default.removeItem(at: AppPaths.backups.appendingPathComponent(key))
            try? FileManager.default.removeItem(at: AppPaths.journal.appendingPathComponent(key))
        }
        let one = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), width: 8)])
        let two = PKDrawing(strokes: one.strokes + [line(.pen, .black, CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), width: 8)])
        func strokesInFile(_ page: Int) -> Int { (try? NoteLoader.load(url))?.drawings[page]?.strokes.count ?? 0 }
        func journalPages() -> [Int: PKDrawing] { DrawingJournal(documentURL: url).load().pages }
        func isSaved(_ state: NoteDocument.SaveState) -> Bool {
            if case .saved(.some) = state { return true }
            return false
        }

        // 1) 고치고 flush → PDF에 들어가고 복구 기록은 지워짐
        let doc = try await NoteDocument.open(url)
        doc.update(one, page: 0)
        r.check("고치면 저장 대기", doc.saveState == .pending && doc.hasUnsavedChanges)
        await doc.flush(reason: "점검")
        r.check("flush 후 저장됨", isSaved(doc.saveState) && !doc.hasUnsavedChanges, "\(doc.saveState)")
        r.check("flush한 필기가 PDF에 있음", strokesInFile(0) == 1)
        try? await Task.sleep(for: .milliseconds(300))
        r.check("저장 끝난 복구 기록은 지움", journalPages().isEmpty)

        // 2) PDF 저장 전에 앱이 죽은 상황: 복구 기록만 남고 문서는 사라짐 → 다시 열면 되살아남
        var crashing: NoteDocument? = try await NoteDocument.open(url)
        crashing?.update(two, page: 0)
        try? await Task.sleep(for: .milliseconds(900))  // 복구 기록(0.4초)은 쓰이고 PDF 저장(3초)은 아직
        r.check("복구 기록이 PDF보다 먼저 남음", journalPages()[0]?.strokes.count == 2 && strokesInFile(0) == 1)
        crashing = nil
        try? await Task.sleep(for: .seconds(4))
        r.check("사라진 문서는 뒤늦게 저장하지 않음", strokesInFile(0) == 1)
        let reopened = try await NoteDocument.open(url)
        r.check("다시 열면 복구 기록에서 되살림",
                reopened.drawing(for: 0).strokes.count == 2 && reopened.hasUnsavedChanges)
        await reopened.flush(reason: "점검")
        r.check("되살린 필기를 PDF에 저장", strokesInFile(0) == 2)

        // 3) 저장 실패 (원본이 잠깐 없어짐) → 실패 표시, 복구 기록 유지 → 원본이 돌아오면 다시 저장
        let failing = try await NoteDocument.open(url)
        failing.update(one, page: 2)
        let hidden = root.appendingPathComponent("hidden.pdf")
        try FileManager.default.moveItem(at: url, to: hidden)
        await failing.flush(reason: "실패 점검")
        if case .failed = failing.saveState {
            r.check("저장 실패 표시", true)
        } else {
            r.check("저장 실패 표시", false, "\(failing.saveState)")
        }
        try? await Task.sleep(for: .milliseconds(300))
        r.check("실패해도 복구 기록 남음", journalPages()[2]?.strokes.count == 1)
        try FileManager.default.moveItem(at: hidden, to: url)
        await failing.flush(reason: "재시도 점검")
        r.check("원본이 돌아오면 다시 저장", isSaved(failing.saveState) && strokesInFile(2) == 1 && strokesInFile(0) == 2,
                "\(failing.saveState)")
    }

    // MARK: 도구

    /// 눈으로 확인할 결과물을 앱 tmp/selftest-artifacts 에 남김 (지우지 않음)
    private static var artifacts: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func keep(_ file: URL, as name: String) {
        let dest = artifacts.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: file, to: dest)
    }

    private static func keep(_ image: CGImage?, as name: String) {
        guard let image, let data = UIImage(cgImage: image).pngData() else { return }
        try? data.write(to: artifacts.appendingPathComponent(name))
    }

    private static func isInk(_ annotation: PDFAnnotation) -> Bool {
        annotation.value(forAnnotationKey: InkPayload.inkKey) != nil
    }

    private static func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// 600×800 세 쪽짜리 PDF. 2쪽은 90도 회전, 3쪽은 crop box를 (50,100,500,600)으로
    private static func makePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError(description: "PDF 컨텍스트 못 만듦")
        }
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.85, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(url: url),
              let rotated = document.page(at: 1), let cropped = document.page(at: 2) else {
            throw TestError(description: "PDF 다시 못 염")
        }
        rotated.rotation = 90
        cropped.setBounds(CGRect(x: 50, y: 100, width: 500, height: 600), for: .cropBox)
        guard document.write(to: url) else { throw TestError(description: "PDF 못 씀") }
    }

    private static func line(_ ink: PKInk.InkType, _ color: UIColor, _ a: CGPoint, _ b: CGPoint,
                             width: CGFloat) -> PKStroke {
        let n = 40
        let points = (0...n).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(n)
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                 timeOffset: TimeInterval(i) * 0.01,
                                 size: CGSize(width: width, height: width),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(ink, color: color),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    /// 화면에 보이는 방향(회전 적용)으로 1pt = 1px 렌더링. 주석은 PDF에 저장된 appearance로 그려짐
    private static func render(_ page: PDFPage) -> CGImage? {
        let size = PageGeometry(page: page).canvasSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            // draw(with:to:)가 회전과 crop을 직접 적용함 (transform(_:for:)를 또 부르면 두 번 돌아감)
            page.draw(with: .cropBox, to: cg)
        }
        return image.cgImage
    }

    /// (x, y)는 위에서부터 잰 픽셀 좌표. 0(검정) ~ 1(흰색)
    private static func luminance(_ image: CGImage?, at p: CGPoint) -> CGFloat {
        let c = rgb(image, at: p)
        return c.r < 0 ? -1 : 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// 픽셀 색 (0~1). 못 읽으면 -1
    private static func rgb(_ image: CGImage?, at p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let image else { return (-1, -1, -1) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: -p.x, y: -(CGFloat(image.height) - p.y - 1),
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else { return (-1, -1, -1) }
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }
}
#endif
