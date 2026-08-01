//
//  OfflinePDFTranslatorApp.swift
//  offline-pdf-translator
//

import SwiftUI

@main
struct OfflinePDFTranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
