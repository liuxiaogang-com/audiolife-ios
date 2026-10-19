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
        guard case .success = AppModelStore.loadResult else { return }
        AppModelStore.migrateLegacyContentIfNeeded()
        AudioLifeShortcuts.updateAppShortcutParameters()
        _ = RecordingSessionManager.shared
    }

    var body: some Scene {
        WindowGroup {
            if case .success(let container) = AppModelStore.loadResult {
            ContentView()
                .environment(router)
                .onOpenURL { url in
                    router.handle(url: url)
                }
                .modelContainer(container)
            } else if case .failure(let error) = AppModelStore.loadResult {
                DataStoreRecoveryView(message: error.localizedDescription)
            }
        }
    }
}
