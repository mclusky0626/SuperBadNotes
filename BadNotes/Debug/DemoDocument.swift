//
//  DemoDocument.swift
//  BadNotes
//
//  점검용 시연 문서 (디버그 빌드에만 들어감).
//  -BNInkDemo 로 켜면 사용자 문서 대신 임시 폴더에 새로 만든 이 PDF에서 시연함.
//

#if DEBUG
import UIKit

nonisolated enum DemoDocument {
    static var url: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BadNotesDemo", isDirectory: true)
            .appendingPathComponent("필기 시연.pdf")
    }

    /// A4 세 쪽짜리 글 문서를 새로 만듦. 지난 시연이 남긴 백업·복구 기록도 정리
    static func make() throws -> URL {
        let fm = FileManager.default
        let target = url
        try? fm.removeItem(at: target.deletingLastPathComponent())
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = AppPaths.key(for: target)
        try? fm.removeItem(at: AppPaths.backups.appendingPathComponent(key, isDirectory: true))
        try? fm.removeItem(at: AppPaths.journal.appendingPathComponent(key, isDirectory: true))

        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let title: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: UIColor(red: 0.8, green: 0.2, blue: 0.15, alpha: 1),
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor(white: 0.15, alpha: 1),
        ]
        let sentence = "필기가 페이지와 함께 그려져서 아무리 확대해도 선명한지 확인하는 시연 문서입니다. "
        try UIGraphicsPDFRenderer(bounds: page).writePDF(to: target) { context in
            for number in 1...3 {
                context.beginPage()
                NSAttributedString(string: "BadNotes 필기 시연 \(number)쪽", attributes: title)
                    .draw(at: CGPoint(x: 48, y: 56))
                var y: CGFloat = 120
                while y < 760 {
                    NSAttributedString(string: String(repeating: sentence, count: 2), attributes: body)
                        .draw(in: CGRect(x: 48, y: y, width: page.width - 96, height: 22))
                    y += 26
                }
            }
        }
        return target
    }
}
#endif
