//
//  PageElement.swift
//  BadNotes
//
//  페이지 위에 놓는 것들: 텍스트 상자, 유리 메모지, 사진.
//  좌표는 필기와 같은 페이지 캔버스 좌표 (왼쪽 위 원점, pt).
//
//  PDF 안에 넣는 방식 (필기와 같은 생각):
//  - 페이지마다 Stamp 주석 하나에 그 페이지의 요소를 전부 담음
//  - 보이는 모양: appearance stream (다른 앱용. 유리는 반투명 판으로 비슷하게)
//  - 편집용 원본: /BNElements (JSON, LZFSE + base64), /BNImages (사진 원본, 이진 plist + base64),
//    /BNMeta (형식 + 저장 당시 페이지 좌표계)
//  - 주석 순서는 필기보다 앞 → 다른 앱에서도 필기가 요소 위에 그려짐
//

import PDFKit
import UIKit
import CryptoKit

nonisolated struct PageElement: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text, sticky, image
    }

    /// 텍스트 상자 바탕
    enum Fill: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, color, glass
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "바탕 없음"
            case .color: "색 바탕"
            case .glass: "Liquid Glass"
            }
        }
        var shortTitle: String {
            switch self {
            case .none: "없음"
            case .color: "색"
            case .glass: "유리"
            }
        }
        var icon: String {
            switch self {
            case .none: "textformat"
            case .color: "square.fill"
            case .glass: "drop.halffull"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var text = ""
    var fontSize: CGFloat = 20
    var bold = false
    var textColor = RGBAColor(hex: 0x1C1C1E)
    /// 0 왼쪽, 1 가운데, 2 오른쪽
    var alignment = 0
    var fill = Fill.none
    /// 색 바탕 / 메모지 유리 색
    var fillColor = RGBAColor(hex: 0xFFE07A)
    /// 사진이면 문서 안 사진 번호 (내용 해시)
    var imageID: String?
    /// 글꼴 (`TextFonts`의 번호)
    var font = "system"
    /// 유리: 맑게(뒤가 더 비침) / 뿌옇게
    var glassClear = false
    /// 유리에 입히는 색의 진하기 (0 = 색 없음). 색은 fillColor
    var glassTint: Double = 0

    init(kind: Kind, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        if kind == .sticky {
            glassClear = true
            glassTint = 0.3
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, x, y, width, height, text, fontSize, bold, textColor, alignment, fill, fillColor, imageID
        case font, glassClear, glassTint
    }

    /// 예전(1.2) 파일에는 글꼴·유리 값이 없어서 없으면 기본값
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decode(CGFloat.self, forKey: .x)
        y = try c.decode(CGFloat.self, forKey: .y)
        width = try c.decode(CGFloat.self, forKey: .width)
        height = try c.decode(CGFloat.self, forKey: .height)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 20
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        textColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? RGBAColor(hex: 0x1C1C1E)
        alignment = try c.decodeIfPresent(Int.self, forKey: .alignment) ?? 0
        fill = try c.decodeIfPresent(Fill.self, forKey: .fill) ?? .none
        fillColor = try c.decodeIfPresent(RGBAColor.self, forKey: .fillColor) ?? RGBAColor(hex: 0xFFE07A)
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID)
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? "system"
        glassClear = try c.decodeIfPresent(Bool.self, forKey: .glassClear) ?? (kind == .sticky)
        glassTint = try c.decodeIfPresent(Double.self, forKey: .glassTint) ?? (kind == .sticky ? 0.3 : 0)
    }

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.minX
            y = newValue.minY
            width = newValue.width
            height = newValue.height
        }
    }

    var hasText: Bool { kind != .image }
    var usesGlass: Bool { kind == .sticky || (kind == .text && fill == .glass) }

    /// 글자 둘레 여백
    var padding: CGSize {
        switch kind {
        case .sticky: CGSize(width: 18, height: 16)
        case .text: fill == .none ? CGSize(width: 6, height: 4) : CGSize(width: 14, height: 10)
        case .image: .zero
        }
    }

    var cornerRadius: CGFloat {
        switch kind {
        case .sticky: 22
        case .text: fill == .glass ? 18 : 10
        case .image: 4
        }
    }

    /// 메모지 색 고르기
    static let stickyColors: [(String, RGBAColor)] = [
        ("노랑", RGBAColor(hex: 0xFFD84D)), ("분홍", RGBAColor(hex: 0xFF8FB8)), ("하늘", RGBAColor(hex: 0x6CC4FF)),
        ("민트", RGBAColor(hex: 0x6EE0B4)), ("보라", RGBAColor(hex: 0xB79CFF)), ("투명", RGBAColor(hex: 0xFFFFFF, alpha: 0)),
    ]

    /// 색 바탕 고르기
    static let fillColors: [(String, RGBAColor)] = [
        ("노랑", RGBAColor(hex: 0xFFF0A8)), ("분홍", RGBAColor(hex: 0xFFD6E4)), ("하늘", RGBAColor(hex: 0xD3ECFF)),
        ("민트", RGBAColor(hex: 0xD2F5E6)), ("회색", RGBAColor(hex: 0xECECEF)), ("검정", RGBAColor(hex: 0x2B2B30)),
    ]
}

// MARK: - 글자·사진 그리기 (PDF 모양과 편집기 타일이 같은 코드)

nonisolated enum ElementRenderer {
    static func font(_ e: PageElement) -> UIFont {
        TextFonts.font(e.font, size: e.fontSize, bold: e.bold)
    }

    static func paragraph(_ e: PageElement) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = [.left, .center, .right][min(max(e.alignment, 0), 2)]
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func attributes(_ e: PageElement) -> [NSAttributedString.Key: Any] {
        [.font: font(e), .foregroundColor: e.textColor.uiColor.withAlphaComponent(1), .paragraphStyle: paragraph(e)]
    }

    /// 상자 폭에 맞춘 높이 (글자가 늘면 상자가 아래로 길어짐)
    static func fittedHeight(_ e: PageElement) -> CGFloat {
        guard e.hasText else { return e.height }
        let inner = max(10, e.width - e.padding.width * 2)
        let sample = e.text.isEmpty ? "가" : (e.text.hasSuffix("\n") ? e.text + "가" : e.text)
        let box = (sample as NSString).boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: attributes(e), context: nil)
        let height = ceil(box.height) + e.padding.height * 2
        return e.kind == .sticky ? max(height, e.width * 0.8) : height
    }

    /// 바탕. live = 화면에서 진짜 유리를 따로 그릴 때는 유리 바탕을 건너뜀
    static func drawBackground(_ e: PageElement, in context: CGContext, rect: CGRect, live: Bool) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: min(e.cornerRadius, rect.width / 2, rect.height / 2)).cgPath
        switch (e.kind, e.fill) {
        case (.text, .color):
            context.addPath(path)
            context.setFillColor(e.fillColor.uiColor.cgColor)
            context.fillPath()
        case (.sticky, _), (.text, .glass):
            guard !live else { return }
            // 다른 앱용 유리 흉내: 반투명 판(맑으면 더 투명) + 색 + 밝은 테두리
            let base = UIColor(red: 1, green: 1, blue: 1, alpha: e.glassClear ? 0.25 : 0.55).cgColor
            context.addPath(path)
            context.setFillColor(base)
            context.fillPath()
            if e.fillColor.a > 0.01, e.glassTint > 0.01 {
                context.addPath(path)
                context.setFillColor(e.fillColor.uiColor.withAlphaComponent(min(0.9, e.glassTint)).cgColor)
                context.fillPath()
            }
            context.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                         cornerRadius: min(e.cornerRadius, rect.width / 2, rect.height / 2)).cgPath)
            context.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
            context.setLineWidth(1)
            context.strokePath()
            context.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25),
                                         cornerRadius: min(e.cornerRadius, rect.width / 2, rect.height / 2)).cgPath)
            context.setStrokeColor(UIColor(white: 0, alpha: 0.12).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
        default:
            break
        }
    }

    /// 글자 또는 사진. UIKit 좌표(위가 원점)인 상태에서 불러야 함
    static func drawContent(_ e: PageElement, image: CGImage?, in context: CGContext, rect: CGRect) {
        switch e.kind {
        case .image:
            guard let image else {
                context.setFillColor(UIColor(white: 0.85, alpha: 1).cgColor)
                context.fill(rect)
                return
            }
            context.saveGState()
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: e.cornerRadius).cgPath)
            context.clip()
            UIGraphicsPushContext(context)
            UIImage(cgImage: image).draw(in: rect)
            UIGraphicsPopContext()
            context.restoreGState()
        case .text, .sticky:
            guard !e.text.isEmpty else { return }
            UIGraphicsPushContext(context)
            let inner = rect.insetBy(dx: e.padding.width, dy: e.padding.height)
            (e.text as NSString).draw(with: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: attributes(e), context: nil)
            UIGraphicsPopContext()
        }
    }
}

// MARK: - 사진 보관

nonisolated enum ElementImages {
    /// 사진은 긴 변 2400px 안으로 줄이고 JPEG(투명하면 PNG)로. 번호는 내용 해시
    static func prepare(_ data: Data) -> (id: String, data: Data, size: CGSize)? {
        guard let source = UIImage(data: data), let cg = source.cgImage ?? render(source) else { return nil }
        let maxSide: CGFloat = 2400
        let pixel = CGSize(width: cg.width, height: cg.height)
        var image = UIImage(cgImage: cg, scale: 1, orientation: source.imageOrientation)
        let oriented = image.size
        let scale = min(1, maxSide / max(oriented.width, oriented.height))
        if scale < 1 || source.imageOrientation != .up {
            let size = CGSize(width: (oriented.width * scale).rounded(), height: (oriented.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        let hasAlpha: Bool = {
            guard let alpha = image.cgImage?.alphaInfo else { return false }
            return !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        }()
        guard let encoded = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.88) else { return nil }
        _ = pixel
        let id = SHA256.hash(data: encoded).prefix(10).map { String(format: "%02x", $0) }.joined()
        return (id, encoded, image.size)
    }

    private static func render(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }

    static func decode(_ data: Data) -> CGImage? {
        UIImage(data: data)?.cgImage
    }
}

// MARK: - PDF 안에 넣고 꺼내기

nonisolated enum ElementPayload {
    static let elementsKey = PDFAnnotationKey(rawValue: "/BNElements")
    static let imagesKey = PDFAnnotationKey(rawValue: "/BNImages")
    static let metaKey = PDFAnnotationKey(rawValue: "/BNElementMeta")
    static let format = "BadNotesElements1"

    struct ReadResult {
        var elements: [PageElement] = []
        var images: [String: Data] = [:]
        var annotations: [PDFAnnotation] = []
        var problems: [String] = []
    }

    static func encode(_ elements: [PageElement]) throws -> String {
        let json = try JSONEncoder().encode(elements)
        let packed = try (json as NSData).compressed(using: .lzfse) as Data
        return packed.base64EncodedString()
    }

    static func decode(_ string: String) throws -> [PageElement] {
        guard let packed = Data(base64Encoded: string, options: .ignoreUnknownCharacters) else {
            throw InkPayload.PayloadError.notBase64
        }
        let raw: Data
        do { raw = try (packed as NSData).decompressed(using: .lzfse) as Data } catch {
            throw InkPayload.PayloadError.decompressFailed
        }
        return try JSONDecoder().decode([PageElement].self, from: raw)
    }

    static func encodeImages(_ images: [String: Data]) throws -> String {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(images).base64EncodedString()
    }

    static func decodeImages(_ string: String) throws -> [String: Data] {
        guard let data = Data(base64Encoded: string, options: .ignoreUnknownCharacters) else {
            throw InkPayload.PayloadError.notBase64
        }
        return try PropertyListDecoder().decode([String: Data].self, from: data)
    }

    static func read(from page: PDFPage) -> ReadResult {
        let current = PageGeometry(page: page)
        var result = ReadResult()
        for annotation in page.annotations {
            guard let payload = annotation.value(forAnnotationKey: elementsKey) as? String else { continue }
            do {
                var elements = try decode(payload)
                if let meta = annotation.value(forAnnotationKey: metaKey) as? String {
                    let parts = meta.split(separator: " ")
                    if parts.first == Substring(format),
                       let saved = PageGeometry(serialized: Array(parts.dropFirst())), !saved.isClose(to: current) {
                        let t = current.transform(from: saved)
                        for i in elements.indices { elements[i].frame = elements[i].frame.applying(t).standardized }
                    }
                }
                if let images = annotation.value(forAnnotationKey: imagesKey) as? String {
                    result.images.merge(try decodeImages(images)) { a, _ in a }
                }
                result.elements += elements
                result.annotations.append(annotation)
            } catch {
                result.problems.append("요소: \(error.localizedDescription)")
            }
        }
        return result
    }
}

/// 저장할 때만 만드는 요소 주석. PDFKit이 파일로 쓸 때 draw(with:in:)로 모양을 기록함
nonisolated final class ElementAnnotation: PDFAnnotation {
    private var elements: [PageElement] = []
    private var images: [String: CGImage] = [:]
    private var geometry = PageGeometry(box: .zero, rotation: 0)

    init(elements: [PageElement], images: [String: Data], geometry: PageGeometry) throws {
        var rect = elements.reduce(CGRect.null) { $0.union($1.frame) }
            .applying(geometry.canvasToPage).insetBy(dx: -2, dy: -2).intersection(geometry.box)
        if rect.isNull || rect.width < 1 || rect.height < 1 {
            rect = CGRect(x: geometry.box.minX, y: geometry.box.minY, width: 1, height: 1)
        }
        super.init(bounds: rect, forType: .stamp, withProperties: nil)
        self.elements = elements
        self.geometry = geometry
        let used = Set(elements.compactMap(\.imageID))
        let mine = images.filter { used.contains($0.key) }
        for (id, data) in mine { self.images[id] = ElementImages.decode(data) }
        setValue(try ElementPayload.encode(elements), forAnnotationKey: ElementPayload.elementsKey)
        if !mine.isEmpty {
            setValue(try ElementPayload.encodeImages(mine), forAnnotationKey: ElementPayload.imagesKey)
        }
        setValue("\(ElementPayload.format) \(geometry.serialized)", forAnnotationKey: ElementPayload.metaKey)
        userName = "BadNotes"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.concatenate(geometry.canvasToPage)
        for element in elements {
            ElementRenderer.drawBackground(element, in: context, rect: element.frame, live: false)
            ElementRenderer.drawContent(element, image: element.imageID.flatMap { images[$0] }, in: context, rect: element.frame)
        }
        context.restoreGState()
    }
}

// MARK: - 글꼴

/// 텍스트 상자 글꼴. 기본 글꼴 모양 4가지 + 기기에 있는 글꼴 (없는 글꼴은 목록에서 뺌)
nonisolated enum TextFonts {
    struct Option: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
    }

    static let builtIn: [Option] = [
        Option(id: "system", title: "기본"), Option(id: "rounded", title: "둥근"),
        Option(id: "serif", title: "명조"), Option(id: "mono", title: "고정폭"),
    ]

    private static let named: [Option] = [
        Option(id: "NanumPen", title: "나눔손글씨 펜"), Option(id: "NanumBrush", title: "나눔손글씨 붓"),
        Option(id: "NanumMyeongjo", title: "나눔명조"), Option(id: "NanumGothic", title: "나눔고딕"),
        Option(id: "AppleMyungjo", title: "애플 명조"), Option(id: "Noteworthy-Light", title: "Noteworthy"),
        Option(id: "ChalkboardSE-Regular", title: "Chalkboard"), Option(id: "AmericanTypewriter", title: "타자기"),
        Option(id: "Georgia", title: "Georgia"), Option(id: "Avenir-Book", title: "Avenir"),
        Option(id: "SnellRoundhand", title: "필기체"),
    ]

    static let available: [Option] = builtIn + named.filter { UIFont(name: $0.id, size: 12) != nil }

    static func title(_ id: String) -> String {
        available.first { $0.id == id }?.title ?? "기본"
    }

    static func font(_ id: String, size: CGFloat, bold: Bool) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let design: UIFontDescriptor.SystemDesign?
        switch id {
        case "system": return system
        case "rounded": design = .rounded
        case "serif": design = .serif
        case "mono": design = .monospaced
        default: design = nil
        }
        if let design, let descriptor = system.fontDescriptor.withDesign(design) {
            return UIFont(descriptor: descriptor, size: size)
        }
        guard let named = UIFont(name: id, size: size) else { return system }
        if bold, let descriptor = named.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return named
    }
}
