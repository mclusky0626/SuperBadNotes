//
//  BadNotesApp.swift
//  BadNotes
//
//  Created by 제비 on 11/22/26.
//

import SwiftUI

@main
struct BadNotesApp: App {
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
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
