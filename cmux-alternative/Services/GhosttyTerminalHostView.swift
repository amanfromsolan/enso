import AppKit
import SwiftUI

struct GhosttyTerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> PlaceholderTerminalView {
        PlaceholderTerminalView()
    }

    func updateNSView(_ nsView: PlaceholderTerminalView, context: Context) {
        nsView.configure(session: session)
    }
}

final class PlaceholderTerminalView: NSView {
    private let stackView = NSStackView()
    private let promptLabel = NSTextField(labelWithString: "")
    private let outputLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(session: TerminalSession) {
        promptLabel.stringValue = "\(session.workingDirectory) %"
        outputLabel.stringValue = """
        Ghostty host boundary is ready.

        Session: \(session.title)
        Status: \(session.status.rawValue)

        Replace PlaceholderTerminalView with the Ghostty/libghostty-backed NSView here.
        """
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false

        promptLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.lineBreakMode = .byTruncatingMiddle
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        outputLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        outputLabel.textColor = .labelColor
        outputLabel.maximumNumberOfLines = 0

        stackView.addArrangedSubview(promptLabel)
        stackView.addArrangedSubview(outputLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 22)
        ])
    }
}
