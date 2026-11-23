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
