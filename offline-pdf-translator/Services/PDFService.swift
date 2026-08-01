//
//  PDFService.swift
//  offline-pdf-translator
//

import Foundation
import PDFKit

enum PDFServiceError: LocalizedError {
    case unableToOpen
    case emptyDocument
    case unableToCreateOutput

    var errorDescription: String? {
        switch self {
        case .unableToOpen:
            return "Could not open the selected PDF."
        case .emptyDocument:
            return "This PDF has no pages."
        case .unableToCreateOutput:
            return "Could not create the translated PDF."
        }
    }
}

enum PDFService {
    static func loadDocument(from url: URL) throws -> PDFDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else {
            throw PDFServiceError.unableToOpen
        }
        guard document.pageCount > 0 else {
            throw PDFServiceError.emptyDocument
        }
        return document
    }

    static func document(from data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw PDFServiceError.unableToCreateOutput
        }
        return document
    }

    /// Replaces one page in an existing document for progressive preview.
    static func replacePage(in document: PDFDocument, at index: Int, with page: PDFPage) {
        let bounded = max(0, min(index, document.pageCount))
        if bounded < document.pageCount {
            document.removePage(at: bounded)
        }
        document.insert(page, at: bounded)
    }
}
