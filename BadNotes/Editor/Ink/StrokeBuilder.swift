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
    /// 필압에 따라 굵기가 몇 배까지 변하는지 (볼펜 1...1, 만년필 0.7...1.3, 붓펜 0.3...1.6)
    let pressureRange: ClosedRange<CGFloat>
    let startTime: TimeInterval
    private let creationDate = Date()
    private(set) var points: [PKStrokePoint] = []
    private var pressure: CGFloat = 0.5
    private var lastLocation: CGPoint?

    init(inkType: PKInk.InkType, color: UIColor, width: CGFloat,
         pressureRange: ClosedRange<CGFloat> = 1...1, startTime: TimeInterval) {
        self.inkType = inkType
        self.color = color
        self.width = width
        self.pressureRange = pressureRange
        self.startTime = startTime
    }

    /// 펜슬 힘(0~1) → 쓰기 압력. 보통 필압이 0.2~0.4 정도라 곡선으로 펴 줌
    static func pressure(fromForce normalized: CGFloat) -> CGFloat {
        min(1, pow(max(0, normalized) * 1.5, 0.75))
    }

    mutating func add(_ sample: InputSample) {
        if let last = lastLocation, hypot(sample.location.x - last.x, sample.location.y - last.y) < 0.2 {
            return
        }
        let raw = sample.force.map(Self.pressure(fromForce:)) ?? 0.5
        // 압력이 들쭉날쭉하면 굵기가 울퉁불퉁해서 살짝 부드럽게
        pressure = points.isEmpty ? raw : pressure + (raw - pressure) * 0.35
        points.append(point(for: sample, pressure: pressure))
        lastLocation = sample.location
    }

    /// predicted: 아직 안 온 터치 예측값. 화면에 미리 그려서 지연을 숨김 (저장하지는 않음)
    func makeStroke(predicted: [InputSample] = [], seed: UInt32 = UInt32.random(in: 1...UInt32.max)) -> PKStroke? {
        var all = points
        var p = pressure
        for sample in predicted {
            let raw = sample.force.map(Self.pressure(fromForce:)) ?? 0.5
            p += (raw - p) * 0.35
            all.append(point(for: sample, pressure: p))
        }
        guard let first = all.first else { return nil }
        if all.count == 1 { all.append(first) }  // 콕 찍은 점
        let path = PKStrokePath(controlPoints: all, creationDate: creationDate)
        return PKStroke(ink: PKInk(inkType, color: color), path: path, transform: .identity, mask: nil, randomSeed: seed)
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
        if inkType == .pencil {
            // 연필은 눕히면 굵어지고, 세게 누르면 진해짐
            visible = width * (1 + 1.5 * tilt)
            opacity = 0.35 + 0.6 * pressure
        }
        // PencilKit은 점 크기를 그대로 굵기로 쓰지 않아서 (펜은 2 × (크기 − 2)) 거꾸로 환산해서 저장
        let size = InkRenderer.pencilKitSize(forWidth: visible, inkType)
        return PKStrokePoint(location: sample.location,
                             timeOffset: max(0, sample.time - startTime),
                             size: CGSize(width: size, height: size),
                             opacity: opacity,
                             force: pressure * 4,
                             azimuth: sample.azimuth,
                             altitude: sample.altitude,
                             secondaryScale: 1)
    }
}
