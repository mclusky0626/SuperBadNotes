//
//  PageInk.swift
//  BadNotes
//
//  페이지 하나의 필기. 메인 스레드가 바꾸고, 타일을 그리는 백그라운드 스레드가 읽음.
//  획마다 샘플링 결과를 캐시해서, 획 하나를 더해도 그 획만 새로 계산함.
//

import PencilKit
import UIKit

nonisolated final class PageInk: @unchecked Sendable {
    private let lock = NSLock()
    private var drawing: PKDrawing
    private var sampled: [SampledStroke]?
    private var cache: [StrokeKey: SampledStroke] = [:]
    /// 올가미로 옮기는 동안 타일에서 숨기는 획 번호
    private var hidden: Set<Int> = []
    /// 막 넣은 획: 타일이 실제로 다시 그린 영역을 기록해서, 화면 위 임시 획을 그 영역만큼 지움
    /// (임시 획과 타일 획이 겹쳐 진해지거나, 임시 획이 먼저 사라져 깜빡이는 걸 막음)
    private var pending: Set<StrokeKey> = []
    private var drawn: [StrokeKey: [(rect: CGRect, time: CFTimeInterval)]] = [:]

    init(drawing: PKDrawing) {
        self.drawing = drawing
    }

    // MARK: 막 넣은 획 추적

    /// replace 전에 불러야 그 사이에 그려진 타일도 놓치지 않음
    func markPending(_ keys: [StrokeKey]) {
        lock.withLock {
            for key in keys {
                pending.insert(key)
                drawn[key] = []
            }
        }
    }

    func clearPending(_ key: StrokeKey) {
        lock.withLock {
            pending.remove(key)
            drawn[key] = nil
        }
    }

    /// 타일 그리기용: 그릴 획 + 아직 추적 중인 획
    func renderSnapshot() -> (strokes: [SampledStroke], pending: Set<StrokeKey>) {
        lock.withLock {
            let all = ensureSampled()
            let visible = hidden.isEmpty ? all : all.enumerated().filter { !hidden.contains($0.offset) }.map(\.element)
            return (visible, pending)
        }
    }

    func recordDrawn(_ rect: CGRect, keys: [StrokeKey]) {
        let now = CACurrentMediaTime()
        lock.withLock {
            for key in keys where pending.contains(key) {
                drawn[key, default: []].append((rect, now))
            }
        }
    }

    /// 타일이 새로 그린 영역. 그린 직후는 아직 화면에 안 올라갔을 수 있어서 0.05초 지난 것만
    func coveredRects(for key: StrokeKey) -> [CGRect] {
        let now = CACurrentMediaTime()
        return lock.withLock {
            (drawn[key] ?? []).filter { now - $0.time > 0.05 }.map(\.rect)
        }
    }

    /// 타일 그리기용. 처음 부르면 이때 샘플링 (첫 타일이 비용을 냄)
    func renderStrokes() -> [SampledStroke] {
        lock.withLock {
            let all = ensureSampled()
            guard !hidden.isEmpty else { return all }
            return all.enumerated().filter { !hidden.contains($0.offset) }.map(\.element)
        }
    }

    func currentDrawing() -> PKDrawing {
        lock.withLock { drawing }
    }

    /// drawing.strokes와 같은 순서
    func sampledStrokes() -> [SampledStroke] {
        lock.withLock { ensureSampled() }
    }

    /// 새 필기로 바꾸고 다시 그려야 할 영역을 돌려줌. 숨긴 획도 다시 보이게 함
    @discardableResult
    func replace(with new: PKDrawing) -> CGRect {
        lock.withLock {
            let old = ensureSampled()
            let wasHidden = hidden
            var nextCache: [StrokeKey: SampledStroke] = [:]
            var next: [SampledStroke] = []
            next.reserveCapacity(new.strokes.count)
            for stroke in new.strokes {
                let key = StrokeKey(stroke)
                let s = nextCache[key] ?? cache[key] ?? InkRenderer.sample(stroke, key: key)
                nextCache[key] = s
                next.append(s)
            }

            var dirty = CGRect.null
            let oldKeys = Set(old.map(\.key))
            let newKeys = Set(next.map(\.key))
            for s in old where !newKeys.contains(s.key) { dirty = dirty.union(s.bounds) }
            for s in next where !oldKeys.contains(s.key) { dirty = dirty.union(s.bounds) }
            for index in wasHidden where old.indices.contains(index) { dirty = dirty.union(old[index].bounds) }

            drawing = new
            sampled = next
            cache = nextCache
            hidden = []
            return dirty
        }
    }

    /// 올가미로 옮기는 동안 원래 자리의 획을 숨김. 다시 그려야 할 영역을 돌려줌
    func setHidden(_ indices: Set<Int>) -> CGRect {
        lock.withLock {
            let all = ensureSampled()
            var dirty = CGRect.null
            for index in hidden.symmetricDifference(indices) where all.indices.contains(index) {
                dirty = dirty.union(all[index].bounds)
            }
            hidden = indices
            return dirty
        }
    }

    private func ensureSampled() -> [SampledStroke] {
        if let sampled { return sampled }
        var result: [SampledStroke] = []
        result.reserveCapacity(drawing.strokes.count)
        for stroke in drawing.strokes {
            let key = StrokeKey(stroke)
            let s = cache[key] ?? InkRenderer.sample(stroke, key: key)
            cache[key] = s
            result.append(s)
        }
        sampled = result
        return result
    }
}
