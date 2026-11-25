//
//  StrokeBuilder.swift
//  BadNotes
//
//  Apple Pencil(또는 손가락) 입력 → PKStroke.
//  데이터는 PencilKit 형식 그대로라서 레이어 모드(PencilKit)에서도 같은 필기를 보고 고칠 수 있음.
//

import PencilKit
import UIKit

/// 터치 한 번에서 뽑은 값 (페이지 캔버스 좌표)
nonisolated struct InputSample: Sendable {
    var location: CGPoint
    var time: TimeInterval
    /// 0~1. 손가락이면 nil (압력 없음 → 중간값으로)
    var force: CGFloat?
    var azimuth: CGFloat
    var altitude: CGFloat
}

nonisolated struct StrokeBuilder {
    let inkType: PKInk.InkType
    let color: UIColor
    /// 화면에 보이는 굵기 (pt)
    let width: CGFloat
    /// 필압에 따라 굵기가 몇 배까지 변하는지
    let pressureRange: ClosedRange<CGFloat>
    let startTime: TimeInterval
    private let creationDate = Date()
    private(set) var points: [PKStrokePoint] = []
    private var pressure: CGFloat = 0.5
    private let seed: UInt32
    private let profile: BrushProfile?
    private var distance: CGFloat = 0
    private var speed: CGFloat = 0

    init(inkType: PKInk.InkType, color: UIColor, width: CGFloat,
         pressureRange: ClosedRange<CGFloat> = 1...1, startTime: TimeInterval, seed: UInt32 = InkOrigin.badNotesSeed()) {
        self.inkType = inkType
        self.color = color
        self.width = width
        self.pressureRange = pressureRange
        self.startTime = startTime
        self.seed = seed
        self.profile = BrushProfile(seed: seed)
    }

    /// 펜슬 힘(0~1) → 쓰기 압력. 보통 필압이 0.2~0.4 정도라 곡선으로 펴 줌
    static func pressure(fromForce normalized: CGFloat) -> CGFloat {
        min(1, pow(max(0, normalized) * 1.5, 0.75))
    }

    mutating func add(_ sample: InputSample) {
        if let last = points.last {
            let step = hypot(sample.location.x - last.location.x, sample.location.y - last.location.y)
            guard step >= 0.2 else { return }
            distance += step
            let elapsed = sample.time - startTime - last.timeOffset
            if elapsed > 0 {
                let measured = min(1, step / CGFloat(elapsed) / 1_200)
                speed += (measured - speed) * 0.35
            }
        }
        let raw = sample.force.map(Self.pressure(fromForce:)) ?? 0.5
        // 압력이 들쭉날쭉하면 굵기가 울퉁불퉁해서 살짝 부드럽게
        pressure = points.isEmpty ? raw : pressure + (raw - pressure) * 0.35
        points.append(point(for: sample, pressure: pressure))
    }

    /// predicted: 아직 안 온 터치 예측값. 화면에 미리 그려서 지연을 숨김 (저장하지는 않음)
    func makeStroke(predicted: [InputSample] = [], seed override: UInt32? = nil) -> PKStroke? {
        // 예측점에도 실제 입력과 같은 속도·필압 필터를 적용하고, 원본 상태는 건드리지 않음.
        var preview = self
        for sample in predicted { preview.add(sample) }
        guard let first = preview.points.first else { return nil }
        var all = preview.points
        if all.count == 1 { all.append(first) }
        if profile == .brush, all.count >= 4 {
            let length = min(width * 2.2, preview.distance * 0.3)
            taper(&all, from: 0, step: 1, length: length)
            taper(&all, from: all.count - 1, step: -1, length: length)
        }
        let path = PKStrokePath(controlPoints: all, creationDate: creationDate)
        return PKStroke(ink: PKInk(inkType, color: color), path: path, transform: .identity, mask: nil,
                        randomSeed: override ?? seed)
    }

    private func taper(_ points: inout [PKStrokePoint], from start: Int, step: Int, length: CGFloat) {
        var index = start
        var travel: CGFloat = 0
        while points.indices.contains(index), travel < length {
            let point = points[index]
            let width = InkRenderer.renderWidth(point, .pen, direction: 0) * (0.2 + 0.8 * travel / length)
            let size = InkRenderer.pencilKitSize(forWidth: width, .pen)
            points[index] = PKStrokePoint(location: point.location, timeOffset: point.timeOffset,
                                          size: CGSize(width: size, height: size), opacity: point.opacity,
                                          force: point.force, azimuth: point.azimuth, altitude: point.altitude,
                                          secondaryScale: point.secondaryScale)
            index += step
            if points.indices.contains(index) {
                travel += hypot(points[index].location.x - point.location.x, points[index].location.y - point.location.y)
            }
        }
    }

    /// 거의 곧게 그은 획이면 곧은 선으로 편 것 (형광펜으로 글줄 칠할 때). 수평에서 3° 안이면 수평으로.
    /// 곧지 않으면 nil
    func straightened() -> StrokeBuilder? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let a = first.location, b = last.location
        let dx = b.x - a.x, dy = b.y - a.y
        let chord = hypot(dx, dy)
        guard chord >= 24 else { return nil }

        var pathLength: CGFloat = 0
        for (p, q) in zip(points, points.dropFirst()) {
            pathLength += hypot(q.location.x - p.location.x, q.location.y - p.location.y)
        }
        var deviation: CGFloat = 0
        for p in points {
            let d = abs(dy * p.location.x - dx * p.location.y + b.x * a.y - b.y * a.x) / chord
            deviation = max(deviation, d)
        }
        guard pathLength <= chord * 1.12, deviation <= max(4, chord * 0.06) else { return nil }

        var end = b
        if abs(dy) / chord < sin(3 * .pi / 180) { end.y = a.y }
        let length = hypot(end.x - a.x, end.y - a.y)
        let count = max(2, Int(length / 2))
        let middle = points[points.count / 2]
        var copy = self
        copy.points = (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            return PKStrokePoint(location: CGPoint(x: a.x + (end.x - a.x) * t, y: a.y + (end.y - a.y) * t),
                                 timeOffset: first.timeOffset + (last.timeOffset - first.timeOffset) * Double(t),
                                 size: middle.size, opacity: middle.opacity, force: middle.force,
                                 azimuth: middle.azimuth, altitude: middle.altitude,
                                 secondaryScale: middle.secondaryScale)
        }
        return copy
    }

    private func point(for sample: InputSample, pressure: CGFloat) -> PKStrokePoint {
        // 0 = 펜슬을 세움, 1 = 눕힘
        let tilt = 1 - min(1, max(0, sample.altitude / (.pi / 2)))
        let low = pressureRange.lowerBound, high = pressureRange.upperBound
        var visible = width * (low + (high - low) * pressure)
        var opacity: CGFloat = 1
        var azimuth = sample.azimuth
        if profile == .brush {
            visible *= 1.15 - 0.55 * speed
        } else if profile == .fountain {
            // 수직에 가까우면 안정된 사선 펜촉, 눕히면 Pencil의 방위각을 따름.
            let base = CGFloat.pi * 0.75
            let delta = sample.azimuth - base
            let rotation = atan2(sin(2 * delta), cos(2 * delta)) * 0.5
            azimuth = base + rotation * min(1, tilt * 3)
        } else if inkType == .pencil {
            // 연필은 눕히면 굵어지고, 세게 누르면 진해짐
            visible = width * (0.75 + pressure * 0.5 + 2.5 * tilt)
            opacity = 0.16 + 0.8 * pressure
        }
        // PencilKit은 점 크기를 그대로 굵기로 쓰지 않아서 (펜은 2 × (크기 − 2)) 거꾸로 환산해서 저장
        let size = InkRenderer.pencilKitSize(forWidth: visible, inkType)
        return PKStrokePoint(location: sample.location,
                             timeOffset: max(0, sample.time - startTime),
                             size: CGSize(width: size, height: size),
                             opacity: opacity,
                             force: pressure * 4,
                             azimuth: azimuth,
                             altitude: sample.altitude,
                             secondaryScale: 1)
    }
}
