import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    private let controller: GlobalAudioController
    private let stateLabel = NSTextField(labelWithString: "Stopped")
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(title: "Start", target: nil, action: nil)

    init(controller: GlobalAudioController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Global Vocal Remover"
        window.center()
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Global Vocal Remover")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        stateLabel.font = .systemFont(ofSize: 14, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        toggleButton.bezelStyle = .rounded

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(stateLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(toggleButton)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -22),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func toggle() {
        if controller.isRunning {
            controller.stop()
            refresh()
            return
        }

        Task { @MainActor in
            do {
                try controller.start()
            } catch {
                NSAlert(error: error).runModal()
            }
            refresh()
        }
    }

    private func refresh() {
        stateLabel.stringValue = controller.isRunning ? "Running" : "Stopped"
        detailLabel.stringValue = controller.statusText
        toggleButton.title = controller.isRunning ? "Stop" : "Start"
    }
}
