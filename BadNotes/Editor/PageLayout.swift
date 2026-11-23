//
//  PageLayout.swift
//  BadNotes
//
//  페이지 배치와 넘기기 애니메이션 (편집기 두 모드가 같이 씀).
//  - 줄: 세로 화면은 한 쪽씩, 가로 화면(두 쪽 펼치기)은 두 쪽씩. 표지가 있으면 표지는 혼자 (책처럼)
//  - 넘기기: 넘어가는 종이가 책등을 축으로 들렸다가 반대쪽에 내려앉는 3D 애니메이션 + 그늘
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

    static func row(containing page: Int, in rows: [[Int]]) -> Int {
        rows.firstIndex { $0.contains(page) } ?? max(0, min(rows.count - 1, page))
    }
}

/// 종이 넘기기 애니메이션. 화면 좌표의 페이지 사진(스냅샷)으로 그림
@MainActor
enum PageTurn {
    struct Sheet {
        let snapshot: UIView
        let frame: CGRect
    }

    /// - old: 넘기기 전 보이던 페이지들 (왼쪽부터)
    /// - newBack: 넘어가는 종이 뒷면이 될 새 페이지를 중간에 찍어 오는 함수 (못 찍으면 흰 종이)
    static func run(in host: UIView, old: [Sheet], forward: Bool, duration: TimeInterval = 0.62,
                    newBack: @escaping (CGRect) -> UIView?, completion: @escaping () -> Void) {
        guard !old.isEmpty else { completion(); return }
        let stage = UIView(frame: host.bounds)
        stage.isUserInteractionEnabled = true
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1800
        stage.layer.sublayerTransform = perspective
        host.addSubview(stage)

        // 넘어가는 종이 = 앞으로면 오른쪽 페이지, 뒤로면 왼쪽 페이지
        let leafSheet = forward ? old[old.count - 1] : old[0]
        // 두 쪽일 때 반대쪽은 끝날 때까지 그대로 덮어 둠 (새 페이지가 미리 보이지 않게)
        var staticViews: [UIView] = []
        if old.count == 2 {
            let other = forward ? old[0] : old[1]
            other.snapshot.frame = other.frame
            stage.addSubview(other.snapshot)
            staticViews.append(other.snapshot)
        }

        let leaf = makeLeaf(content: leafSheet.snapshot, frame: leafSheet.frame, anchorLeft: forward)
        stage.addSubview(leaf.view)
        // 바닥에 드리우는 그림자 (책등 쪽이 진함)
        let floorShade = UIView(frame: leafSheet.frame)
        floorShade.backgroundColor = .black
        floorShade.alpha = 0
        floorShade.isUserInteractionEnabled = false
        stage.insertSubview(floorShade, belowSubview: leaf.view)

        let half = duration / 2
        UIView.animate(withDuration: half, delay: 0, options: [.curveEaseIn]) {
            leaf.view.layer.transform = CATransform3DMakeRotation(forward ? -.pi / 2 : .pi / 2, 0, 1, 0)
            leaf.shade.alpha = 0.38
            floorShade.alpha = 0.12
        } completion: { _ in
            leaf.view.removeFromSuperview()
            floorShade.removeFromSuperview()
            guard old.count == 2 else {
                // 한 쪽: 들려 나간 종이 밑에 새 페이지가 이미 깔려 있음
                stage.removeFromSuperview()
                completion()
                return
            }
            // 두 쪽: 종이 뒷면(새 페이지)이 반대쪽에 내려앉음
            let landing = forward ? old[0].frame : old[1].frame
            let back = newBack(landing) ?? {
                let paper = UIView()
                paper.backgroundColor = .white
                return paper
            }()
            let fall = makeLeaf(content: back, frame: landing, anchorLeft: !forward)
            fall.view.layer.transform = CATransform3DMakeRotation(forward ? .pi / 2 : -.pi / 2, 0, 1, 0)
            fall.shade.alpha = 0.38
            stage.addSubview(fall.view)
            UIView.animate(withDuration: half, delay: 0, options: [.curveEaseOut]) {
                fall.view.layer.transform = CATransform3DIdentity
                fall.shade.alpha = 0
            } completion: { _ in
                UIView.animate(withDuration: 0.08) {
                    stage.alpha = 0
                } completion: { _ in
                    stage.removeFromSuperview()
                    completion()
                }
            }
        }
        _ = staticViews
    }

    /// 한쪽 가장자리(책등)를 축으로 도는 종이. shade = 기울수록 어두워지는 막
    private static func makeLeaf(content: UIView, frame: CGRect, anchorLeft: Bool) -> (view: UIView, shade: UIView) {
        let view = UIView()
        view.layer.anchorPoint = CGPoint(x: anchorLeft ? 0 : 1, y: 0.5)
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.layer.position = CGPoint(x: anchorLeft ? frame.minX : frame.maxX, y: frame.midY)
        view.layer.isDoubleSided = false
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.25
        view.layer.shadowRadius = 12
        view.layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: frame.size)).cgPath
        content.frame = view.bounds
        view.addSubview(content)
        // 책등 쪽에서 바깥쪽으로 옅어지는 그늘
        let shade = UIView(frame: view.bounds)
        let gradient = CAGradientLayer()
        gradient.frame = shade.bounds
        gradient.colors = [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0.35).cgColor]
        gradient.startPoint = CGPoint(x: anchorLeft ? 0 : 1, y: 0.5)
        gradient.endPoint = CGPoint(x: anchorLeft ? 1 : 0, y: 0.5)
        shade.layer.addSublayer(gradient)
        shade.alpha = 0
        view.addSubview(shade)
        return (view, shade)
    }
}
