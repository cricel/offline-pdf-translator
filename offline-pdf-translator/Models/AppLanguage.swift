//
//  AppLanguage.swift
//  offline-pdf-translator
//

import Foundation

struct AppLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }
    var displayName: String { name }
}
