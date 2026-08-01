//
//  TranslatorViewModel.swift
//  offline-pdf-translator
//

import Foundation
import PDFKit
import SwiftUI

@MainActor
@Observable
final class TranslatorViewModel {
    var languages: [AppLanguage] = []
    var pairs: [TranslationPairInfo] = []
    var sourceLanguage: AppLanguage?
    var targetLanguage: AppLanguage?

    var isLoadingLanguages = false
    var sourceDocument: PDFDocument?
    var translatedDocument: PDFDocument?
    var sourceFileName: String?
    var sourceRevision = 0
    var translatedRevision = 0
    var isTranslating = false
    var errorMessage: String?
    var scrollFraction: CGFloat = 0
    var progress = TranslationProgress()
    var isActivityExpanded = true

    var languagePairLabel: String {
        "\(sourceDisplayName) → \(targetDisplayName)"
    }

    var sourceDisplayName: String {
        sourceLanguage?.displayName ?? "—"
    }

    var targetDisplayName: String {
        targetLanguage?.displayName ?? "—"
    }

    var sourceCode: String {
        sourceLanguage?.code ?? "en"
    }

    var targetCode: String {
        targetLanguage?.code ?? "zh"
    }

    /// Targets that have a catalog model from the current source language.
    var availableTargetLanguages: [AppLanguage] {
        guard let sourceLanguage else { return languages }
        let targets = Set(pairs.filter { $0.from == sourceLanguage.code }.map(\.to))
        return languages.filter { targets.contains($0.code) }
    }

    var selectedPair: TranslationPairInfo? {
        pairs.first { $0.from == sourceCode && $0.to == targetCode }
    }

    var translateHelp: String {
        if let pair = selectedPair {
            if pair.installed {
                return "Translate offline with the installed \(pair.label) model"
            }
            return "First use downloads \(pair.label) (~\(pair.approxMB) MB), then works offline"
        }
        return "Choose a supported language pair"
    }

    var canTranslate: Bool {
        sourceDocument != nil
            && !isTranslating
            && sourceLanguage != nil
            && targetLanguage != nil
            && sourceLanguage?.code != targetLanguage?.code
            && selectedPair != nil
    }

    var canSave: Bool {
        translatedDocument != nil && !isTranslating
    }

    func loadSupportedLanguages() async {
        isLoadingLanguages = true
        defer { isLoadingLanguages = false }

        do {
            let service = OfflineTranslationService.shared
            try await service.bootstrap { [weak self] message in
                Task { @MainActor in
                    self?.progress.log(message)
                }
            }
            let catalog = try await service.listCatalog { [weak self] message in
                Task { @MainActor in
                    self?.progress.log(message)
                }
            }
            languages = catalog.languages
            pairs = catalog.pairs
            progress.log("Catalog: \(pairs.count) language pair(s). Models download on first use.")
        } catch {
            languages = []
            pairs = []
            progress.log("Could not load language catalog: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return
        }

        sourceLanguage = languages.first { $0.code == "en" } ?? languages.first
        reconcileTargetLanguage()
        if let pair = selectedPair {
            let state = pair.installed ? "installed" : "will download (~\(pair.approxMB) MB)"
            progress.log("Ready — \(languagePairLabel) (\(state)).")
        } else {
            progress.log("Ready — pick a supported language pair.")
        }
    }

    func sourceLanguageChanged(to newValue: AppLanguage?) {
        sourceLanguage = newValue
        reconcileTargetLanguage()
    }

    func targetLanguageChanged(to newValue: AppLanguage?) {
        targetLanguage = newValue
    }

    func importPDF(from url: URL) {
        do {
            let document = try PDFService.loadDocument(from: url)
            sourceDocument = document
            translatedDocument = nil
            sourceRevision += 1
            translatedRevision += 1
            sourceFileName = url.lastPathComponent
            scrollFraction = 0
            errorMessage = nil
            progress.stage = .idle
            progress.isIndeterminate = false
            progress.fraction = 0
            progress.detail = "Loaded \(document.pageCount) page(s). Ready to translate."
            progress.log("Opened “\(url.lastPathComponent)” (\(document.pageCount) page(s)).")
        } catch {
            errorMessage = error.localizedDescription
            progress.finishFailure(error.localizedDescription)
        }
    }

    func requestTranslation() {
        guard canTranslate else { return }
        errorMessage = nil
        isTranslating = true
        isActivityExpanded = true
        let pageCount = sourceDocument?.pageCount ?? 0
        progress.resetForNewJob(totalPages: pageCount)
        if let pair = selectedPair, !pair.installed {
            progress.log("Will download \(pair.label) (~\(pair.approxMB) MB) before translating.")
        }
        progress.log("Translate — \(languagePairLabel)")
        Task { await performTranslation() }
    }

    func suggestedExportName() -> String {
        let base = sourceFileName?
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            ?? "translated"
        return "\(base)-\(targetCode).pdf"
    }

    // MARK: - Pipeline

    private func reconcileTargetLanguage() {
        let options = availableTargetLanguages
        if let targetLanguage, options.contains(where: { $0.code == targetLanguage.code }) {
            return
        }
        targetLanguage = options.first { $0.code == "zh" }
            ?? options.first { $0.code != sourceLanguage?.code }
            ?? options.first
    }

    private func performTranslation() async {
        do {
            let service = OfflineTranslationService.shared
            try await service.bootstrap { [weak self] message in
                Task { @MainActor in
                    self?.progress.log(message)
                    self?.progress.detail = message
                    self?.progress.isIndeterminate = true
                }
            }

            try await service.prepare(from: sourceCode, to: targetCode) { [weak self] message in
                Task { @MainActor in
                    self?.progress.setStage(.preparing, detail: message, indeterminate: true)
                }
            }

            // Refresh installed badges after download.
            if let catalog = try? await service.listCatalog() {
                pairs = catalog.pairs
            }

            try await rewritePages(using: service)
        } catch {
            isTranslating = false
            let message = error.localizedDescription
            errorMessage = message
            progress.finishFailure(message)
        }
    }

    private func rewritePages(using service: OfflineTranslationService) async throws {
        guard let sourceDocument else {
            throw PDFServiceError.unableToOpen
        }

        let pageCount = sourceDocument.pageCount
        guard pageCount > 0 else {
            throw PDFServiceError.emptyDocument
        }

        progress.setStage(
            .translating,
            detail: "Starting page rewrite…",
            indeterminate: false,
            fraction: 0.10
        )
        progress.log("Rewriting pages with PyMuPDF.")

        guard let sourceData = sourceDocument.dataRepresentation() else {
            throw PDFServiceError.unableToCreateOutput
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-pdf-translator-source-\(UUID().uuidString).pdf")
        try sourceData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workingDocument = try PDFService.document(from: sourceData)
        translatedDocument = workingDocument
        translatedRevision += 1

        let from = sourceCode
        let to = targetCode

        for pageIndex in 0..<pageCount {
            let pageNumber = pageIndex + 1
            progress.updatePageProgress(
                completed: pageIndex,
                total: pageCount,
                pageLabel: "Translating page \(pageNumber) of \(pageCount)…"
            )

            let pageData = try await service.translatePage(
                pdfPath: tempURL.path,
                pageIndex: pageIndex,
                from: from,
                to: to
            )

            guard let page = PDFDocument(data: pageData)?.page(at: 0) else {
                throw PDFServiceError.unableToCreateOutput
            }

            PDFService.replacePage(in: workingDocument, at: pageIndex, with: page)
            translatedDocument = workingDocument
            translatedRevision += 1
            progress.log("Preview updated for page \(pageNumber).")

            progress.updatePageProgress(
                completed: pageNumber,
                total: pageCount,
                pageLabel: "Page \(pageNumber) of \(pageCount) translated."
            )
        }

        isTranslating = false
        progress.finishSuccess("Done — \(pageCount) page(s) translated. You can save the result.")
    }
}
