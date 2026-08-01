//
//  SyncedPDFView.swift
//  offline-pdf-translator
//

import AppKit
import PDFKit
import SwiftUI

/// PDFKit viewer that reports / applies a normalized vertical scroll fraction (0…1).
struct SyncedPDFView: NSViewRepresentable {
    let document: PDFDocument?
    let revision: Int
    @Binding var scrollFraction: CGFloat
    let emptyMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollFraction: $scrollFraction)
    }

    func makeNSView(context: Context) -> PDFPaneContainer {
        let container = PDFPaneContainer()
        container.pdfView.autoScales = true
        container.pdfView.displayMode = .singlePageContinuous
        container.pdfView.displayDirection = .vertical
        container.pdfView.backgroundColor = NSColor.windowBackgroundColor
        container.emptyLabel.stringValue = emptyMessage
        return container
    }

    func updateNSView(_ container: PDFPaneContainer, context: Context) {
        container.emptyLabel.stringValue = emptyMessage
        context.coordinator.scrollFraction = $scrollFraction
        context.coordinator.ensureAttached(to: container.pdfView)

        if context.coordinator.boundRevision != revision {
            context.coordinator.boundRevision = revision
            container.pdfView.document = document
            container.showEmptyState(document == nil)
            DispatchQueue.main.async {
                context.coordinator.ensureAttached(to: container.pdfView)
                context.coordinator.applyScrollFraction(scrollFraction, to: container.pdfView)
            }
        } else {
            container.showEmptyState(document == nil)
            context.coordinator.applyScrollFractionIfNeeded(scrollFraction, to: container.pdfView)
        }
    }

    static func dismantleNSView(_ nsView: PDFPaneContainer, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var scrollFraction: Binding<CGFloat>
        var boundRevision: Int = -1
        private weak var observedClipView: NSClipView?
        private var isApplying = false
        private var lastApplied: CGFloat = -1
        private var observations: [NSObjectProtocol] = []

        init(scrollFraction: Binding<CGFloat>) {
            self.scrollFraction = scrollFraction
        }

        func ensureAttached(to pdfView: PDFView) {
            guard let scrollView = Self.nestedScrollView(in: pdfView) else { return }
            if observedClipView === scrollView.contentView { return }

            detach()
            observedClipView = scrollView.contentView
            scrollView.contentView.postsBoundsChangedNotifications = true

            let boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleUserScroll(in: pdfView)
            }
            observations.append(boundsObserver)
        }

        func detach() {
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations.removeAll()
            observedClipView = nil
        }

        private func handleUserScroll(in pdfView: PDFView) {
            guard !isApplying else { return }
            let fraction = currentFraction(in: pdfView)
            guard abs(fraction - scrollFraction.wrappedValue) > 0.001 else { return }
            lastApplied = fraction
            scrollFraction.wrappedValue = fraction
        }

        func applyScrollFractionIfNeeded(_ fraction: CGFloat, to pdfView: PDFView) {
            guard abs(fraction - lastApplied) > 0.001 else { return }
            applyScrollFraction(fraction, to: pdfView)
        }

        func applyScrollFraction(_ fraction: CGFloat, to pdfView: PDFView) {
            guard let scrollView = Self.nestedScrollView(in: pdfView),
                  let documentView = scrollView.documentView else { return }

            let clipHeight = scrollView.contentView.bounds.height
            let docHeight = documentView.bounds.height
            let maxOffset = max(docHeight - clipHeight, 0)
            guard maxOffset > 0 else { return }

            let clamped = min(max(fraction, 0), 1)
            let targetY = clamped * maxOffset
            var origin = scrollView.contentView.bounds.origin
            if abs(origin.y - targetY) < 0.5 {
                lastApplied = clamped
                return
            }

            isApplying = true
            lastApplied = clamped
            origin.y = targetY
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplying = false
        }

        private func currentFraction(in pdfView: PDFView) -> CGFloat {
            guard let scrollView = Self.nestedScrollView(in: pdfView),
                  let documentView = scrollView.documentView else { return 0 }

            let clip = scrollView.contentView.bounds
            let maxOffset = max(documentView.bounds.height - clip.height, 0)
            guard maxOffset > 0 else { return 0 }
            return min(max(clip.origin.y / maxOffset, 0), 1)
        }

        private static func nestedScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let found = nestedScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}

final class PDFPaneContainer: NSView {
    let pdfView = PDFView()
    let emptyLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.isHidden = true

        addSubview(pdfView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showEmptyState(_ show: Bool) {
        emptyLabel.isHidden = !show
        pdfView.isHidden = show
    }
}
