//
//  BadNotesApp.swift
//  BadNotes
//
//  Created by 제비 on 11/22/26.
//

import SwiftUI

@main
struct BadNotesApp: App {
    @State private var themes = ThemeStore.shared

    init() {
        #if DEBUG
        if SelfTest.isRequested {
            Task.detached(priority: .userInitiated) { await SelfTest.run() }
            return
        }
        #endif
        LegacyMigration.start()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if SelfTest.isRequested {
                Text("저장 엔진 자체 점검 중 (콘솔 확인)")
            } else {
                RootView().environment(themes)
            }
            #else
            RootView().environment(themes)
            #endif
        }
    }
}

/// 테마 배경을 맨 뒤에 깔고, 강조색·화면 모드를 앱 전체에 적용
struct RootView: View {
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        ContentView()
            .background {
                ThemeBackground(theme: themes.theme, photo: themes.photo)
            }
            .tint(themes.accent)
            .preferredColorScheme(themes.colorScheme)
    }
}
