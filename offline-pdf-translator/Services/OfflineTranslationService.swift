//
//  OfflineTranslationService.swift
//  offline-pdf-translator
//

import Foundation

struct TranslationPairInfo: Hashable, Identifiable {
    let from: String
    let to: String
    let approxMB: Int
    let installed: Bool

    var id: String { "\(from)-\(to)" }
    var label: String { "\(from)→\(to)" }
}

enum OfflineTranslationError: LocalizedError {
    case runtimeMissing
    case bridgeFailed(String)
    case notReady
    case invalidResponse
    case unsupportedPair(String, String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return "Bundled translator runtime is missing. Run Tools/build_translator_runtime.sh, then rebuild the app."
        case .bridgeFailed(let message):
            return message
        case .notReady:
            return "Offline translator is not ready yet."
        case .invalidResponse:
            return "Translator bridge returned an invalid response."
        case .unsupportedPair(let from, let to):
            return "No downloadable model for \(from)→\(to)."
        }
    }
}

/// Speaks JSON-lines to the bundled CTranslate2 + PyMuPDF runtime inside the app package.
actor OfflineTranslationService {
    static let shared = OfflineTranslationService()

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderrTask: Task<Void, Never>?
    private var stdoutRemainder = Data()
    private var preparedPair: String?
    private var cachedPairs: [TranslationPairInfo] = []

    func bootstrap(progress: @escaping @Sendable (String) -> Void) async throws {
        let root = try resolveRuntimeRoot()
        try FileManager.default.createDirectory(at: modelsDirectory(), withIntermediateDirectories: true)
        progress("Using bundled offline runtime…")
        try await ensureProcessRunning(runtimeRoot: root, progress: progress)
    }

    func listCatalog(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (languages: [AppLanguage], pairs: [TranslationPairInfo]) {
        let response = try await request(["cmd": "list_catalog"], progress: progress)
        guard let languages = response["languages"] as? [[String: Any]],
              let pairs = response["pairs"] as? [[String: Any]] else {
            throw OfflineTranslationError.invalidResponse
        }

        let mappedLanguages: [AppLanguage] = languages.compactMap { item in
            guard let code = item["code"] as? String,
                  let name = item["name"] as? String else { return nil }
            return AppLanguage(code: code, name: name)
        }

        let mappedPairs: [TranslationPairInfo] = pairs.compactMap { item in
            guard let from = item["from"] as? String,
                  let to = item["to"] as? String else { return nil }
            let approx = item["approx_mb"] as? Int ?? 150
            let installed = item["installed"] as? Bool ?? false
            return TranslationPairInfo(from: from, to: to, approxMB: approx, installed: installed)
        }

        cachedPairs = mappedPairs
        return (mappedLanguages, mappedPairs)
    }

    func availableTargets(from fromCode: String) -> [String] {
        let normalized = normalize(fromCode)
        return cachedPairs
            .filter { $0.from == normalized }
            .map(\.to)
    }

    func pairInfo(from fromCode: String, to toCode: String) -> TranslationPairInfo? {
        let from = normalize(fromCode)
        let to = normalize(toCode)
        return cachedPairs.first { $0.from == from && $0.to == to }
    }

    /// Download the model if needed, then load it into memory.
    func prepare(from fromCode: String, to toCode: String, progress: @escaping @Sendable (String) -> Void) async throws {
        let pair = "\(normalize(fromCode))->\(normalize(toCode))"
        if preparedPair == pair {
            progress("Language pair ready (\(pair)).")
            return
        }

        if let info = pairInfo(from: fromCode, to: toCode), !info.installed {
            progress("Model not installed yet — downloading \(info.label) (~\(info.approxMB) MB)…")
        } else {
            progress("Preparing model \(pair)…")
        }

        let response = try await request([
            "cmd": "prepare",
            "from": normalize(fromCode),
            "to": normalize(toCode)
        ], progress: progress)

        if let downloaded = response["downloaded"] as? Bool, downloaded {
            progress("Download finished for \(pair).")
        }

        preparedPair = pair
        // Refresh installed flags after a successful prepare.
        _ = try? await listCatalog(progress: { _ in })
        progress("Model ready for \(pair).")
    }

    /// Translate one PDF page with PyMuPDF and return a single-page PDF.
    func translatePage(pdfPath: String, pageIndex: Int, from fromCode: String, to toCode: String) async throws -> Data {
        let response = try await request([
            "cmd": "translate_page",
            "pdf_path": pdfPath,
            "page": pageIndex,
            "from": normalize(fromCode),
            "to": normalize(toCode)
        ])
        guard let b64 = response["page_pdf_b64"] as? String,
              let data = Data(base64Encoded: b64),
              !data.isEmpty else {
            throw OfflineTranslationError.invalidResponse
        }
        return data
    }

    // MARK: - Paths

    func modelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("offline-pdf-translator", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    private func resolveRuntimeRoot() throws -> URL {
        if let resource = Bundle.main.resourceURL?
            .appendingPathComponent("TranslatorRuntime", isDirectory: true),
           runtimeLooksValid(resource) {
            return resource
        }

        let devCandidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Services
                .deletingLastPathComponent() // offline-pdf-translator
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("TranslatorRuntime", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("TranslatorRuntime", isDirectory: true)
        ]
        for candidate in devCandidates where runtimeLooksValid(candidate) {
            return candidate
        }

        throw OfflineTranslationError.runtimeMissing
    }

    private func runtimeLooksValid(_ root: URL) -> Bool {
        let python = root.appendingPathComponent("python/bin/python3")
        let bridge = root.appendingPathComponent("ct2_bridge.py")
        let catalog = root.appendingPathComponent("model_catalog.json")
        return FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: bridge.path)
            && FileManager.default.fileExists(atPath: catalog.path)
    }

    // MARK: - Process I/O

    private func ensureProcessRunning(
        runtimeRoot: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        if let process, process.isRunning { return }

        progress("Starting bundled translator…")

        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        let bridge = runtimeRoot.appendingPathComponent("ct2_bridge.py")

        let proc = Process()
        proc.executableURL = python
        proc.arguments = [bridge.path]
        proc.currentDirectoryURL = runtimeRoot

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PDF_TRANSLATOR_MODELS_DIR"] = modelsDirectory().path
        proc.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        process = proc
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        stdoutRemainder = Data()

        stderrTask = Task.detached {
            let handle = errPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if let text = String(data: chunk, encoding: .utf8) {
                    fputs(text, stderr)
                }
            }
        }

        _ = try await readJSONLine()
    }

    private func request(
        _ payload: [String: Any],
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [String: Any] {
        guard let stdin, let process, process.isRunning else {
            throw OfflineTranslationError.notReady
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(contentsOf: "\n".utf8)
        try stdin.write(contentsOf: line)

        // Progress events may arrive before the final command response.
        while true {
            let response = try await readJSONLine()
            if let ok = response["ok"] as? Bool, ok == false {
                throw OfflineTranslationError.bridgeFailed((response["error"] as? String) ?? "Translator bridge error")
            }
            if let event = response["event"] as? String, event == "progress" {
                if let detail = response["detail"] as? String {
                    progress?(detail)
                }
                continue
            }
            return response
        }
    }

    private func readJSONLine() async throws -> [String: Any] {
        guard let stdout else { throw OfflineTranslationError.notReady }

        while true {
            if let object = try parseJSONLine(from: &stdoutRemainder) {
                return object
            }

            let chunk = stdout.availableData
            if chunk.isEmpty {
                try await Task.sleep(for: .milliseconds(15))
                if process?.isRunning != true {
                    throw OfflineTranslationError.bridgeFailed("Translator process exited unexpectedly.")
                }
                continue
            }
            stdoutRemainder.append(chunk)
        }
    }

    private func parseJSONLine(from buffer: inout Data) throws -> [String: Any]? {
        guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
        let next = buffer.index(after: newline)
        buffer = buffer.subdata(in: next..<buffer.endIndex)
        guard !lineData.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            throw OfflineTranslationError.invalidResponse
        }
        return object
    }

    private func normalize(_ code: String) -> String {
        let value = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if value.hasPrefix("zh") { return "zh" }
        return value.split(separator: "-").first.map(String.init) ?? value
    }
}
