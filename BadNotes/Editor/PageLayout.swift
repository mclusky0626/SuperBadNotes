//
//  PageLayout.swift
//  BadNotes
//
//  페이지 배치 (편집기 두 모드가 같이 씀).
//  - 줄: 세로 화면은 한 쪽씩, 가로 화면(두 쪽 펼치기)은 두 쪽씩. 표지가 있으면 표지는 혼자 (책처럼)
//  - 두 쪽 화면에서 혼자인 쪽은 책처럼 제자리에: 표지는 오른쪽, 홀수로 남은 마지막 쪽은 왼쪽 (오른쪽은 빈 자리)
//  - 넘기기 애니메이션은 PageCurl.swift
//

import UIKit

nonisolated enum PageRows {
    static func make(count: Int, twoUp: Bool, coverAlone: Bool) -> [[Int]] {
        guard count > 0 else { return [] }
        guard twoUp else { return (0..<count).map { [$0] } }
        var rows: [[Int]] = []
        var index = 0
        if coverAlone {
            rows.append([0])
            index = 1
        }
        while index < count {
            rows.append(index + 1 < count ? [index, index + 1] : [index])
            index += 2
        }
        return rows
    }

    /// 두 쪽 화면에서 이 줄의 각 쪽이 오른쪽 자리인지 (줄 순서대로)
    static func rightSlots(_ row: [Int], coverAlone: Bool) -> [Bool] {
        if row.count >= 2 { return [false, true] }
        return [coverAlone && row == [0]]
    }

    static func row(containing page: Int, in rows: [[Int]]) -> Int {
        rows.firstIndex { $0.contains(page) } ?? max(0, min(rows.count - 1, page))
    }
}

/// 페이지의 PDF 좌표를 편집기 좌표로 옮기는 균일 배율과 위치.
nonisolated struct PagePlacement: Equatable {
    let index: Int
    let frame: CGRect
    let scale: CGFloat

    var transform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: frame.minX, ty: frame.minY)
    }

    @MainActor func apply(to view: UIView) {
        view.transform = CGAffineTransform(scaleX: scale, y: scale)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
    }
}

nonisolated struct PageArrangement {
    let placements: [PagePlacement]
    let size: CGSize

    init(sizes: [CGSize], rows: [[Int]], twoUp: Bool, coverAlone: Bool) {
        // 두 쪽은 PDF마다 원래 폭이 달라도 화면의 절반씩 차지한다.
        // 한 쪽 보기에서는 서로 다른 크기의 PDF를 원래 배율로 나란히 유지한다.
        let referenceWidth: CGFloat?
        if twoUp {
            referenceWidth = sizes.first?.width
        } else {
            referenceWidth = rows.joined().map { sizes[$0].width }.max()
        }
        let slotWidth = max(1, referenceWidth ?? 1)
        let rowGap = slotWidth * 0.006
        var result: [PagePlacement] = []
        var y: CGFloat = 0
        for row in rows {
            if !result.isEmpty { y += rowGap }
            var rowHeight: CGFloat = 0
            for (index, right) in zip(row, PageRows.rightSlots(row, coverAlone: coverAlone)) {
                let size = sizes[index]
                let scale = twoUp ? slotWidth / max(1, size.width) : 1
                let width = size.width * scale
                let height = size.height * scale
                let x = twoUp ? (right ? slotWidth : 0) : (slotWidth - width) / 2
                // 같은 줄의 첫 필기 위치와 책등이 종이 크기에 따라 움직이지 않게 위쪽을 맞춘다.
                result.append(PagePlacement(index: index, frame: CGRect(x: x, y: y, width: width, height: height), scale: scale))
                rowHeight = max(rowHeight, height)
            }
            y += rowHeight
        }
        placements = result
        size = CGSize(width: slotWidth * (twoUp ? 2 : 1), height: max(1, y))
    }
}
