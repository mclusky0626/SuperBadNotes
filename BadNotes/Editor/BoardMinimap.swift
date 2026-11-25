import SwiftUI
import PencilKit
import PDFKit

nonisolated struct BoardPlace: Codable, Identifiable {
    let id: UUID
    var name: String
    var point: CGPoint
    static let prefix = "BadNotesBoardPlaces:"

    static func load(from document: PDFDocument) -> [Self] {
        guard let keyword = PaperSpec.keywords(document.documentAttributes).first(where: { $0.hasPrefix(prefix) }),
              let data = Data(base64Encoded: String(keyword.dropFirst(prefix.count))) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    static func write(_ places: [Self], to document: PDFDocument) throws {
        var attributes = document.documentAttributes ?? [:]
        var keywords = PaperSpec.keywords(attributes).filter { !$0.hasPrefix(prefix) }
        if !places.isEmpty { keywords.append(prefix + (try JSONEncoder().encode(places)).base64EncodedString()) }
        attributes[PDFDocumentAttribute.keywordsAttribute] = keywords
        document.documentAttributes = attributes
    }
}

@Observable final class BoardMapState {
    var size = CGSize.zero
    var visible = CGRect.zero
    @ObservationIgnored weak var scroll: UIScrollView?
    @ObservationIgnored weak var board: UIView?
    @ObservationIgnored var insets = UIEdgeInsets.zero

    func update(_ scroll: UIScrollView, board: UIView, insets: UIEdgeInsets) {
        self.scroll = scroll
        self.board = board
        self.insets = insets
        let rect = scroll.convert(scroll.bounds.inset(by: insets), to: board).intersection(board.bounds)
        if size != board.bounds.size { size = board.bounds.size }
        if visible != rect { visible = rect }
    }

    func jump(to point: CGPoint) {
        guard let scroll, let board else { return }
        let target = board.convert(point, to: scroll)
        let view = scroll.bounds.inset(by: insets)
        let limits = scroll.adjustedContentInset
        let offset = scroll.contentOffset
        let x = min(scroll.contentSize.width - scroll.bounds.width + limits.right, offset.x + target.x - view.midX)
        let y = min(scroll.contentSize.height - scroll.bounds.height + limits.bottom, offset.y + target.y - view.midY)
        scroll.setContentOffset(CGPoint(x: max(-limits.left, x), y: max(-limits.top, y)), animated: false)
    }
}

struct BoardMinimap: View {
    let note: NoteDocument
    let map: BoardMapState
    @State private var name = ""
    @State private var destination: CGPoint?
    @State private var naming = false
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text("미니맵").font(.caption.bold())
                Spacer()
                Menu {
                    Button("현재 위치 저장", systemImage: "bookmark.badge.plus") {
                        destination = CGPoint(x: map.visible.midX, y: map.visible.midY)
                        name = ""
                        naming = true
                    }.disabled(map.visible.isNull || map.visible.isEmpty)
                    ForEach(note.boardPlaces) { place in
                        Button(place.name) { map.jump(to: place.point) }
                    }
                } label: { Image(systemName: "bookmark").frame(width: 40, height: 32) }
                .accessibilityLabel("저장한 위치")
            }
            GeometryReader { geo in
                let scale = min(geo.size.width / max(1, map.size.width), geo.size.height / max(1, map.size.height))
                let size = CGSize(width: map.size.width * scale, height: map.size.height * scale)
                Canvas { ctx, _ in
                    let area = CGRect(origin: .zero, size: size)
                    ctx.fill(Path(area), with: .color(.white))
                    if let thumbnail { ctx.draw(Image(uiImage: thumbnail), in: area) }
                    let t = CGAffineTransform(scaleX: scale, y: scale)
                    for element in note.elements(for: 0) {
                        ctx.fill(Path(element.frame.applying(t)), with: .color(.gray.opacity(0.55)))
                    }
                    if !map.visible.isNull {
                        let path = Path(map.visible.applying(t))
                        ctx.fill(path, with: .color(.blue.opacity(0.16)))
                        ctx.stroke(path, with: .color(.blue), lineWidth: 2)
                    }
                    for place in note.boardPlaces {
                        ctx.fill(Path(ellipseIn: CGRect(origin: place.point.applying(t), size: .zero).insetBy(dx: -3, dy: -3)), with: .color(.orange))
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped().contentShape(Rectangle())
                .onTapGesture { p in if scale > 0 { map.jump(to: CGPoint(x: p.x / scale, y: p.y / scale)) } }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }.frame(height: 76)
        }
        .frame(width: 136).padding(8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .task(id: note.boardMapRevision) {
            guard let page = note.pdf.page(at: 0) else { return }
            let rect = page.bounds(for: .cropBox)
            let drawing = note.drawing(for: 0)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, rect.width > 0, rect.height > 0 else { return }
            let image = await Task.detached(priority: .utility) {
                drawing.image(from: rect, scale: 300 / max(rect.width, rect.height))
            }.value
            if !Task.isCancelled { thumbnail = image }
        }
        .alert("현재 위치 이름", isPresented: $naming) {
            TextField("이름", text: $name)
            Button("저장") { if let destination { note.addBoardPlace(name, at: destination) } }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("취소", role: .cancel) {}
        }
    }
}
