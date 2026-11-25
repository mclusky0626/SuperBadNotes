import SwiftUI

struct AppRelease: Identifiable {
    struct Change {
        let icon: String
        let title: String
        let detail: String
    }

    let version: String
    let changes: [Change]
    var id: String { version }

    static let history = [
        AppRelease(version: "1.5.1", changes: [
            Change(icon: "eraser", title: "부분 지우개 반응 개선",
                   detail: "노트에서 문지른 자리만 지워져요. 유리펜도 지운 상태로 저장하고 다시 열 수 있어요."),
            Change(icon: "drop.halffull", title: "펜과 글자에 Liquid Glass 적용",
                   detail: "유리펜의 곡선과 글자 획을 따라 iPadOS의 유리 재질이 적용돼요. 사진이나 필기 위에서 배경이 굴절되는 모습을 볼 수 있어요.")
        ]),
        AppRelease(version: "1.5", changes: [
            Change(icon: "book.pages", title: "화면 반씩 쓰는 가로 노트",
                   detail: "책등이 화면 한가운데에 오도록 두 쪽을 펼쳐요. 도구 막대 주변 여백도 줄여서 더 넓게 쓸 수 있어요."),
            Change(icon: "book", title: "자연스럽게 넘어가는 표지",
                   detail: "표지를 열면 첫 속지가 표지 뒷면을 따라 왼쪽에 내려앉아요. 표지를 닫을 때도 같은 순서로 돌아가요."),
            Change(icon: "pencil.and.scribble", title: "펜마다 다른 획",
                   detail: "볼펜은 고른 선을, 만년필은 펜촉 방향에 따라 굵기가 달라지는 선을 그려요. 붓펜은 필압에 반응하고, 연필은 눕혀서 질감 있는 면을 칠할 수 있어요.")
        ]),
        AppRelease(version: "1.4", changes: [
            Change(icon: "book", title: "종이처럼 말아 넘기기",
                   detail: "모서리를 끌어 페이지를 넘겨요. 가로에서는 표지가 오른쪽, 마지막에 홀로 남은 속지가 왼쪽에 놓여요."),
            Change(icon: "arrow.up.left.and.arrow.down.right", title: "확대 고정과 화이트보드 확장",
                   detail: "페이지를 넘겨도 선택한 배율을 유지할 수 있어요. 화이트보드 가장자리에서 쓰면 작업 공간이 늘어나요.")
        ])
    ]

    static var installedVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 여러 창을 열어도 새 버전 안내는 한 창에서만 표시한다.
    static func takeUnseenRelease() -> AppRelease? {
        let defaults = UserDefaults.standard
        let key = "lastPresentedReleaseVersion"
        guard let release = history.first(where: { $0.version == installedVersion }),
              release.version.compare(defaults.string(forKey: key) ?? "", options: .numeric) == .orderedDescending
        else { return nil }
        defaults.set(release.version, forKey: key)
        return release
    }
}

struct ReleaseNotesView: View {
    var release: AppRelease?

    var body: some View {
        List {
            ForEach(release.map { [$0] } ?? AppRelease.history) { entry in
                Section("BadNotes \(entry.version)") {
                    ForEach(entry.changes, id: \.title) { change in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: change.icon)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(change.title).font(.headline)
                                Text(change.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle(release == nil ? "변경 기록" : "이번 업데이트")
    }
}
