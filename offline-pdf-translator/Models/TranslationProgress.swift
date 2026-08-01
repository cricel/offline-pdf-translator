//
//  TranslationProgress.swift
//  offline-pdf-translator
//

import Foundation

enum TranslationStage: String, Equatable {
    case idle
    case preparing
    case translating
    case completed
    case failed

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .translating: return "Translating pages"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

struct TranslationEvent: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(_ message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.message = message
    }

    var timeLabel: String {
        timestamp.formatted(date: .omitted, time: .standard)
    }
}

@MainActor
@Observable
final class TranslationProgress {
    var stage: TranslationStage = .idle
    var detail: String = "Open a PDF, pick languages, translate (models download on first use)."
    var fraction: Double = 0
    var isIndeterminate = false
    var events: [TranslationEvent] = []
    var completedPages = 0
    var totalPages = 0

    var isActive: Bool {
        switch stage {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }

    var percentLabel: String {
        if isIndeterminate {
            return "…"
        }
        return "\(Int((fraction * 100).rounded()))%"
    }

    func resetForNewJob(totalPages: Int) {
        self.totalPages = totalPages
        completedPages = 0
        fraction = 0
        isIndeterminate = true
        events.removeAll()
        stage = .preparing
        detail = "Starting translation job…"
        log("Started translation for \(totalPages) page(s).")
    }

    func setStage(_ stage: TranslationStage, detail: String, indeterminate: Bool? = nil, fraction: Double? = nil) {
        self.stage = stage
        self.detail = detail
        if let indeterminate {
            isIndeterminate = indeterminate
        }
        if let fraction {
            self.fraction = min(max(fraction, 0), 1)
        }
        log(detail)
    }

    func updatePageProgress(completed: Int, total: Int, pageLabel: String) {
        completedPages = completed
        totalPages = total
        stage = .translating
        isIndeterminate = false
        let pageFraction = total > 0 ? Double(completed) / Double(total) : 0
        fraction = 0.10 + pageFraction * 0.90
        detail = pageLabel
        log(pageLabel)
    }

    func finishSuccess(_ message: String) {
        stage = .completed
        isIndeterminate = false
        fraction = 1
        detail = message
        log(message)
    }

    func finishFailure(_ message: String) {
        stage = .failed
        isIndeterminate = false
        detail = message
        log("Error: \(message)")
    }

    func log(_ message: String) {
        events.append(TranslationEvent(message))
        if events.count > 40 {
            events.removeFirst(events.count - 40)
        }
    }
}
