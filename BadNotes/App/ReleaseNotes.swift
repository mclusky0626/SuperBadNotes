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
        AppRelease(version: "1.5.2.1", changes: [
            Change(icon: "clock.arrow.circlepath", title: "변경 기록과 업데이트 안내",
                   detail: "설정에서 이전 버전의 변경 기록을 확인하고, 업데이트 안내 자동 표시를 켜거나 끌 수 있어요.")
        ]),
        AppRelease(version: "1.5.2", changes: [
            Change(icon: "map", title: "화이트보드 미니맵",
                   detail: "보드 전체에서 지금 보는 위치를 확인하고 미니맵을 눌러 이동해요. 자주 찾는 위치는 이름을 붙여 노트에 저장할 수 있어요.")
        ]),
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
        ]),
        AppRelease(version: "1.3", changes: [
            Change(icon: "book.pages", title: "책처럼 넘기는 노트",
                   detail: "페이지를 책처럼 넘기고 가로 화면에서 두 쪽을 펼쳐 볼 수 있어요. 도구 막대와 글꼴, 유리 투명도도 개선했어요.")
        ]),
        AppRelease(version: "1.2", changes: [
            Change(icon: "text.bubble", title: "텍스트와 메모지, 사진",
                   detail: "페이지에 텍스트 상자와 유리 메모지, 사진을 넣을 수 있어요. Apple 필기 도구도 사용할 수 있어요."),
            Change(icon: "eraser", title: "지우개와 표지 개선",
                   detail: "지우개와 노트북 표지를 새롭게 정리했어요.")
        ]),
        AppRelease(version: "1.0", changes: [
            Change(icon: "pencil.and.scribble", title: "BadNotes 시작",
                   detail: "PDF에 필기하고 저장하는 BadNotes의 첫 버전이에요.")
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
        return AppSettings.shared.showUpdateNotes ? release : nil
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
