//
//  InkGestureRecognizer.swift
//  BadNotes
//
//  펜슬(설정하면 손가락도) 하나만 따라가는 인식기. 획 단위로 시작/이동/끝을 알려 줌.
//  손가락은 기본적으로 안 받아서 스크롤·확대는 스크롤뷰가 그대로 처리함.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

final class InkGestureRecognizer: UIGestureRecognizer {
    /// false를 돌려주면 이 터치는 무시 (페이지 밖 등)
    var onBegan: ((UITouch, UIEvent) -> Bool)?
    var onMoved: ((UITouch, UIEvent) -> Void)?
    /// 마지막 값: 취소됐는지
    var onEnded: ((UITouch, UIEvent?, Bool) -> Void)?
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked {
            if tracked.type != .pencil {
                // 손가락으로 쓰는 중에 손가락이 하나 더 오면 스크롤/확대하려는 것 → 그리던 획은 버림
                onEnded?(tracked, event, true)
                self.tracked = nil
                state = .cancelled
            } else {
                for touch in touches { ignore(touch, for: event) }
            }
            return
        }
        guard touches.count == 1, let touch = touches.first, onBegan?(touch, event) == true else {
            state = .failed
            return
        }
        tracked = touch
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onMoved?(tracked, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onEnded?(tracked, event, false)
        self.tracked = nil
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onEnded?(tracked, event, true)
        self.tracked = nil
        state = .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}
