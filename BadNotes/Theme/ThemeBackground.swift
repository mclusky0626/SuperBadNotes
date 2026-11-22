//
//  ThemeBackground.swift
//  BadNotes
//
//  앱 맨 뒤 = 바탕(내 사진 / 단색 / 그라데이션) + 그 위 Liquid Glass 한 겹.
//  사진이 유리 너머로 비쳐 보이고, 버튼·막대·카드가 그 위에 떠 있음.
//

import SwiftUI
import CoreMotion
import Observation

struct ThemeBackground: View {
    let theme: Theme
    let photo: UIImage?
    /// 미리보기 등에서 움직임을 끄고 싶을 때
    var allowMotion = true

    @State private var motion = MotionParallax.shared

    private var parallaxOn: Bool { allowMotion && theme.parallax }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                base
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(parallaxOn ? 1.08 : 1)
                    .offset(parallaxOn ? motion.offset : .zero)
                    .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.9), value: motion.offset)
                    .clipped()

                if theme.glassLayer {
                    // 바탕 전체를 덮는 유리 한 장
                    Color.clear
                        .glassEffect(theme.glass, in: Rectangle())
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { if parallaxOn { motion.start() } }
        .onDisappear { if parallaxOn { motion.stop() } }
        .onChange(of: parallaxOn) { _, on in
            if on { motion.start() } else { motion.stop() }
        }
    }

    @ViewBuilder
    private var base: some View {
        let colors = theme.baseColors
        switch theme.base {
        case .photo:
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: theme.photoBlur)
                    .overlay(Color.black.opacity(theme.photoDim))
            } else {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            }
        case .color:
            colors[0]
        case .gradient:
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// 기기 기울기 → 바탕 이동량. 켜 놓은 곳이 하나라도 있을 때만 센서를 씀
@Observable
final class MotionParallax {
    static let shared = MotionParallax()

    private(set) var offset: CGSize = .zero

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var reference: CMAttitude?

    func start() {
        users += 1
        guard users == 1, manager.isDeviceMotionAvailable else { return }
        reference = nil
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.update(motion) }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        manager.stopDeviceMotionUpdates()
        offset = .zero
    }

    /// 켰을 때 자세를 기준으로 얼마나 기울었는지
    private func update(_ motion: CMDeviceMotion) {
        guard let attitude = motion.attitude.copy() as? CMAttitude else { return }
        if reference == nil { reference = attitude.copy() as? CMAttitude }
        if let reference { attitude.multiply(byInverseOf: reference) }
        let limit: CGFloat = 24
        offset = CGSize(width: max(-limit, min(limit, CGFloat(attitude.roll) * 40)),
                        height: max(-limit, min(limit, CGFloat(attitude.pitch) * 40)))
    }
}
