//
//  PageGeometry.swift
//  BadNotes
//
//  필기(PKDrawing)는 "화면에 보이는 페이지" 좌표로 저장됨
//    → 왼쪽 위가 원점, 아래로 +y, 페이지 회전이 이미 적용된 모양, 단위는 PDF 포인트
//  PDF 주석은 "페이지 좌표"로 그려짐
//    → 왼쪽 아래가 원점, 위로 +y, 회전 전 모양
//  이 둘 사이 변환을 맡음.
//

import PDFKit

nonisolated struct PageGeometry: Equatable, Sendable {
    /// 화면에 보이는 영역 (crop box), 페이지 좌표
    var box: CGRect
    /// 시계 방향 회전: 0, 90, 180, 270
    var rotation: Int

    init(box: CGRect, rotation: Int) {
        self.box = box.standardized
        self.rotation = (((rotation % 360) + 360) % 360) / 90 * 90
    }

    init(page: PDFPage) {
        self.init(box: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    /// 화면(캔버스)에 보이는 페이지 크기
    var canvasSize: CGSize {
        rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// 캔버스 좌표 → PDF 페이지 좌표
    var canvasToPage: CGAffineTransform {
        let x = box.minX, y = box.minY, w = box.width, h = box.height
        switch rotation {
        case 90:  return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: x, ty: y)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: x + w, ty: y)
        case 270: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: x + w, ty: y + h)
        default:  return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: y + h)
        }
    }

    /// `old` 좌표계로 저장된 필기를 지금 좌표계로 옮기는 변환
    /// (다른 앱이 페이지를 회전시키거나 잘라 냈을 때)
    func transform(from old: PageGeometry) -> CGAffineTransform {
        old.canvasToPage.concatenating(canvasToPage.inverted())
    }

    func isClose(to other: PageGeometry, tolerance: CGFloat = 0.01) -> Bool {
        rotation == other.rotation
            && abs(box.minX - other.box.minX) <= tolerance
            && abs(box.minY - other.box.minY) <= tolerance
            && abs(box.width - other.box.width) <= tolerance
            && abs(box.height - other.box.height) <= tolerance
    }

    // MARK: 저장용 문자열 "x y w h 회전"

    var serialized: String {
        func f(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }
        return "\(f(box.minX)) \(f(box.minY)) \(f(box.width)) \(f(box.height)) \(rotation)"
    }

    init?<S: StringProtocol>(serialized parts: [S]) {
        guard parts.count == 5,
              let x = Double(parts[0]), let y = Double(parts[1]),
              let w = Double(parts[2]), let h = Double(parts[3]),
              let r = Int(parts[4]) else { return nil }
        self.init(box: CGRect(x: x, y: y, width: w, height: h), rotation: r)
    }
}
