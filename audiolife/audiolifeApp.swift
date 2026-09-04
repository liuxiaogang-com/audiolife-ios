//
//  audiolifeApp.swift
//  audiolife
//
//  Created by xiao on 2026/8/29.
//

import AppIntents
import SwiftData
import SwiftUI

@main
struct audiolifeApp: App {
    @State private var router = AppRouter.shared

    init() {
        DiagnosticLogger.log("AudioLife application initialized")
        AppModelStore.migrateLegacyContentIfNeeded()
        AudioLifeShortcuts.updateAppShortcutParameters()
        _ = RecordingSessionManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(router)
                .onOpenURL { url in
                    router.handle(url: url)
                }
        }
        .modelContainer(AppModelStore.container)
    }
}
