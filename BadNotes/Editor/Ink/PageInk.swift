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
    private var strokes: [PKStroke]
    private var drawing: PKDrawing?
    private var sampled: [SampledStroke]?
    private var cache: [StrokeKey: SampledStroke] = [:]
    /// 올가미로 옮기는 동안 타일에서 숨기는 획 번호
    private var hidden: Set<Int> = []
    /// 막 넣은 획: 타일이 실제로 다시 그린 영역을 기록해서, 화면 위 임시 획을 그 영역만큼 지움
    /// (임시 획과 타일 획이 겹쳐 진해지거나, 임시 획이 먼저 사라져 깜빡이는 걸 막음)
    private var pending: Set<StrokeKey> = []
    private var drawn: [StrokeKey: [(rect: CGRect, time: CFTimeInterval)]] = [:]

    init(drawing: PKDrawing) {
        strokes = drawing.strokes
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
        lock.withLock {
            if let drawing { return drawing }
            let result = PKDrawing(strokes: strokes)
            drawing = result
            return result
        }
    }

    /// drawing.strokes와 같은 순서
    func sampledStrokes() -> [SampledStroke] {
        lock.withLock { ensureSampled() }
    }

    /// 지우개는 마스크만 바꾼다. 펜촉·흑연 입자·보간점은 그대로 쓰고, 타일에는 한 번에 반영한다.
    func erase(_ sweep: StrokeEditing.Sweep, partial: Bool, highlightersOnly: Bool) -> CGRect {
        let (samples, source) = lock.withLock { (ensureSampled(), strokes) }
        let candidates = samples.indices.filter { samples[$0].bounds.intersects(sweep.bounds) }
        guard !candidates.isEmpty else { return .null }
        var dirty = CGRect.null
        var removed = IndexSet()
        var edits: [(index: Int, stroke: PKStroke, sample: SampledStroke)] = []
        for index in candidates {
            let s = samples[index], stroke = source[index]
            if highlightersOnly && !StrokeEditing.isHighlighter(stroke) { continue }
            if partial {
                guard let cut = StrokeEditing.erase(stroke, sampled: s, sweep: sweep) else { continue }
                if let masked = cut.first {
                    var changed = s
                    changed.key = StrokeKey(masked)
                    changed.mask = masked.mask?.cgPath
                    changed.maskSpace = .path
                    if s.appleSource != nil { changed.appleSource = masked }
                    edits.append((index, masked, changed))
                    let padding = max(4 * s.widthScale, sweep.radius * 2 + s.widthScale)
                    dirty = dirty.union(s.bounds.intersection(sweep.bounds.insetBy(dx: -padding, dy: -padding)))
                    continue
                }
            } else if !StrokeEditing.touches(s, sweep: sweep) { continue }
            removed.insert(index)
            dirty = dirty.union(s.bounds)
        }
        guard !edits.isEmpty || !removed.isEmpty else { return .null }
        // 타일은 한 번에 갱신하고, 저장·실행 취소에 필요한 PKDrawing은 손을 뗐을 때 만든다.
        lock.withLock {
            for index in edits.map(\.index) + Array(removed) {
                let old = samples[index].key
                cache[old] = nil
                pending.remove(old)
                drawn[old] = nil
            }
            for edit in edits {
                strokes[edit.index] = edit.stroke
                sampled?[edit.index] = edit.sample
                cache[edit.sample.key] = edit.sample
            }
            if !removed.isEmpty {
                let ranges = RangeSet(removed.rangeView)
                strokes.removeSubranges(ranges)
                sampled?.removeSubranges(ranges)
            }
            drawing = nil
        }
        return dirty
    }

    /// 새 필기로 바꾸고 다시 그려야 할 영역을 돌려줌. 숨긴 획도 다시 보이게 함
    @discardableResult
    func replace(with new: PKDrawing) -> CGRect {
        let newStrokes = new.strokes
        return lock.withLock {
            let old = ensureSampled()
            let wasHidden = hidden
            var nextCache: [StrokeKey: SampledStroke] = [:]
            var next: [SampledStroke] = []
            next.reserveCapacity(newStrokes.count)
            for stroke in newStrokes {
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

            strokes = newStrokes
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
        result.reserveCapacity(strokes.count)
        for stroke in strokes {
            let key = StrokeKey(stroke)
            let s = cache[key] ?? InkRenderer.sample(stroke, key: key)
            cache[key] = s
            result.append(s)
        }
        sampled = result
        return result
    }
}
