//
//  ContentView.swift
//  offline-pdf-translator
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = TranslatorViewModel()
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var exportDocument: PDFFileDocument?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            toolbar
            Divider()
            panes
            Divider()
            ActivityPanel(progress: model.progress, isExpanded: $model.isActivityExpanded)
        }
        .frame(minWidth: 960, minHeight: 640)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.importPDF(from: url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .pdf,
            defaultFilename: model.suggestedExportName()
        ) { result in
            switch result {
            case .success(let url):
                model.progress.detail = "Saved to \(url.lastPathComponent)"
                model.progress.log("Saved translated PDF to \(url.lastPathComponent).")
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        .task {
            await model.loadSupportedLanguages()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            languagePickers

            Spacer(minLength: 0)

            Button {
                isImporterPresented = true
            } label: {
                Label("Open PDF", systemImage: "doc.badge.plus")
            }
            .disabled(model.isTranslating)

            Button {
                model.requestTranslation()
            } label: {
                if model.isTranslating {
                    Label("Translating…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Translate", systemImage: "globe")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canTranslate)
            .help(model.translateHelp)

            Button {
                presentExporter()
            } label: {
                Label("Save Translated PDF", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var languagePickers: some View {
        HStack(spacing: 8) {
            if model.isLoadingLanguages {
                ProgressView()
                    .controlSize(.small)
                Text("Loading languages…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("From", selection: sourceSelection) {
                    ForEach(model.languages) { language in
                        Text(language.displayName).tag(Optional(language))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 170)
                .disabled(model.isTranslating)

                Text("→")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Picker("To", selection: targetSelection) {
                    ForEach(model.availableTargetLanguages) { language in
                        Text(targetLabel(for: language)).tag(Optional(language))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 140, maxWidth: 200)
                .disabled(model.isTranslating || model.availableTargetLanguages.isEmpty)
            }
        }
    }

    private func targetLabel(for language: AppLanguage) -> String {
        guard let pair = model.pairs.first(where: {
            $0.from == model.sourceCode && $0.to == language.code
        }) else {
            return language.displayName
        }
        return pair.installed ? language.displayName : "\(language.displayName) ↓"
    }

    private var sourceSelection: Binding<AppLanguage?> {
        Binding(
            get: { model.sourceLanguage },
            set: { model.sourceLanguageChanged(to: $0) }
        )
    }

    private var targetSelection: Binding<AppLanguage?> {
        Binding(
            get: { model.targetLanguage },
            set: { model.targetLanguageChanged(to: $0) }
        )
    }

    private var panes: some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            pane(
                title: "Original",
                subtitle: model.sourceFileName ?? "No file selected",
                document: model.sourceDocument,
                revision: model.sourceRevision,
                scrollFraction: $model.scrollFraction,
                emptyMessage: "Open a PDF to preview it here."
            )

            Divider()

            pane(
                title: "Translated",
                subtitle: model.targetDisplayName,
                document: model.translatedDocument,
                revision: model.translatedRevision,
                scrollFraction: $model.scrollFraction,
                emptyMessage: model.sourceDocument == nil
                    ? "Translated PDF will appear here."
                    : "Click Translate to generate the translated PDF."
            )
        }
    }

    private func pane(
        title: String,
        subtitle: String,
        document: PDFDocument?,
        revision: Int,
        scrollFraction: Binding<CGFloat>,
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            SyncedPDFView(
                document: document,
                revision: revision,
                scrollFraction: scrollFraction,
                emptyMessage: emptyMessage
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presentExporter() {
        guard let document = model.translatedDocument,
              let data = document.dataRepresentation() else { return }
        exportDocument = PDFFileDocument(data: data)
        isExporterPresented = true
    }
}

struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    ContentView()
}
