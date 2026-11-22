//
//  GlassControls.swift
//  BadNotes
//
//  테마 유리를 입힌 공통 부품.
//

import SwiftUI

/// 동그란 유리 아이콘 버튼. 선택되면 강조색 유리
struct GlassIconButton: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.isEnabled) private var isEnabled

    let systemImage: String
    let label: String
    var selected = false
    var tint: Color?
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(selected ? Color.white : (tint ?? Color.primary))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? Glass.regular.tint(themes.accent).interactive() : themes.glass.interactive(), in: .circle)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// 문서 표지. 썸네일이 있으면 그 비율대로(가로 문서는 가로로), 없으면 색으로 채움.
/// 책: 왼쪽 책등 그림자 + 그림자 / 유리: 유리판 위에 얹은 모양
struct CoverFrame<Badge: View>: View {
    @Environment(ThemeStore.self) private var themes

    let image: UIImage?
    let placeholder: [Color]
    let style: Theme.CardStyle
    /// 표지가 들어갈 최대 크기
    let box: CGSize
    /// 표지 오른쪽 위 모서리에 얹는 것 (즐겨찾기 별)
    let badge: Badge

    init(image: UIImage?, placeholder: [Color], style: Theme.CardStyle, box: CGSize, @ViewBuilder badge: () -> Badge) {
        self.image = image
        self.placeholder = placeholder
        self.style = style
        self.box = box
        self.badge = badge()
    }

    private var faceSize: CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return box }
        let scale = min(box.width / image.size.width, box.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    var body: some View {
        Group {
            switch style {
            case .book: book.overlay(alignment: .topTrailing) { badge }
            case .glass: glassCard.overlay(alignment: .topTrailing) { badge.padding(6) }
            }
        }
        .frame(width: box.width, height: box.height, alignment: .bottom)
    }

    private var face: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: placeholder, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: faceSize.width, height: faceSize.height)
        .clipped()
    }

    private var book: some View {
        face
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                              bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous))
            .overlay(alignment: .leading) {
                // 책등
                LinearGradient(colors: [.black.opacity(0.22), .white.opacity(0.18), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 9)
            }
            .overlay {
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                       bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 7, y: 4)
    }

    private var glassCard: some View {
        face
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(9)
            .glassEffect(themes.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension CoverFrame where Badge == EmptyView {
    init(image: UIImage?, placeholder: [Color], style: Theme.CardStyle, box: CGSize) {
        self.init(image: image, placeholder: placeholder, style: style, box: box) { EmptyView() }
    }
}
