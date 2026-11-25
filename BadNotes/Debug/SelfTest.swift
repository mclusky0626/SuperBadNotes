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
            try brushTests(root: root, results)
            try await badnoteEraseTests(root: root, results)
            highlighterTests(results)
            await pencilKitMatchTests(results)
            try await documentTests(root: root, results)
            try await notebookTests(root: root, results)
            try elementTests(root: root, results)
            try await boardGrowthTests(root: root, results)
            try coverTests(root: root, results)
            await maskMatchesPencilKit(results)
            pageCurlTests(results)
            try await spreadTurnTests(root: root, results)
            try await spreadLayoutTests(root: root, results)
            await glassPageImageTest(results)
        } catch {
            results.check("예외 없이 끝남", false, "\(error)")
        }
        try? FileManager.default.removeItem(at: root)
        print("[SELFTEST] DONE passed=\(results.passed) failed=\(results.failed)")
    }

    @MainActor
    private static func badnoteEraseTests(root: URL, _ r: Results) throws {
        let url = root.appendingPathComponent("Eraser.badnote")
        try makePDF(url)
        let blue = line(.monoline, .blue, CGPoint(x: 20, y: 30), CGPoint(x: 210, y: 30), width: 12)
        let glass = PKStroke(ink: blue.ink, path: blue.path, transform: CGAffineTransform(translationX: 5, y: 20),
                             mask: nil, randomSeed: GlassInk.seed(strength: 0.45))
        var strokes = [glass]
        for row in 0..<24 {
            for col in 0..<16 {
                let x = CGFloat(col * 34 + 15), y = CGFloat(row * 18 + 90)
                strokes.append(line(.monoline, .black, CGPoint(x: x, y: y), CGPoint(x: x + 24, y: y + 3), width: 4))
            }
        }
        var word = PageElement(kind: .text, x: 0, y: 600, width: 180, height: 50)
        word.text = "유리 Glass"
        word.glassText = true
        _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: PKDrawing(strokes: strokes), elements: [word])],
                                   images: [:], to: url)
        let saved = try NoteLoader.load(url)
        guard let original = saved.drawings[0] else { throw TestError(description: "부분 지우개 노트 열기") }
        let page = PageInk(drawing: original)
        let initial = page.sampledStrokes()
        let sweep = StrokeEditing.Sweep(from: CGPoint(x: 75, y: 65),
                                        through: [CGPoint(x: 75, y: 30), CGPoint(x: 140, y: 30), CGPoint(x: 140, y: 65)],
                                        radius: 7)
        r.check(".badnote: 형광펜만 지우면 유리펜 보존", page.erase(sweep, partial: true, highlightersOnly: true).isNull)
        let area = page.erase(sweep, partial: true, highlightersOnly: false)
        r.check(".badnote: 획의 바뀐 구간만 다시 그림", !area.isNull && !area.contains(CGPoint(x: 34, y: 50)))
        let changed = page.sampledStrokes()
        r.check(".badnote: 손대지 않은 필기와 유리펜 원래 윤곽 유지", changed.count == initial.count
                && changed[0].glassOutline === initial[0].glassOutline && changed.last?.key == initial.last?.key)
        r.check(".badnote: 지운 곳을 다시 지나가면 변경 없음",
                page.erase(sweep, partial: true, highlightersOnly: false).isNull)
        _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: page.currentDrawing(), elements: [word])], images: [:], to: url)
        let reopened = try NoteLoader.load(url)
        guard let stroke = reopened.drawings[0]?.strokes.first, let mark = GlassMark(stroke: InkRenderer.sample(stroke))
        else { throw TestError(description: "저장한 유리펜 윤곽") }
        func visible(_ x: CGFloat) -> Bool { mark.path.contains(CGPoint(x: x - mark.frame.minX, y: 50 - mark.frame.minY)) }
        r.check(".badnote: 다시 열어도 두 군데 지운 자리는 비고 가운데와 양끝은 남음",
                !visible(75) && !visible(140) && visible(40) && visible(108) && visible(180))
        r.check(".badnote: 지우고 저장한 뒤에도 유리 글자와 펜의 진하기 유지",
                reopened.elements[0]?.first == word && stroke.randomSeed == glass.randomSeed)

        var timings: [Double] = []
        for row in 0..<24 {
            let y = CGFloat(row * 18 + 90)
            let motion = StrokeEditing.Sweep(from: CGPoint(x: 25, y: y - 5),
                                             through: [CGPoint(x: 25, y: y + 7)], radius: 4)
            let start = CACurrentMediaTime()
            let dirty = page.erase(motion, partial: true, highlightersOnly: false)
            if !dirty.isNull { timings.append((CACurrentMediaTime() - start) * 1000) }
        }
        r.check(".badnote: 385획 페이지에서 24번 연속 부분 지우기", timings.count == 24)
        if !timings.isEmpty {
            let p95 = timings.sorted()[Int(ceil(Double(timings.count) * 0.95)) - 1]
            print("[SELFTEST] INFO 부분 지우개 385획, 24회 엔진 p95 \(String(format: "%.2f", p95)) ms")
        }
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
        // 가운데만 가늘게 지운 뒤 양옆에 남은 조각도 다시 지워짐
        let fat = line(.pen, .black, CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100), width: 14)
        let fatWidth = InkRenderer.sample(fat).meanWidth
        if let split = StrokeEditing.erase(fat, sampled: InkRenderer.sample(fat), from: CGPoint(x: -30, y: 100),
                                           to: CGPoint(x: 230, y: 100), radius: fatWidth * 0.2)?.first {
            let sliver = InkRenderer.sample(split)
            let edge = CGPoint(x: 100, y: 100 + fatWidth * 0.4)
            let again = StrokeEditing.erase(split, sampled: sliver, from: CGPoint(x: -30, y: edge.y), to: CGPoint(x: 230, y: edge.y),
                                            radius: fatWidth * 0.35)
            let other = CGPoint(x: 100, y: 100 - fatWidth * 0.4)
            let last = again?.first.flatMap {
                StrokeEditing.erase($0, sampled: InkRenderer.sample($0), from: CGPoint(x: -30, y: other.y),
                                    to: CGPoint(x: 230, y: other.y), radius: fatWidth * 0.35)
            }
            let rest = last?.first.map { StrokeEditing.inkOutline(InkRenderer.sample($0)).intersection($0.mask!.cgPath).boundingBoxOfPath }
            r.check("부분 지우개: 가운데를 지운 뒤 남은 가장자리 조각도 지워짐", again?.first != nil && last?.isEmpty == true,
                    "\(again?.count ?? -1) / \(last?.count ?? -1) 남은 \(String(describing: rest))")
        } else {
            r.check("부분 지우개: 가운데를 지운 뒤 남은 가장자리 조각도 지워짐", false, "가운데가 안 지워짐")
        }
        // 곡선 펜 획을 지그재그로 문질러 지우면 부스러기 없이 다 지워짐
        var curvyBuilder = StrokeBuilder(inkType: .pen, color: .systemRed, width: 3.8, pressureRange: 0.7...1.3, startTime: 0)
        for i in 0...80 {
            let t = CGFloat(i) / 80
            curvyBuilder.add(InputSample(location: CGPoint(x: 20 + 180 * t, y: 100 + sin(t * .pi * 3) * 40),
                                         time: Double(i) * 0.01, force: 0.3 + 0.5 * sin(t * .pi), azimuth: 0, altitude: .pi / 2))
        }
        if var current = curvyBuilder.makeStroke(seed: InkOrigin.badNotesSeed()) {
            var alive = true
            var previous = CGPoint(x: 10, y: 40)
            for i in 0...60 where alive {
                let point = CGPoint(x: 10 + CGFloat(i) * 3.5, y: i.isMultiple(of: 2) ? 40 : 160)
                for step in 0..<6 where alive {
                    let a = CGPoint(x: previous.x + (point.x - previous.x) * CGFloat(step) / 6,
                                    y: previous.y + (point.y - previous.y) * CGFloat(step) / 6)
                    let b2 = CGPoint(x: previous.x + (point.x - previous.x) * CGFloat(step + 1) / 6,
                                     y: previous.y + (point.y - previous.y) * CGFloat(step + 1) / 6)
                    if let result = StrokeEditing.erase(current, sampled: InkRenderer.sample(current), from: a, to: b2, radius: 11) {
                        if let next = result.first { current = next } else { alive = false }
                    }
                }
                previous = point
            }
            var reds = 0
            if alive {
                let image = renderStrokes([current], size: CGSize(width: 240, height: 200))
                for x in stride(from: 0, to: 240, by: 2) { for y in stride(from: 40, to: 160, by: 2) {
                    let c = rgb(image, at: CGPoint(x: x, y: y))
                    if c.r - c.g > 0.25 { reds += 1 }
                } }
            }
            r.check("부분 지우개: 곡선 획을 문질러 지우면 부스러기 안 남음", !alive || reds == 0, "남은 빨간 점 \(reds)")
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

    private static func brushTests(root: URL, _ r: Results) throws {
        func stroke(_ profile: BrushProfile, angle: CGFloat = 0, altitude: CGFloat = .pi / 2,
                    interval: Double = 0.01, pressure: (Int) -> CGFloat = { _ in 0.45 }) -> PKStroke {
            let ink: PKInk.InkType = profile == .graphite ? .pencil : (profile == .fountain ? .fountainPen : .pen)
            var builder = StrokeBuilder(inkType: ink, color: .blue, width: 12, pressureRange: 0.18...2.1,
                                        startTime: 0, seed: profile.seed(salt: 37))
            for i in 0...80 {
                let distance = CGFloat(i) * 2
                builder.add(InputSample(location: CGPoint(x: 30 + cos(angle) * distance, y: 100 + sin(angle) * distance),
                                        time: Double(i) * interval, force: pressure(i), azimuth: 0, altitude: altitude))
            }
            return builder.makeStroke()!
        }

        let slow = stroke(.brush, interval: 0.03), fast = stroke(.brush, interval: 0.001)
        func width(_ stroke: PKStroke, _ i: Int) -> CGFloat { InkRenderer.renderWidth(stroke.path[i], .pen, direction: 0) }
        r.check("붓펜: 같은 필압에서 빠른 획은 가늘고 양끝은 뾰족함",
                width(fast, 40) < width(slow, 40) * 0.7 && max(width(slow, 0), width(slow, 80)) < width(slow, 40) * 0.3)
        let fountain = InkRenderer.sample(stroke(.fountain, altitude: .pi / 4))
        let broad = InkRenderer.sample(stroke(.fountain, angle: .pi / 2, altitude: .pi / 4))
        r.check("만년필: 납작한 펜촉의 방향에 따라 굵기가 달라짐", broad.meanWidth > fountain.meanWidth * 3)

        let pencil = stroke(.graphite, altitude: .pi / 5) { $0 < 40 ? 0.05 : 0.8 }
        let drawing = PKDrawing(strokes: [pencil])
        let restored = try PKDrawing(data: drawing.dataRepresentation()).strokes[0]
        let copy = StrokeEditing.duplicated(pencil, by: .zero)
        r.check("연필: 저장·복제 후 펜촉과 흑연 씨앗을 보존", restored.randomSeed == pencil.randomSeed
                && copy.randomSeed == pencil.randomSeed && StrokeKey(copy) != StrokeKey(pencil))
        let image = renderStrokes([restored], size: CGSize(width: 220, height: 200))
        func redness(_ image: CGImage?, from start: Int) -> [CGFloat] {
            (start..<(start + 24)).map { rgb(image, at: CGPoint(x: $0, y: 100)).r }
        }
        let light = redness(image, from: 50), dark = redness(image, from: 144)
        r.check("연필: 한 획 안에서 필압에 따라 농도가 변하고 흑연 결이 보임",
                dark.reduce(0, +) + 4 < light.reduce(0, +) && dark.max()! - dark.min()! > 0.04,
                "밝은 부분 \(light.reduce(0, +) / 24), 진한 부분 \(dark.reduce(0, +) / 24)")
        let upright = InkRenderer.sample(stroke(.graphite))
        r.check("연필: 눕히면 넓게 칠해짐", InkRenderer.sample(pencil).meanWidth > upright.meanWidth * 2)
        let erased = StrokeEditing.erase(restored, sampled: InkRenderer.sample(restored),
                                         from: CGPoint(x: 155, y: 70), to: CGPoint(x: 155, y: 130), radius: 6)
        let cut = erased.flatMap { renderStrokes($0, size: CGSize(width: 220, height: 200)) }
        r.check("연필: 부분 지우개가 흑연 결까지 지움", cut != nil && rgb(cut, at: CGPoint(x: 155, y: 100)).r > 0.98
                && redness(cut, from: 165).min()! < 0.8)
        let url = root.appendingPathComponent("Brushes.pdf")
        try makePDF(url)
        _ = try PDFInkWriter.apply([0: drawing], to: url)
        let exported = PDFDocument(url: url)?.page(at: 0).flatMap(render)
        let darkPDF = redness(exported, from: 144)
        r.check("연필: PDF에 펜 색과 질감이 보임", exported != nil && darkPDF.max()! - darkPDF.min()! > 0.04
                && darkPDF.min()! < 0.8 && rgb(exported, at: CGPoint(x: 150, y: 100)).b > 0.8)
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
        let far = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 2000, y: 1500), CGPoint(x: 2400, y: 1600), width: 4)])
        _ = try PDFInkWriter.apply([0: far], to: boardURL)
        let board = try NoteLoader.load(boardURL)
        r.check("화이트보드: 작게 시작하는 한 장 + 화이트보드로 알아봄 + 필기 저장",
                board.pdf.pageCount == 1 && PaperSpec.isBoard(board.pdf.documentAttributes)
                    && abs((board.pdf.page(at: 0)?.bounds(for: .cropBox).width ?? 0) - PaperSpec.boardStart.width) < 1
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

    // MARK: 화이트보드 늘리기

    private static func boardGrowthTests(root: URL, _ r: Results) async throws {
        let url = root.appendingPathComponent("Grow.pdf")
        try PaperRenderer.boardPDF(name: "늘리기").write(to: url)
        let d = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), width: 4)])
        var sticky = PageElement(kind: .sticky, x: 50, y: 200, width: 200, height: 200)
        sticky.text = "메모"
        _ = try PDFInkWriter.apply(content: [0: PageContent(drawing: d, elements: [sticky])], images: [:], to: url)
        await MainActor.run { LegacyMigration.skipForTesting() }
        let note = try await NoteDocument.open(url)
        let grown = await note.growBoard(left: 1600, top: 0, right: 1600, bottom: 1600)
        await note.flush(reason: "점검")
        let loaded = try NoteLoader.load(url)
        let size = loaded.pdf.page(at: 0)?.bounds(for: .cropBox).size ?? .zero
        let start = PaperSpec.boardStart
        r.check("화이트보드 늘리기: 가장자리 쪽으로 크기가 늘고 파일에도 저장",
                abs(size.width - (start.width + 3200)) < 1 && abs(size.height - (start.height + 1600)) < 1
                    && grown?.shift == CGPoint(x: 1600, y: 0), "\(size) \(String(describing: grown))")
        let strokeX = loaded.drawings[0]?.bounds.minX ?? 0, stickyX = loaded.elements[0]?.first?.x ?? 0
        r.check("화이트보드 늘리기: 왼쪽으로 늘리면 필기·메모지도 그만큼 밀려서 제자리",
                abs(strokeX - (d.bounds.minX + 1600)) < 2 && abs(stickyX - 1650) < 0.5, "\(strokeX) \(stickyX)")
        let key = AppPaths.key(for: url)
        try? FileManager.default.removeItem(at: AppPaths.backups.appendingPathComponent(key))
        try? FileManager.default.removeItem(at: AppPaths.journal.appendingPathComponent(key))
    }

    // MARK: 표지

    // MARK: 책처럼 넘기기

    @MainActor
    private static func spreadLayoutTests(root: URL, _ r: Results) async throws {
        let url = root.appendingPathComponent("MixedSpread.pdf")
        try makePDF(url)
        let note = try await NoteDocument.open(url)
        let direct = DirectEditorView(document: note, tools: .shared, bridge: EditorBridge())
        direct.setPageView(book: true, twoUp: true)
        let apple = PencilKitEditorView(document: note, bridge: EditorBridge())
        apple.setTwoUp(true)
        defer {
            direct.prepareForRemoval()
            apple.prepareForRemoval()
        }

        for editor: UIView & ElementHost in [direct, apple] {
            let name = editor === direct ? "직접 필기" : "Apple 도구"
            editor.frame = CGRect(x: 0, y: 0, width: 1200, height: 780)
            editor.layoutIfNeeded()
            guard let left = editor.elementPageView(0), let right = editor.elementPageView(1) else {
                r.check("\(name) 펼침면 페이지 준비", false)
                continue
            }
            let a = left.convert(left.bounds, to: editor)
            let b = right.convert(right.bounds, to: editor)
            r.check("\(name) 서로 다른 폭의 PDF도 화면을 정확히 이분할",
                    abs(a.minX) < 0.1 && abs(a.maxX - 600) < 0.1 && abs(b.minX - 600) < 0.1 && abs(b.maxX - 1200) < 0.1,
                    "\(a) / \(b)")
            r.check("\(name) 회전된 페이지의 원본 비율 유지",
                    abs(b.height / b.width - right.bounds.height / right.bounds.width) < 0.001)

            if editor === apple, let canvas = apple.subviews.compactMap({ $0 as? PKCanvasView }).first {
                // Canvas coordinates are the paper placements before scroll-view zoom.
                let native = PKDrawing(strokes: [line(.pen, .black, CGPoint(x: 50, y: 50),
                                                      CGPoint(x: 150, y: 150), width: 4)])
                let frame = right.frame
                let scale = frame.width / right.bounds.width
                let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: frame.minX, ty: frame.minY)
                canvas.drawing = native.transformed(using: transform)
                apple.canvasViewDrawingDidChange(canvas)
                r.check("Apple 필기 저장 좌표가 원래 PDF 페이지와 일치",
                        note.drawing(for: 0).strokes.isEmpty && close(note.drawing(for: 1).bounds, native.bounds, 0.5))
            }

            editor.frame.size.height = 1400
            editor.layoutIfNeeded()
            let portrait = left.convert(left.bounds, to: editor)
            r.check("\(name) 너비가 같아도 세로로 바뀌면 한 쪽 보기",
                    portrait.width > 600 && (right.isHidden || right.frame.minY >= left.frame.maxY))
        }
    }

    @MainActor
    private static func spreadTurnTests(root: URL, _ r: Results) async throws {
        let url = root.appendingPathComponent("Spread.pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextKeywords as String: ["\(PaperSpec.coverPrefix)navy"]]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 150, height: 200), format: format)
        try renderer.writePDF(to: url) { context in
            for height in [260, 160, 200, 130] {
                context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 150, height: height), pageInfo: [:])
            }
        }
        let note = try await NoteDocument.open(url)
        let bridge = EditorBridge()
        let editor = DirectEditorView(document: note, tools: .shared, bridge: bridge)
        editor.setPageView(book: true, twoUp: true)
        editor.frame = CGRect(x: 0, y: 0, width: 640, height: 400)
        editor.layoutIfNeeded()
        defer { editor.prepareForRemoval() }

        func visiblePages() -> [Int] {
            (0..<4).compactMap(editor.elementPageView).filter { !$0.isHidden }.map(\.index)
        }
        guard let scroll = editor.subviews.compactMap({ $0 as? UIScrollView }).first else {
            throw TestError(description: "책 보기 스크롤 화면 없음")
        }
        scroll.contentOffset.y = 90
        bridge.turn(1)
        r.check("표지를 열 때 종이 밑의 오른쪽 페이지만 먼저 보임", visiblePages() == [2])
        if let curl = editor.subviews.compactMap({ $0 as? PageCurlView }).first, let page = editor.elementPageView(1) {
            let destination = page.convert(page.bounds, to: editor)
            r.check("스크롤한 표지의 뒷면이 높이가 다른 다음 장의 실제 위치에 내려앉음",
                    curl.landingRect == destination && curl.geometry.rect.minY < destination.minY
                        && curl.geometry.rect.height > destination.height)
        } else {
            r.check("스크롤한 표지 넘기기 준비", false)
        }
        editor.endFlip(complete: false)
        r.check("표지를 열다 놓으면 표지와 읽던 위치 복원",
                visiblePages() == [0] && bridge.page == 0 && abs(scroll.contentOffset.y - 90) < 0.01)
        bridge.turn(1)
        editor.endFlip(complete: true)
        r.check("표지가 내려앉으면 첫 펼침면 두 쪽이 보임", visiblePages() == [1, 2])

        bridge.turn(1)
        r.check("마지막 한 쪽도 펼쳐지는 종이 뒷면으로만 보임", visiblePages().isEmpty)
        editor.endFlip(complete: true)
        bridge.turn(-1)
        r.check("마지막 장에서 돌아갈 때 왼쪽 페이지만 먼저 보임", visiblePages() == [1])
        editor.endFlip(complete: true)
        bridge.turn(-1)
        r.check("표지를 덮는 동안 고정된 표지가 먼저 나타나지 않음", visiblePages().isEmpty)
        editor.endFlip(complete: false)
        r.check("표지를 덮다 놓으면 원래 펼침면 복원", visiblePages() == [1, 2])
        bridge.turn(-1)
        editor.endFlip(complete: true)
        r.check("표지를 다 덮으면 오른쪽 표지만 보임", visiblePages() == [0])
    }

    private static func pageCurlTests(_ r: Results) {
        // 두 쪽 배치: 표지는 오른쪽, 홀수로 남은 마지막 쪽은 왼쪽 자리
        let withCover = PageRows.make(count: 4, twoUp: true, coverAlone: true)   // [0] [1,2] [3]
        r.check("두 쪽 줄 (표지 + 홀수 끝)", withCover == [[0], [1, 2], [3]], "\(withCover)")
        r.check("표지는 오른쪽 자리", PageRows.rightSlots([0], coverAlone: true) == [true])
        r.check("홀수로 남은 마지막 쪽은 왼쪽 자리", PageRows.rightSlots([3], coverAlone: true) == [false]
                && PageRows.rightSlots([4], coverAlone: false) == [false])
        r.check("두 쪽 줄은 왼쪽·오른쪽", PageRows.rightSlots([1, 2], coverAlone: true) == [false, true])

        // 말림 계산: 화면 좌표 그대로 셰이더와 같은 식으로 잡은 점이 손가락에 오는지
        func project(_ p: CGPoint, _ st: CurlGeometry.State) -> CGPoint {
            let n = st.normal, c = st.point, rad = st.radius
            let dist = (p.x - c.x) * n.dx + (p.y - c.y) * n.dy
            guard !st.flat, dist > 0 else { return p }
            let back = CGPoint(x: p.x - n.dx * dist, y: p.y - n.dy * dist)
            if dist < .pi * rad {
                let off = rad * sin(dist / rad)
                return CGPoint(x: back.x + n.dx * off, y: back.y + n.dy * off)
            }
            let off = dist - .pi * rad
            return CGPoint(x: back.x - n.dx * off, y: back.y - n.dy * off)
        }
        for spineOnLeft in [true, false] {
            let side = spineOnLeft ? "오른쪽 종이" : "왼쪽 종이"
            let g = CurlGeometry(rect: CGRect(x: 500, y: 40, width: 400, height: 560), spineOnLeft: spineOnLeft)
            let y: CGFloat = 520
            let rest = g.state(finger: g.rest(y), grabY: y)
            r.check("\(side): 안 넘기면 납작", rest.flat && rest.turned == 0, "\(rest)")
            let done = g.state(finger: g.turned(y), grabY: y)
            r.check("\(side): 다 넘기면 책등에서 반지름 0으로 접힘",
                    !done.flat && done.radius < 0.01 && abs(done.point.x - g.spineX) < 0.01 && abs(done.turned - 1) < 0.001,
                    "\(done)")
            let mirrored = project(CGPoint(x: g.freeX, y: 100), done)
            r.check("\(side): 다 넘긴 종이는 반대쪽 자리에 거울처럼",
                    abs(mirrored.x - (2 * g.spineX - g.freeX)) < 0.5 && abs(mirrored.y - 100) < 0.5, "\(mirrored)")
            let towardSpine: CGFloat = spineOnLeft ? -1 : 1
            var followOK = true
            for travel in stride(from: CGFloat(40), through: 760, by: 60) {
                let finger = CGPoint(x: g.freeX + towardSpine * travel, y: y - travel * 0.15)
                let clamped = g.clamp(finger, grabY: y)
                let st = g.state(finger: finger, grabY: y)
                let p = project(g.rest(y), st)
                if hypot(p.x - clamped.x, p.y - clamped.y) > 1 { followOK = false }
            }
            r.check("\(side): 잡은 점이 손가락을 따라감", followOK)
            let far = g.clamp(CGPoint(x: g.spineX + towardSpine * 3000, y: y - 2000), grabY: y)
            r.check("\(side): 책등에서 종이 폭보다 멀리 안 감",
                    abs(hypot(far.x - g.spineX, far.y - y) - g.width) < 0.01)
            let backward = g.state(finger: CGPoint(x: g.freeX - towardSpine * 50, y: y), grabY: y)
            r.check("\(side): 반대로 끌면 안 말림", backward.flat)
        }
        r.check("종이 넘기기 셰이더 컴파일", CurlResources.shared != nil)
        curlRenderSweep(r)
        // 화면 찍기가 비었을 때(투명·검정) 알아채는지
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in }.cgImage
        let paper = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }.cgImage
        // XDR 화면(아이패드 프로)처럼 16비트 확장 범위 사진도 텍스처에서 하얗게 나오는지
        if let res = CurlResources.shared, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
           let wide = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue) {
            wide.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
            wide.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            if let image = wide.makeImage(), let texture = res.texture(image) {
                var px = [UInt8](repeating: 0, count: 4)
                texture.getBytes(&px, bytesPerRow: 128, from: MTLRegionMake2D(16, 16, 1, 1), mipmapLevel: 0)
                r.check("16비트 확장 범위 사진도 하얀 텍스처", px[0] > 240 && px[1] > 240 && px[2] > 240 && px[3] > 240, "\(px)")
            } else {
                r.check("16비트 확장 범위 사진도 하얀 텍스처", false, "텍스처 못 만듦")
            }
        }
        r.check("빈 페이지 사진을 알아챔", blank.map(PageView.looksBlank) == true && paper.map(PageView.looksBlank) == false)
    }

    /// 유리 메모지·유리 글자·유리펜이 가득한 페이지도 넘기기 사진이 검게 나오지 않는지
    private static func glassPageImageTest(_ r: Results) async {
        let blank = await MainActor.run { () -> Bool? in
            let size = CGSize(width: 600, height: 800)
            let pdfPage = PDFPage()
            pdfPage.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            var big = PageElement(kind: .sticky, x: 20, y: 20, width: 560, height: 700)
            big.text = "She"
            big.fill = .glass
            var glyph = PageElement(kind: .text, x: 60, y: 300, width: 400, height: 120)
            glyph.text = "What"
            glyph.fontSize = 80
            glyph.glassText = true
            var stroke = line(.pen, .black, CGPoint(x: 40, y: 760), CGPoint(x: 560, y: 760), width: 8)
            stroke.randomSeed = GlassInk.seed(strength: 0.5)
            let view = PageView(index: 0, page: pdfPage, size: size, ink: PageInk(drawing: PKDrawing(strokes: [stroke])),
                                documentLock: ReadWriteLock())
            view.setElements([big, glyph], image: { _ in nil })
            view.updateGlassInk()
            return view.image(pointScale: 2).map(PageView.looksBlank)
        }
        r.check("유리 가득한 페이지도 넘기기 사진이 하얗게", blank == false, "\(String(describing: blank))")
    }

    /// 말린 종이를 화면 밖에 여러 손가락 자리로 그려 보고 검은 점(NaN·빈 텍스처)이 없는지
    private static func curlRenderSweep(_ r: Results) {
        guard let res = CurlResources.shared else { return }
        let size = CGSize(width: 640, height: 420)
        func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> MTLTexture? {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 280)).image { c in
                UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
                c.fill(CGRect(x: 0, y: 0, width: 200, height: 280))
            }
            return image.cgImage.flatMap(res.texture)
        }
        guard let front = solid(0.95, 0.94, 0.90), let back = solid(0.85, 0.92, 0.98) else {
            r.check("넘기기 텍스처 만들기", false)
            return
        }
        let colorD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                              height: Int(size.height), mipmapped: false)
        colorD.usage = [.renderTarget, .shaderRead]
        colorD.storageMode = .shared
        let depthD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: CurlResources.depthFormat, width: Int(size.width),
                                                              height: Int(size.height), mipmapped: false)
        depthD.usage = .renderTarget
        depthD.storageMode = .private
        guard let color = res.device.makeTexture(descriptor: colorD), let depth = res.device.makeTexture(descriptor: depthD)
        else { r.check("넘기기 그릴 판 만들기", false); return }

        var worst = (black: 0, total: 0, case: "")
        var frames = 0
        var alignedLandings = 0
        for spineOnLeft in [true, false] {
            let rect = spineOnLeft ? CGRect(x: 322, y: 30, width: 260, height: 360) : CGRect(x: 58, y: 30, width: 260, height: 360)
            let g = CurlGeometry(rect: rect, spineOnLeft: spineOnLeft)
            let landing = CGRect(x: 2 * g.spineX - rect.maxX, y: 78, width: rect.width, height: 250)
            let toward: CGFloat = spineOnLeft ? -1 : 1
            for grab in [rect.minY + 2, rect.maxY - 2] {
                // 아주 조금 끈 것부터 거의 다 넘긴 것까지, 위아래로도 흔들어서
                for travel in [0.6, 1.5, 3, 8, 30, 130, 260, 420, 505, 518, 520] as [CGFloat] {
                    for dy in [-120, 0, 120] as [CGFloat] {
                        for withBack in [true, false] {
                            let finger = CGPoint(x: g.freeX + toward * travel, y: grab + dy)
                            let st = g.state(finger: finger, grabY: grab)
                            let pass = MTLRenderPassDescriptor()
                            pass.colorAttachments[0].texture = color
                            pass.colorAttachments[0].loadAction = .clear
                            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                            pass.colorAttachments[0].storeAction = .store
                            pass.depthAttachment.texture = depth
                            pass.depthAttachment.clearDepth = 1
                            pass.stencilAttachment.texture = depth
                            pass.stencilAttachment.clearStencil = 0
                            guard let buffer = res.queue.makeCommandBuffer(),
                                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
                            res.encode(CurlResources.Frame(viewSize: size, leafRect: rect, underRect: rect, state: st,
                                                           pageWidth: rect.width, front: front, back: withBack ? back : nil,
                                                           landingTransform: g.landingTransform(to: withBack ? landing : nil,
                                                                                               progress: st.turned)),
                                       into: encoder)
                            encoder.endEncoding()
                            buffer.commit()
                            buffer.waitUntilCompleted()
                            frames += 1
                            var pixels = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
                            color.getBytes(&pixels, bytesPerRow: Int(size.width) * 4,
                                           from: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)), mipmapLevel: 0)
                            if withBack, st.turned == 1, dy == 0 {
                                func alpha(_ y: CGFloat) -> UInt8 {
                                    pixels[(Int(y) * Int(size.width) + Int(landing.midX)) * 4 + 3]
                                }
                                if alpha(landing.minY + 1) > 240, alpha(landing.maxY - 1) > 240,
                                   alpha(landing.minY - 2) < 20, alpha(landing.maxY + 2) < 20 { alignedLandings += 1 }
                            }
                            var black = 0, opaque = 0
                            pixels.withUnsafeBufferPointer { p in
                                var i = 0
                                while i < p.count {
                                    if p[i + 3] > 240 {
                                        opaque += 1
                                        if p[i] < 90 && p[i + 1] < 90 && p[i + 2] < 90 { black += 1 }
                                    }
                                    i += 8
                                }
                            }
                            if black > worst.black {
                                worst = (black, opaque, "책등 \(spineOnLeft ? "왼쪽" : "오른쪽") 잡은 y \(Int(grab - rect.minY)) "
                                         + "끈 거리 \(travel) dy \(dy) 뒷면 \(withBack) R \(st.radius)")
                            }
                        }
                    }
                }
            }
        }
        r.check("넘기는 종이에 검은 점 없음 (\(frames)장)", worst.black == 0,
                "검은 점 \(worst.black)/\(worst.total): \(worst.case)")
        r.check("양방향 말림 마지막 프레임의 위아래 픽셀이 다음 페이지와 일치", alignedLandings == 4)
    }

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
