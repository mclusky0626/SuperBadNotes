//
//  SettingsView.swift
//  BadNotes
//
//  설정: 필기 방식(직접 필기 / 레이어), 입력, 테마 바로가기, 정보.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let openTheme: () -> Void
    let openLog: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AppSettings.EditMode.allCases) { mode in
                        Button {
                            settings.editMode = mode
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: settings.editMode == mode ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(settings.editMode == mode ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mode.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(mode.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("필기 방식")
                }

                Section {
                    Toggle("손가락으로도 쓰기", isOn: $settings.fingerDrawing)
                    Toggle("두 손가락 탭으로 실행 취소", isOn: $settings.tapToUndo)
                    Toggle("형광펜 곧게 긋기", isOn: $settings.straightHighlighter)
                } header: {
                    Text("입력")
                } footer: {
                    Text("손가락으로 쓰기를 켜면 스크롤과 확대는 두 손가락으로 해요. 세 손가락 탭은 다시 실행이에요. 형광펜 곧게 긋기를 켜면 거의 곧은 형광펜 줄을 곧게 펴 주고, 수평에 가까우면 수평으로 맞춰요. Apple Pencil 두 번 탭은 시스템 설정을 따라 지우개로 바꿔요.")
                }

                Section {
                    Toggle("책처럼 넘기기", isOn: $settings.pageTurn)
                    Toggle("가로 화면에서 두 쪽 펼치기", isOn: $settings.twoUpLandscape)
                } header: {
                    Text("페이지 보기")
                } footer: {
                    Text("책처럼 넘기기를 켜면 한 장씩 보이고, 옆으로 쓸거나 아래 ‹ › 를 누르면 종이를 넘기듯 넘어가요. 끄면 세로로 이어서 스크롤해요. 가로 화면에서는 두 쪽이 양옆으로 펼쳐져요. (책처럼 넘기기는 BadNotes 필기 도구에서만)")
                }

                Section {
                    Picker("새 문서 형식", selection: $settings.newFormat) {
                        ForEach(NoteFormat.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("파일 형식")
                } footer: {
                    Text(settings.newFormat.detail + " 새 노트북을 만들 때마다 따로 고를 수도 있어요. 화이트보드는 이 형식으로 만들어요.")
                }

                Section("모양") {
                    Button("테마 바꾸기…", action: openTheme)
                }

                Section("정보") {
                    LabeledContent("버전", value: AppRelease.installedVersion ?? "–")
                    NavigationLink("변경 기록") { ReleaseNotesView() }
                    Toggle("업데이트 안내 자동 표시", isOn: $settings.showUpdateNotes)
                    LabeledContent("PDF 위치", value: "파일 › 나의 iPad › BadNotes")
                    Button("로그 보기", action: openLog)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
