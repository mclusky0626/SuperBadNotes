//
//  InkAnnotation.swift
//  BadNotes
//
//  필기를 PDF 안에 넣는 방식.
//  페이지마다 Stamp 주석 하나에 두 가지를 같이 담음:
//  - 보이는 모양: appearance stream. PDFKit이 저장할 때 draw(with:in:)를 호출해서 벡터로 기록함
//    → 파일 앱, 미리보기, 다른 PDF 앱에서도 필기가 보임
//  - 편집용 원본: /BNInk 키에 PKDrawing 데이터 (LZFSE 압축 + base64)
//    /BNMeta 키에 형식 버전과 저장 당시 페이지 좌표계
//    → BadNotes에서 다시 열면 획 단위로 그대로 편집 가능
//

import PDFKit
import PencilKit

nonisolated enum InkPayload {
    static let inkKey = PDFAnnotationKey(rawValue: "/BNInk")
    static let metaKey = PDFAnnotationKey(rawValue: "/BNMeta")
    /// 형식 이름 + 압축 방식. 형식이 바뀌면 숫자를 올림
    static let format = "BadNotes1 lzfse"

    enum PayloadError: LocalizedError {
        case notBase64
        case decompressFailed
        case unknownFormat(String)

        var errorDescription: String? {
            switch self {
            case .notBase64: "필기 데이터가 base64가 아님"
            case .decompressFailed: "필기 데이터 압축 풀기 실패"
            case .unknownFormat(let s): "모르는 필기 형식: \(s)"
            }
        }
    }

    struct ReadResult {
        /// 지금 페이지 좌표계 기준으로 합친 필기
        var drawing = PKDrawing()
        /// 읽는 데 성공한 BadNotes 필기 주석들 (화면용 문서에서는 떼어 냄)
        var annotations: [PDFAnnotation] = []
        /// 읽지 못한 주석에 대한 설명. 이런 주석은 건드리지 않고 그대로 둠
        var problems: [String] = []
    }

    static func encode(_ drawing: PKDrawing) throws -> String {
        let raw = drawing.dataRepresentation()
        let packed = try (raw as NSData).compressed(using: .lzfse) as Data
        return packed.base64EncodedString()
    }

    static func decode(_ string: String) throws -> PKDrawing {
        guard let packed = Data(base64Encoded: string, options: .ignoreUnknownCharacters) else {
            throw PayloadError.notBase64
        }
        let raw: Data
        do {
            raw = try (packed as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw PayloadError.decompressFailed
        }
        return try PKDrawing(data: raw)
    }

    static func meta(_ geometry: PageGeometry) -> String {
        "\(format) \(geometry.serialized)"
    }

    /// 메타 문자열 → 저장 당시 좌표계. 형식이 다르면 에러
    static func geometry(fromMeta meta: String) throws -> PageGeometry? {
        let parts = meta.split(separator: " ")
        let head = format.split(separator: " ")
        guard parts.count >= head.count, Array(parts.prefix(head.count)) == head else {
            throw PayloadError.unknownFormat(String(meta.prefix(40)))
        }
        return PageGeometry(serialized: Array(parts.dropFirst(head.count)))
    }

    /// 페이지에 붙은 BadNotes 필기를 모두 읽어서 지금 좌표계 기준 PKDrawing 하나로 합침
    static func read(from page: PDFPage) -> ReadResult {
        let current = PageGeometry(page: page)
        var result = ReadResult()
        for annotation in page.annotations {
            // 키 목록(annotationKeyValues)에는 안 보일 때가 있어서 값으로 직접 확인
            guard let payload = annotation.value(forAnnotationKey: inkKey) as? String else { continue }
            do {
                var drawing = try decode(payload)
                if let meta = annotation.value(forAnnotationKey: metaKey) as? String,
                   let saved = try geometry(fromMeta: meta),
                   !saved.isClose(to: current) {
                    drawing = drawing.transformed(using: current.transform(from: saved))
                }
                result.drawing.append(drawing)
                result.annotations.append(annotation)
            } catch {
                result.problems.append(error.localizedDescription)
            }
        }
        return result
    }
}

/// 저장할 때만 만드는 주석. PDFKit이 파일로 쓸 때 draw(with:in:)로 모양을 기록함
nonisolated final class InkAnnotation: PDFAnnotation {
    private var drawing = PKDrawing()
    private var geometry = PageGeometry(box: .zero, rotation: 0)

    /// bakeGlass: 다른 앱용 모양에 유리펜 흉내를 그릴지 (.badnote는 안 그림)
    private var bakeGlass = true

    init(drawing: PKDrawing, geometry: PageGeometry, bakeGlass: Bool = true) throws {
        let payload = try InkPayload.encode(drawing)
        // 주석 영역은 필기가 있는 곳만 (다른 앱에서 페이지 전체가 선택되지 않게)
        let appearanceBounds = drawing.strokes.reduce(into: CGRect.null) { bounds, stroke in
            bounds = bounds.union(BrushImprint.enclosingBounds(of: stroke))
        }
        var rect = appearanceBounds.applying(geometry.canvasToPage)
            .insetBy(dx: -2, dy: -2)
            .intersection(geometry.box)
        if rect.isNull || rect.width < 1 || rect.height < 1 {
            // 필기가 전부 페이지 밖에 있는 경우: 데이터만 보관
            rect = CGRect(x: geometry.box.minX, y: geometry.box.minY, width: 1, height: 1)
        }
        super.init(bounds: rect, forType: .stamp, withProperties: nil)
        self.drawing = drawing
        self.geometry = geometry
        self.bakeGlass = bakeGlass
        setValue(payload, forAnnotationKey: InkPayload.inkKey)
        setValue(InkPayload.meta(geometry), forAnnotationKey: InkPayload.metaKey)
        // 기본값이면 기기 사용자 이름이 PDF에 박힘
        userName = "BadNotes"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let shown = bakeGlass ? drawing : PKDrawing(strokes: drawing.strokes.filter { !GlassInk.isGlass($0) })
        InkRenderer.draw(shown, in: context, transform: geometry.canvasToPage)
    }
}
