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
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-BNCanvasProbe") {
            await canvasProbe()
            return
        }
        if let i = args.firstIndex(of: "-BNCompare"), i + 1 < args.count {
            await compare(args[i + 1])
            return
        }
        let results = Results()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bn-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try engineTests(root: root, results)
            try migrationTests(root: root, results)
            journalTests(root: root, results)
            inkEngineTests(results)
            highlighterTests(results)
            await pencilKitMatchTests(results)
            try await documentTests(root: root, results)
            try await notebookTests(root: root, results)
            try elementTests(root: root, results)
            try coverTests(root: root, results)
            await maskMatchesPencilKit(results)
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

    // MARK: 직접 필기 엔진

    private static func inkEngineTests(_ r: Results) {
        func sample(_ i: Int, force: CGFloat?) -> InputSample {
            InputSample(location: CGPoint(x: 10 + CGFloat(i) * 4, y: 100), time: Double(i) * 0.01,
                        force: force, azimuth: 0, altitude: .pi / 2)
        }

        // 입력 → 획
        var brush = StrokeBuilder(inkType: .pen, color: .black, width: 3, pressureRange: 0.3...1.6, startTime: 0)
        for i in 0...50 { brush.add(sample(i, force: i < 25 ? 0.08 : 0.7)) }
        let brushWidths = InkRenderer.sample(brush.makeStroke()!).points.map(\.width)
        r.check("붓펜: 필압에 따라 굵기가 변함",
                (brushWidths.min() ?? 0) < (brushWidths.max() ?? 0) * 0.5,
                "\(brushWidths.min() ?? 0) ~ \(brushWidths.max() ?? 0)")

        var ballpoint = StrokeBuilder(inkType: .monoline, color: .black, width: 2.2, startTime: 0)
        for i in 0...50 { ballpoint.add(sample(i, force: i < 25 ? 0.08 : 0.7)) }
        let ballpointWidths = InkRenderer.sample(ballpoint.makeStroke()!).points.map(\.width)
        r.check("볼펜: 굵기 일정하고 고른 굵기 그대로 (2.2pt)",
                ballpointWidths.allSatisfy { abs($0 - 2.2) < 0.01 },
                "\(ballpointWidths.min() ?? 0) ~ \(ballpointWidths.max() ?? 0)")

        var marker = StrokeBuilder(inkType: .marker, color: .yellow, width: 16, startTime: 0)
        for i in 0...50 { marker.add(sample(i, force: 0.5)) }
        let markerWidths = InkRenderer.sample(marker.makeStroke()!).points.map(\.width)
        r.check("형광펜: 가로로 그으면 고른 굵기 그대로 (16pt)",
                markerWidths.allSatisfy { abs($0 - 16) < 0.05 }, "\(markerWidths.first ?? 0)")

        var dot = StrokeBuilder(inkType: .pen, color: .black, width: 3, startTime: 0)
        dot.add(sample(0, force: nil))
        r.check("콕 찍은 점도 획이 됨", dot.makeStroke()?.path.count == 2)

        // 지우개
        let horizontal = line(.pen, .black, CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100), width: 4)
        let sampled = InkRenderer.sample(horizontal)
        let pieces = StrokeEditing.erase(horizontal, sampled: sampled, from: CGPoint(x: 100, y: 80),
                                         to: CGPoint(x: 100, y: 120), radius: 5)
        r.check("부분 지우개: 획은 하나 그대로, 마스크로만 잘림", pieces?.count == 1 && pieces?.first?.mask != nil,
                "\(pieces?.count ?? -1)")
        if let cut = pieces?.first {
            let same = cut.path.count == horizontal.path.count
                && zip(cut.path, horizontal.path).allSatisfy { $0.location == $1.location && $0.size == $1.size }
            r.check("부분 지우개: 남은 획 모양(점·굵기·씨앗)이 안 바뀜", same && cut.randomSeed == horizontal.randomSeed)
            let image = renderStrokes([cut], size: CGSize(width: 220, height: 200))
            r.check("부분 지우개: 지운 자리는 비고 양옆은 남음",
                    luminance(image, at: CGPoint(x: 100, y: 100)) > 0.9
                        && luminance(image, at: CGPoint(x: 60, y: 100)) < 0.5
                        && luminance(image, at: CGPoint(x: 140, y: 100)) < 0.5,
                    "가운데 \(luminance(image, at: CGPoint(x: 100, y: 100)))")
            // 한 번 더 지우면 마스크 모양이 바뀌어서 다른 획으로 알아봐야 다시 그림
            let s2 = InkRenderer.sample(cut)
            if let again = StrokeEditing.erase(cut, sampled: s2, from: CGPoint(x: 40, y: 80), to: CGPoint(x: 40, y: 120),
                                               radius: 5)?.first {
                r.check("부분 지우개: 두 번째로 지우면 키가 바뀜", StrokeKey(again) != StrokeKey(cut))
                let twice = renderStrokes([again], size: CGSize(width: 220, height: 200))
                r.check("부분 지우개: 두 군데 다 비어 있음",
                        luminance(twice, at: CGPoint(x: 40, y: 100)) > 0.9 && luminance(twice, at: CGPoint(x: 100, y: 100)) > 0.9
                            && luminance(twice, at: CGPoint(x: 70, y: 100)) < 0.5)
            } else {
                r.check("부분 지우개: 두 번째 지우기", false, "안 닿음")
            }
        }
        let wiped = StrokeEditing.erase(horizontal, sampled: sampled, from: CGPoint(x: -10, y: 100),
                                        to: CGPoint(x: 210, y: 100), radius: 30)
        r.check("부분 지우개: 전부 지우면 획이 없어짐", wiped?.isEmpty == true, "\(wiped?.count ?? -1)")
        let highlight = line(.monoline, UIColor.systemYellow.withAlphaComponent(0.5), .zero, CGPoint(x: 50, y: 0), width: 12)
        r.check("형광펜만 지우기: 형광펜·마커는 형광펜, 펜은 아님",
                StrokeEditing.isHighlighter(highlight)
                    && StrokeEditing.isHighlighter(line(.marker, .systemYellow, .zero, CGPoint(x: 50, y: 0), width: 12))
                    && !StrokeEditing.isHighlighter(horizontal))
        r.check("부분 지우개: 안 닿으면 그대로",
                StrokeEditing.erase(horizontal, sampled: sampled, from: CGPoint(x: 100, y: 150),
                                    to: CGPoint(x: 120, y: 150), radius: 5) == nil)
        r.check("획 지우개: 닿으면 통째로",
                StrokeEditing.touches(sampled, from: CGPoint(x: 50, y: 90), to: CGPoint(x: 50, y: 110), radius: 3))

        // 올가미
        let far = InkRenderer.sample(line(.pen, .black, CGPoint(x: 0, y: 400), CGPoint(x: 200, y: 400), width: 4))
        let picked = StrokeEditing.select([sampled, far], lasso: CGPath(rect: CGRect(x: -10, y: 50, width: 230, height: 100),
                                                                       transform: nil))
        r.check("올가미: 안에 있는 획만 고름", picked == [0], "\(picked)")
        let moved = StrokeEditing.translated(horizontal, by: CGVector(dx: 30, dy: 40))
        r.check("옮기기: 위치가 바뀜",
                abs(moved.renderBounds.minX - horizontal.renderBounds.minX - 30) < 0.5
                    && abs(moved.renderBounds.minY - horizontal.renderBounds.minY - 40) < 0.5,
                "\(moved.renderBounds)")
        r.check("복제: 원본과 다른 획으로 구분됨",
                StrokeKey(StrokeEditing.duplicated(horizontal, by: .zero)) != StrokeKey(horizontal))

        // 페이지 필기: 더한 획 자리만 다시 그림
        let ink = PageInk(drawing: PKDrawing(strokes: [horizontal]))
        _ = ink.renderStrokes()
        let added = line(.pen, .black, CGPoint(x: 0, y: 300), CGPoint(x: 200, y: 300), width: 4)
        let dirty = ink.replace(with: PKDrawing(strokes: [horizontal, added]))
        r.check("획을 더하면 그 자리만 다시 그림", dirty.minY > 290 && dirty.maxY < 310, "\(dirty)")
        r.check("같은 획은 같은 키 (다시 계산 안 함)", StrokeKey(horizontal) == StrokeKey(horizontal))
        r.check("형광펜은 반투명으로 그림",
                InkRenderer.sample(line(.marker, .systemYellow, .zero, CGPoint(x: 50, y: 0), width: 12)).translucent)
    }

    // MARK: 형광펜

    private static func highlighterTests(_ r: Results) {
        func sample(_ p: CGPoint, _ i: Int) -> InputSample {
            InputSample(location: p, time: Double(i) * 0.01, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        // 살짝 흔들리며 거의 수평으로 그은 줄 → 곧은 수평선
        var wobbly = StrokeBuilder(inkType: .monoline, color: .yellow.withAlphaComponent(0.5), width: 16, startTime: 0)
        for i in 0...60 {
            wobbly.add(sample(CGPoint(x: 20 + CGFloat(i) * 5, y: 100 + sin(CGFloat(i) / 3) * 2 + CGFloat(i) * 0.05), i))
        }
        let straight = wobbly.straightened()?.makeStroke()
        let ys = straight?.path.map(\.location.y) ?? []
        r.check("형광펜: 거의 곧은 줄은 곧은 수평선으로", !ys.isEmpty && (ys.max()! - ys.min()!) < 0.01,
                "\(ys.min() ?? -1) ~ \(ys.max() ?? -1)")

        // 지그재그는 그대로
        var zigzag = StrokeBuilder(inkType: .monoline, color: .yellow, width: 16, startTime: 0)
        for i in 0...40 { zigzag.add(sample(CGPoint(x: 20 + CGFloat(i) * 6, y: 100 + (i % 2 == 0 ? 0 : 25)), i)) }
        r.check("형광펜: 지그재그는 펴지 않음", zigzag.straightened() == nil)

        // 형광펜 모양: 반투명 + 곱하기 (밑의 글자가 또렷), 방향과 상관없이 같은 굵기
        if let stroke = straight {
            let s = InkRenderer.sample(stroke)
            r.check("형광펜: 반투명 곱하기로 그림", s.translucent && s.blend == .multiply, "\(s.alpha) \(s.blend.rawValue)")
            r.check("형광펜: 고른 굵기 그대로 (16pt)", s.points.allSatisfy { abs($0.width - 16) < 0.05 },
                    "\(s.points.first?.width ?? 0)")
        }
        var vertical = StrokeBuilder(inkType: .monoline, color: .yellow.withAlphaComponent(0.5), width: 16, startTime: 0)
        for i in 0...40 { vertical.add(sample(CGPoint(x: 100, y: 20 + CGFloat(i) * 5), i)) }
        let verticalWidths = vertical.makeStroke().map { InkRenderer.sample($0).points.map(\.width) } ?? []
        r.check("형광펜: 세로로 그어도 같은 굵기", verticalWidths.allSatisfy { abs($0 - 16) < 0.05 },
                "\(verticalWidths.first ?? 0)")

        // 펜을 뗄 때 깜빡임 방지: 타일이 그린 영역 기록
        let ink = PageInk(drawing: PKDrawing())
        let key = StrokeKey(straight ?? line(.pen, .black, .zero, CGPoint(x: 10, y: 0), width: 4))
        ink.markPending([key])
        ink.recordDrawn(CGRect(x: 0, y: 0, width: 256, height: 256), keys: [key])
        r.check("깜빡임 방지: 막 그린 영역은 바로 지우지 않음", ink.coveredRects(for: key).isEmpty)
        Thread.sleep(forTimeInterval: 0.08)
        r.check("깜빡임 방지: 조금 뒤 타일이 그린 영역만큼 지움", ink.coveredRects(for: key).count == 1)
        ink.clearPending(key)
        r.check("깜빡임 방지: 다 끝나면 기록 정리", ink.coveredRects(for: key).isEmpty)
    }

    // MARK: 노트북

    @MainActor
    private static func notebookTests(root: URL, _ r: Results) async throws {
        let library = LibraryStore.shared
        let folder = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let paper = PaperSpec(template: .ruledWide, tone: .yellow, size: .a4Portrait)
        let url = try library.createNotebook(name: "점검 노트", cover: .forest, paper: paper, in: folder)
        guard let document = PDFDocument(url: url) else { throw TestError(description: "노트북 PDF 못 염") }
        r.check("노트북: 표지 + 종이 한 장", document.pageCount == 2, "\(document.pageCount)")
        r.check("노트북: 종이 정보가 PDF에 들어감",
                PaperSpec.from(documentAttributes: document.documentAttributes) == paper,
                "\(String(describing: document.documentAttributes?["Keywords"]))")
        if let cover = document.page(at: 0), let sheet = document.page(at: 1) {
            keep(render(cover), as: "notebook-cover.png")
            keep(render(sheet), as: "notebook-sheet.png")
            keep(url, as: "notebook.pdf")
            let coverColor = rgb(render(cover), at: CGPoint(x: 400, y: 600))
            r.check("노트북: 표지가 칠해짐 (숲색)", coverColor.g > coverColor.r && coverColor.r < 0.4, "\(coverColor)")
            // 넓은 줄: 첫 줄 y=80, 간격 32 → 112번째 줄은 y=80+32*1=112
            let onLine = luminance(render(sheet), at: CGPoint(x: 300, y: 112))
            let between = luminance(render(sheet), at: CGPoint(x: 300, y: 96))
            r.check("노트북: 줄친 종이에 줄이 있음", onLine < between - 0.03, "줄 \(onLine) / 사이 \(between)")
        }

        // 저장 엔진으로 페이지 덧붙이기 + 그 페이지에 필기
        let d = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), width: 6)])
        _ = try PDFInkWriter.apply([2: d], appending: [PaperRenderer.pagePDF(paper)], to: url)
        let appended = try NoteLoader.load(url)
        r.check("페이지 덧붙이기: 쪽수 늘어남", appended.pdf.pageCount == 3, "\(appended.pdf.pageCount)")
        r.check("페이지 덧붙이기: 새 페이지 필기 저장", appended.drawings[2]?.strokes.count == 1)
        r.check("페이지 덧붙이기: 종이 정보 유지",
                PaperSpec.from(documentAttributes: appended.pdf.documentAttributes) == paper)

        // 열린 문서에서 페이지 추가 → 같은 종이로, 저장까지
        LegacyMigration.skipForTesting()
        let note = try await NoteDocument.open(url)
        r.check("열린 노트북: 노트북으로 알아봄", note.isNotebook)
        let added = note.appendPage()
        note.update(d, page: added ?? 0)
        await note.flush(reason: "점검")
        let reloaded = try NoteLoader.load(url)
        r.check("열린 노트북: 페이지 추가가 파일에 저장", reloaded.pdf.pageCount == 4 && added == 3,
                "\(reloaded.pdf.pageCount) / \(added ?? -1)")
        r.check("열린 노트북: 새 페이지 필기도 저장", reloaded.drawings[3]?.strokes.count == 1)
        defer {
            let key = AppPaths.key(for: url)
            try? FileManager.default.removeItem(at: AppPaths.backups.appendingPathComponent(key))
            try? FileManager.default.removeItem(at: AppPaths.journal.appendingPathComponent(key))
        }

        // 서재: 같은 이름이면 번호 붙이기, 이름 바꾸기·옮기기에 즐겨찾기가 따라감
        let second = try library.createNotebook(name: "점검 노트", cover: nil, paper: paper, in: folder)
        r.check("서재: 같은 이름은 번호 붙임", second.lastPathComponent == "점검 노트 2.pdf", second.lastPathComponent)
        library.toggleFavorite(second)
        let renamed = try library.rename(LibraryItem(url: second, name: "점검 노트 2", modified: Date(),
                                                     isFolder: false, childCount: 0), to: "새 이름")
        r.check("서재: 이름 바꾸면 즐겨찾기 따라감", library.isFavorite(renamed) && !library.isFavorite(second))
        let sub = try library.createFolder(named: "하위", in: folder)
        let moved = try library.move(LibraryItem(url: renamed, name: "새 이름", modified: Date(), isFolder: false,
                                                 childCount: 0), to: sub)
        r.check("서재: 옮기면 즐겨찾기 따라감", library.isFavorite(moved) && moved.deletingLastPathComponent().lastPathComponent == "하위")
        library.toggleFavorite(moved)
        let listed = LibraryStore.sorted(LibraryStore.scan(folder), by: .modified)
        r.check("서재: 폴더 먼저, 문서는 PDF만", listed.first?.isFolder == true && listed.filter { !$0.isFolder }.count == 1,
                "\(listed.map(\.name))")
    }

    // MARK: PencilKit과 똑같이 보이는지

    /// 같은 획을 PencilKit(레이어 모드)과 우리 렌더러(직접 필기 모드·PDF)로 그려서 굵기를 비교
    @MainActor
    private static func pencilKitMatchTests(_ r: Results) {
        let cases: [(String, PKInk.InkType, CGFloat, Bool, CGFloat)] = [
            ("펜", .pen, 5, false, 0),
            ("볼펜", .monoline, 3.1, false, 0),
            ("형광펜 가로", .marker, 20, false, 0),
            ("형광펜 세로", .marker, 20, true, 0),
            ("만년필 가로", .fountainPen, 8, false, 0),
            ("만년필 세로", .fountainPen, 8, true, 0),
            ("만년필 비스듬한 펜촉", .fountainPen, 8, false, .pi / 4),
        ]
        let frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        if ProcessInfo.processInfo.arguments.contains("-BNCalibrate") {
            for size in [CGFloat(10), 20, 33, 50] {
                var line = "[SELFTEST] INFO 형광펜 크기 \(size):"
                for vertical in [false, true] {
                    let pts = (0...60).map { i -> PKStrokePoint in
                        let t = CGFloat(i) * 2
                        return PKStrokePoint(location: vertical ? CGPoint(x: 80, y: 20 + t) : CGPoint(x: 20 + t, y: 80),
                                             timeOffset: Double(i) * 0.005, size: CGSize(width: size, height: size),
                                             opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2, secondaryScale: 1)
                    }
                    let s = PKStroke(ink: PKInk(.marker, color: .black),
                                     path: PKStrokePath(controlPoints: pts, creationDate: Date()),
                                     transform: .identity, mask: nil, randomSeed: 11)
                    let img = PKDrawing(strokes: [s]).image(from: frame, scale: 4)
                    line += String(format: " %@ %.2f", vertical ? "세로" : "가로", thickness(img, vertical: vertical))
                }
                print(line)
            }
        }
        for (name, ink, size, vertical, azimuth) in cases {
            let points = (0...60).map { i -> PKStrokePoint in
                let t = CGFloat(i) * 2
                return PKStrokePoint(location: vertical ? CGPoint(x: 80, y: 20 + t) : CGPoint(x: 20 + t, y: 80),
                                     timeOffset: Double(i) * 0.005, size: CGSize(width: size, height: size),
                                     opacity: 1, force: 1, azimuth: azimuth, altitude: .pi / 2, secondaryScale: 1)
            }
            let stroke = PKStroke(ink: PKInk(ink, color: .black),
                                  path: PKStrokePath(controlPoints: points, creationDate: Date()),
                                  transform: .identity, mask: nil, randomSeed: 11)
            let pencilKit = PKDrawing(strokes: [stroke]).image(from: frame, scale: 4)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 4
            format.opaque = false
            let ours = UIGraphicsImageRenderer(size: frame.size, format: format).image { ctx in
                InkRenderer.draw(InkRenderer.sample(stroke), in: ctx.cgContext, smooth: true)
            }
            let a = thickness(pencilKit, vertical: vertical)
            let b = thickness(ours, vertical: vertical)
            r.check("PencilKit과 같은 굵기 (\(name))", abs(a - b) <= max(0.75, a * 0.15),
                    "PencilKit \(String(format: "%.2f", a))pt / 우리 \(String(format: "%.2f", b))pt")
        }
    }

    /// 획 가운데를 가로지르는 줄에서 잉크가 칠해진 길이 (pt)
    @MainActor
    private static func thickness(_ image: UIImage, vertical: Bool) -> CGFloat {
        guard let cg = image.cgImage else { return -1 }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return -1 }
        var count = 0
        if vertical {
            let y = h / 2
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 64 { count += 1 }
        } else {
            let x = w / 2
            for y in 0..<h where pixels[(y * w + x) * 4 + 3] > 64 { count += 1 }
        }
        return CGFloat(count) / (CGFloat(w) / image.size.width)
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

    @MainActor
    private static func canvasProbe() async {
        func describe(_ d: PKDrawing) -> String {
            d.strokes.map { "\($0.ink.inkType.rawValue) a=\(String(format: "%.2f", $0.ink.color.cgColor.alpha)) seed=\(String($0.randomSeed, radix: 16)) size=\($0.path.first?.size ?? .zero)" }
                .joined(separator: " | ")
        }
        var mono = StrokeBuilder(inkType: .monoline, color: .black, width: 2.2, startTime: 0)
        var high = StrokeBuilder(inkType: .monoline, color: UIColor.systemYellow.withAlphaComponent(0.5), width: 16, startTime: 0)
        for i in 0...20 {
            let sample = InputSample(location: CGPoint(x: 10 + CGFloat(i) * 5, y: 50), time: Double(i) * 0.01, force: 0.5, azimuth: 0, altitude: .pi / 2)
            mono.add(sample)
            high.add(InputSample(location: CGPoint(x: 10 + CGFloat(i) * 5, y: 90), time: Double(i) * 0.01, force: 0.5, azimuth: 0, altitude: .pi / 2))
        }
        let original = PKDrawing(strokes: [mono.makeStroke(seed: 7)!, high.makeStroke(seed: GlassInk.seed(strength: 0.4))!])
        print("[PROBE] 원본: \(describe(original))")
        print("[PROBE] 데이터로 왕복: \(describe((try? PKDrawing(data: original.dataRepresentation())) ?? PKDrawing()))")
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        canvas.drawing = original
        print("[PROBE] 캔버스에 넣고 바로: \(describe(canvas.drawing))")
        print("[PROBE] 캔버스 버전 \(canvas.maximumSupportedContentVersion.rawValue), 그림 필요 버전 \(original.requiredContentVersion.rawValue)")
        print("[PROBE] DONE")
    }

    // MARK: 진단: 같은 필기를 PencilKit과 BadNotes 렌더러로 나란히

    @MainActor
    private static func compare(_ name: String) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(name)
        guard let loaded = try? NoteLoader.load(url) else { print("[COMPARE] 못 엶 \(url.path)"); return }
        for (index, drawing) in loaded.drawings.sorted(by: { $0.key < $1.key }) {
            guard let page = loaded.pdf.page(at: index) else { continue }
            let size = PageGeometry(page: page).canvasSize
            for stroke in drawing.strokes {
                let t = stroke.transform
                print("[COMPARE] p\(index) ink=\(stroke.ink.inkType.rawValue) n=\(stroke.path.count) seed=\(String(stroke.randomSeed, radix: 16)) "
                      + "t=(\(t.a),\(t.b),\(t.c),\(t.d),\(t.tx),\(t.ty)) mask=\(stroke.mask != nil) "
                      + "size0=\(stroke.path.first?.size ?? .zero) bounds=\(stroke.renderBounds)")
            }
            let apple = drawing.image(from: CGRect(origin: .zero, size: size), scale: 1)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let combined = UIGraphicsImageRenderer(size: CGSize(width: size.width * 2 + 10, height: size.height), format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: size.width * 2 + 10, height: size.height))
                apple.draw(at: .zero)
                ctx.cgContext.translateBy(x: size.width + 10, y: 0)
                for stroke in drawing.strokes { InkRenderer.draw(InkRenderer.sample(stroke), in: ctx.cgContext, smooth: true) }
            }
            let out = artifacts.appendingPathComponent("compare-p\(index).png")
            try? combined.pngData()?.write(to: out)
            print("[COMPARE] 그림 \(out.path)")
        }
        print("[COMPARE] DONE")
    }

    // MARK: 텍스트 상자·메모지·사진

    private static func elementTests(root: URL, _ r: Results) throws {
        let url = root.appendingPathComponent("Elements.pdf")
        try makePDF(url)
        // 점검용 사진: 빨강 왼쪽 + 파랑 오른쪽
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        }
        guard let prepared = ElementImages.prepare(photo.pngData() ?? Data()) else {
            throw TestError(description: "사진 준비 실패")
        }
        r.check("사진: 준비하면 번호와 크기가 생김", !prepared.id.isEmpty && prepared.size.width >= 399, "\(prepared.size)")

        var plain = PageElement(kind: .text, x: 40, y: 40, width: 200, height: 30)
        plain.text = "안녕 BadNotes"
        plain.height = ElementRenderer.fittedHeight(plain)
        var colored = PageElement(kind: .text, x: 40, y: 120, width: 200, height: 60)
        colored.text = "색 바탕"
        colored.fill = .color
        colored.fillColor = RGBAColor(hex: 0x00C000)
        var glass = PageElement(kind: .text, x: 300, y: 40, width: 200, height: 60)
        glass.text = "유리"
        glass.fill = .glass
        var sticky = PageElement(kind: .sticky, x: 300, y: 140, width: 200, height: 200)
        sticky.text = "메모"
        var picture = PageElement(kind: .image, x: 40, y: 400, width: 200, height: 150)
        picture.imageID = prepared.id
        let elements = [plain, colored, glass, sticky, picture]

        var longer = plain
        longer.text = String(repeating: "줄이 늘어나면 상자도 길어져요 ", count: 6)
        r.check("텍스트 상자: 글이 길면 높이가 늘어남", ElementRenderer.fittedHeight(longer) > plain.height * 2,
                "\(ElementRenderer.fittedHeight(longer)) / \(plain.height)")

        let d = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 40, y: 600), CGPoint(x: 300, y: 600), width: 4)])
        _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: d, elements: elements)],
                                   images: [prepared.id: prepared.data], to: url)
        keep(url, as: "elements.pdf")
        let loaded = try NoteLoader.load(url)
        r.check("요소: PDF에 넣고 다시 읽으면 그대로", loaded.elements[0] == elements,
                "\(loaded.elements[0]?.count ?? 0)개")
        r.check("요소: 사진 원본도 같이 저장", loaded.images[prepared.id] == prepared.data)
        r.check("요소: 필기도 같이 그대로", loaded.drawings[0]?.strokes.count == 1)
        r.check("요소: 화면용 문서에서는 주석을 떼어 냄", loaded.pdf.page(at: 0)?.annotations.isEmpty == true)

        if let saved = PDFDocument(url: url), let page = saved.page(at: 0) {
            let order = page.annotations.map { isInk($0) ? "ink" : ($0.value(forAnnotationKey: ElementPayload.elementsKey) != nil ? "el" : "?") }
            r.check("요소: 다른 앱에서도 필기가 요소 위에 (주석 순서)", order == ["el", "ink"], "\(order)")
            let image = render(page)
            keep(image, as: "elements.png")
            let fill = rgb(image, at: CGPoint(x: 45, y: 125))
            r.check("요소: 색 바탕이 다른 앱에서도 보임", fill.g > 0.6 && fill.r < 0.3, "\(fill)")
            let left = rgb(image, at: CGPoint(x: 80, y: 475)), right = rgb(image, at: CGPoint(x: 200, y: 475))
            r.check("요소: 사진이 다른 앱에서도 보임", left.r > 0.8 && left.b < 0.3 && right.b > 0.8 && right.r < 0.3,
                    "\(left) / \(right)")
            let text = luminance(image, at: CGPoint(x: 52, y: 40 + plain.padding.height + 10))
            _ = text
        }

        // 필기만 바꿔 저장하면 요소는 그대로
        _ = try PDFInkWriter.apply([0: PKDrawing()], to: url)
        let inkOnly = try NoteLoader.load(url)
        r.check("요소: 필기만 저장해도 요소는 남음", inkOnly.elements[0]?.count == elements.count && inkOnly.drawings[0] == nil)
        // 요소를 다 지우면 주석도 사라짐
        _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: nil, elements: [])], images: [:], to: url)
        r.check("요소: 다 지우면 PDF에서도 없어짐", try NoteLoader.load(url).elements[0] == nil)

        // 1.2에서 저장한 요소(글꼴·유리 값 없음)도 읽힘
        let old12 = """
        [{"id":"\(UUID().uuidString)","kind":"sticky","x":10,"y":20,"width":200,"height":200,"text":"옛 메모",
          "fontSize":22,"bold":false,"textColor":{"r":0,"g":0,"b":0,"a":1},"alignment":0,"fill":"none",
          "fillColor":{"r":1,"g":0.8,"b":0.3,"a":1}}]
        """
        let decodedOld = try? JSONDecoder().decode([PageElement].self, from: Data(old12.utf8))
        r.check("요소: 1.2 파일도 읽음 (글꼴 기본, 메모지는 맑은 유리)",
                decodedOld?.first?.font == "system" && decodedOld?.first?.glassClear == true
                    && abs((decodedOld?.first?.glassTint ?? 0) - 0.3) < 0.001, "\(String(describing: decodedOld))")
        var styled = glass
        styled.font = "rounded"
        styled.glassClear = true
        styled.glassTint = 0.5
        let roundTrip = try JSONDecoder().decode([PageElement].self, from: JSONEncoder().encode([styled]))
        r.check("요소: 글꼴·유리 투명도도 저장됨", roundTrip == [styled])
        r.check("글꼴: 기본 모양 4가지는 늘 있음, 모르는 글꼴은 기본으로",
                TextFonts.available.count >= 4
                    && TextFonts.font("없는글꼴", size: 20, bold: false).pointSize == 20
                    && TextFonts.font("rounded", size: 20, bold: true).fontDescriptor.symbolicTraits.contains(.traitBold))

        // 종이 메모지(색 바탕)는 유리가 아님, 예전 메모지(바탕 값 없음)는 유리
        var paperSticky = sticky
        paperSticky.fill = .color
        r.check("메모지: 종이 메모지는 유리 아님, 예전 메모지는 유리",
                !paperSticky.usesGlass && sticky.usesGlass && decodedOld?.first?.usesGlass == true)

        // Liquid Glass 펜 · 유리 글자
        let seed = GlassInk.seed(strength: 0.4)
        r.check("유리펜: 씨앗값에 유리 표시와 진하기", GlassInk.isGlass(seed) && abs(GlassInk.strength(seed) - 0.4) < 0.01
                    && !GlassInk.isGlass(UInt32(12345)))
        var glassStroke = line(.monoline, .systemBlue, CGPoint(x: 40, y: 100), CGPoint(x: 180, y: 100), width: 12)
        glassStroke = PKStroke(ink: glassStroke.ink, path: glassStroke.path, transform: .identity, mask: nil, randomSeed: seed)
        let glassImage = renderStrokes([glassStroke], size: CGSize(width: 220, height: 200))
        let middle = rgb(glassImage, at: CGPoint(x: 110, y: 100)), outside = rgb(glassImage, at: CGPoint(x: 110, y: 140))
        r.check("유리펜: 비치는 색 유리로 그려짐 (속은 색, 밖은 흰색)",
                middle.b > middle.r + 0.1 && middle.r > 0.25 && outside.r > 0.95, "\(middle)")
        r.check("유리펜: 복제해도 유리", GlassInk.isGlass(StrokeEditing.duplicated(glassStroke, by: .zero)))
        let glassURL = root.appendingPathComponent("Glass.pdf")
        try makePDF(glassURL)
        var glassWord = PageElement(kind: .text, x: 40, y: 300, width: 300, height: 80)
        glassWord.text = "유리"
        glassWord.fontSize = 48
        glassWord.bold = true
        glassWord.glassText = true
        glassWord.textColor = RGBAColor(hex: 0xD93025)
        _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: PKDrawing(strokes: [glassStroke]), elements: [glassWord])],
                                   images: [:], to: glassURL)
        let glassLoaded = try NoteLoader.load(glassURL)
        r.check("유리펜·유리 글자: PDF에 넣고 다시 읽어도 유리",
                glassLoaded.drawings[0]?.strokes.first.map(GlassInk.isGlass) == true && glassLoaded.elements[0]?.first?.glassText == true)
        r.check("유리 글자: 글자 윤곽이 나옴",
                !GlyphOutline.path(text: "유리", attributes: ElementRenderer.attributes(glassWord),
                                   in: CGRect(x: 0, y: 0, width: 300, height: 80)).isEmpty)
        if let page = PDFDocument(url: glassURL)?.page(at: 0) {
            let image = render(page)
            keep(image, as: "glass.png")
            var tinted = 0
            for x in stride(from: 50, to: 180, by: 4) {
                let c = rgb(image, at: CGPoint(x: CGFloat(x), y: 330))
                if c.r > c.b + 0.08 { tinted += 1 }
            }
            r.check("유리 글자: 다른 앱에서도 색 유리 글자로 보임", tinted >= 3, "\(tinted)")
            let strokeColor = rgb(image, at: CGPoint(x: 110, y: 100))
            r.check("유리펜: 다른 앱에서도 보임", strokeColor.b > strokeColor.r + 0.05, "\(strokeColor)")
        }

        // Apple 도구로 그은 획은 BadNotes 도구 모드에서도 Apple 렌더러로 (타일, 백그라운드 스레드)
        let appleMarker = line(.marker, .systemOrange, CGPoint(x: 20, y: 100), CGPoint(x: 200, y: 110), width: 18)
        r.check("Apple 획 구분: 표시 없는 획은 Apple, BadNotes 획은 표시",
                InkRenderer.sample(appleMarker).appleSource != nil
                    && InkRenderer.sample(PKStroke(ink: appleMarker.ink, path: appleMarker.path, transform: .identity, mask: nil,
                                                   randomSeed: InkOrigin.badNotesSeed())).appleSource == nil)
        let tileInk = PageInk(drawing: PKDrawing(strokes: [appleMarker]))
        let tileFormat = UIGraphicsImageRendererFormat()
        tileFormat.scale = 1
        let tileImage = UIGraphicsImageRenderer(size: CGSize(width: 220, height: 200), format: tileFormat).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 220, height: 200))
            InkTileRenderer(ink: tileInk).drawTile(in: ctx.cgContext)
        }.cgImage
        let appleImage = UIGraphicsImageRenderer(size: CGSize(width: 220, height: 200), format: tileFormat).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 220, height: 200))
            var picture: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                picture = PKDrawing(strokes: [appleMarker]).image(from: CGRect(x: 0, y: 0, width: 220, height: 200), scale: 1)
            }
            picture?.draw(at: .zero)
        }.cgImage
        var differ = 0
        for x in stride(from: 10, to: 210, by: 10) {
            for y in stride(from: 80, to: 130, by: 5) {
                let a = rgb(tileImage, at: CGPoint(x: x, y: y)), b2 = rgb(appleImage, at: CGPoint(x: x, y: y))
                if abs(a.r - b2.r) + abs(a.g - b2.g) + abs(a.b - b2.b) > 0.06 { differ += 1 }
            }
        }
        r.check("Apple 획: BadNotes 화면에서도 Apple과 똑같이 그려짐", differ == 0, "다른 점 \(differ)개")

        // .badnote: BadNotes 전용 (유리 흉내 안 구움), PDF로 내보내기
        let noteURL = root.appendingPathComponent("Glass.badnote")
        try PaperRenderer.notebookPDF(name: "유리", cover: nil,
                                      paper: PaperSpec(template: .blank, tone: .white, size: .a4Portrait)).write(to: noteURL)
        _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: PKDrawing(strokes: [glassStroke]), elements: [glassWord])],
                                   images: [:], to: noteURL)
        let noteLoaded = try NoteLoader.load(noteURL)
        r.check(".badnote: 저장하고 다시 읽으면 유리 그대로",
                noteLoaded.drawings[0]?.strokes.first.map(GlassInk.isGlass) == true && noteLoaded.elements[0]?.first?.glassText == true)
        if let page = PDFDocument(data: try Data(contentsOf: noteURL))?.page(at: 0) {
            let plain = rgb(render(page), at: CGPoint(x: 110, y: 100))
            r.check(".badnote: 유리 흉내는 안 구움 (다른 앱에서 빈 자리)", plain.r > 0.95 && plain.b > 0.95, "\(plain)")
        }
        let exportItem = LibraryItem(url: noteURL, name: "Glass", modified: Date(), isFolder: false, childCount: 0)
        let exported = try LibraryStore.shared.exportPDF(exportItem)
        if let page = PDFDocument(url: exported)?.page(at: 0) {
            let baked = rgb(render(page), at: CGPoint(x: 110, y: 100))
            r.check("PDF로 내보내기: .pdf로 생기고 유리가 그림으로 구워짐",
                    exported.pathExtension == "pdf" && baked.b > baked.r + 0.05, "\(baked)")
        }
        r.check("서재: .badnote도 문서로 보임",
                LibraryStore.scan(root).contains { $0.url.lastPathComponent == "Glass.badnote" })

        // 화이트보드
        let boardURL = root.appendingPathComponent("Board.pdf")
        try PaperRenderer.boardPDF(name: "보드").write(to: boardURL)
        let far = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 9000, y: 9000), CGPoint(x: 9400, y: 9100), width: 4)])
        _ = try PDFInkWriter.apply([0: far], to: boardURL)
        let board = try NoteLoader.load(boardURL)
        r.check("화이트보드: 아주 큰 한 장 + 화이트보드로 알아봄 + 먼 곳 필기도 저장",
                board.pdf.pageCount == 1 && PaperSpec.isBoard(board.pdf.documentAttributes)
                    && (board.pdf.page(at: 0)?.bounds(for: .cropBox).width ?? 0) >= 14_000
                    && board.drawings[0]?.strokes.count == 1)
        r.check("화이트보드: 표지는 못 넣음", (try? PDFInkWriter.replaceCover(of: boardURL, with: .navy, title: "보드")) == nil)

        // 페이지 줄 (가로 두 쪽)
        r.check("두 쪽: 표지는 혼자, 나머지는 둘씩",
                PageRows.make(count: 5, twoUp: true, coverAlone: true) == [[0], [1, 2], [3, 4]]
                    && PageRows.make(count: 5, twoUp: true, coverAlone: false) == [[0, 1], [2, 3], [4]]
                    && PageRows.make(count: 3, twoUp: false, coverAlone: true) == [[0], [1], [2]]
                    && PageRows.row(containing: 3, in: [[0], [1, 2], [3, 4]]) == 2)

        // 복구 기록
        let journal = DrawingJournal(directory: root.appendingPathComponent("ElementJournal", isDirectory: true))
        try journal.write(elements, images: [prepared.id: prepared.data], page: 2)
        let recovered = journal.load()
        r.check("요소: 복구 기록에서 되살림", recovered.elements[2] == elements && recovered.images[prepared.id] == prepared.data)
        journal.remove(page: 2)
        r.check("요소: 복구 기록 지우기", journal.load().elements[2] == nil)
    }

    // MARK: 표지

    private static func coverTests(root: URL, _ r: Results) throws {
        var blank = 0
        for style in CoverStyle.allCases {
            let size = CGSize(width: 120, height: 170)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                CoverArt.draw(style, title: "점검", in: ctx.cgContext, rect: CGRect(origin: .zero, size: size))
            }.cgImage
            // 제목 판 안쪽(글자 없는 곳)과 바탕이 구분되는지
            let base = rgb(image, at: CGPoint(x: 95, y: 95)), plate = rgb(image, at: CGPoint(x: 23, y: 29))
            if abs(base.r - plate.r) + abs(base.g - plate.g) + abs(base.b - plate.b) < 0.05 {
                blank += 1
                print("[SELFTEST] INFO 밋밋한 표지: \(style.rawValue) 바탕 \(base) 판 \(plate)")
            }
        }
        r.check("표지 \(CoverStyle.allCases.count)가지: 전부 그려지고 제목 자리가 보임", blank == 0, "밋밋한 표지 \(blank)개")

        let folder = root.appendingPathComponent("Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paper = PaperSpec(template: .grid, tone: .white, size: .a4Portrait)
        let url = folder.appendingPathComponent("표지 점검.pdf")
        try PaperRenderer.notebookPDF(name: "표지 점검", cover: .navy, paper: paper).write(to: url)
        let d = PKDrawing(strokes: [line(.pen, .white, CGPoint(x: 100, y: 700), CGPoint(x: 400, y: 700), width: 6)])
        _ = try PDFInkWriter.apply([0: d], to: url)
        let inserted = try PDFInkWriter.replaceCover(of: url, with: .waves, title: "표지 점검")
        let changed = try NoteLoader.load(url)
        let keywords = PaperSpec.keywords(changed.pdf.documentAttributes)
        r.check("표지 바꾸기: 쪽수 그대로, 표지 이름 바뀜",
                !inserted && changed.pdf.pageCount == 2 && keywords.contains("BadNotesCover=waves")
                    && !keywords.contains("BadNotesCover=navy") && PaperSpec.from(documentAttributes: changed.pdf.documentAttributes) == paper,
                "\(keywords)")
        r.check("표지 바꾸기: 표지 위 필기는 새 표지로 옮겨짐", changed.drawings[0]?.strokes.count == 1)
        if let saved = PDFDocument(url: url), let cover = saved.page(at: 0) {
            let sea = rgb(render(cover), at: CGPoint(x: 300, y: 820))
            keep(render(cover), as: "cover-waves.png")
            r.check("표지 바꾸기: 새 그림으로 그려짐 (바다)", sea.b > sea.r && sea.g > sea.r, "\(sea)")
        }
        let plainURL = folder.appendingPathComponent("그냥 PDF.pdf")
        try makePDF(plainURL)
        let added = try PDFInkWriter.replaceCover(of: plainURL, with: .dots, title: "그냥 PDF")
        let withCover = try NoteLoader.load(plainURL)
        r.check("표지 바꾸기: 표지 없던 PDF는 맨 앞에 넣음",
                added && withCover.pdf.pageCount == 4 && PaperSpec.hasCover(withCover.pdf.documentAttributes))
        let key1 = AppPaths.key(for: url), key2 = AppPaths.key(for: plainURL)
        try? FileManager.default.removeItem(at: AppPaths.backups.appendingPathComponent(key1))
        try? FileManager.default.removeItem(at: AppPaths.backups.appendingPathComponent(key2))
    }

    /// 부분 지우개 마스크를 PencilKit(Apple 도구 모드)도 같은 자리로 알아듣는지
    @MainActor
    private static func maskMatchesPencilKit(_ r: Results) {
        let stroke = line(.pen, .black, CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100), width: 4)
        guard let cut = StrokeEditing.erase(stroke, sampled: InkRenderer.sample(stroke), from: CGPoint(x: 100, y: 80),
                                            to: CGPoint(x: 100, y: 120), radius: 5)?.first else {
            r.check("PencilKit도 지운 자리를 똑같이 비움", false, "안 지워짐")
            return
        }
        let image = PKDrawing(strokes: [cut]).image(from: CGRect(x: 0, y: 0, width: 220, height: 200), scale: 1).cgImage
        func dark(_ x: CGFloat) -> Bool {
            guard let image else { return false }
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.draw(image, in: CGRect(x: -x, y: -(CGFloat(image.height) - 100 - 1),
                                               width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            return pixel[3] > 128
        }
        r.check("PencilKit도 지운 자리를 똑같이 비움", dark(60) && dark(140) && !dark(100),
                "왼쪽 \(dark(60)) 가운데 \(dark(100)) 오른쪽 \(dark(140))")
    }

    /// 우리 렌더러로 획을 그린 그림 (흰 바탕, 1pt = 1px)
    private static func renderStrokes(_ strokes: [PKStroke], size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for stroke in strokes { InkRenderer.draw(InkRenderer.sample(stroke), in: ctx.cgContext, smooth: true) }
        }.cgImage
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
