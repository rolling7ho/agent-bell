import AppKit

@MainActor
final class WarningCalloutView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")

    init(text: String, maximumNumberOfLines: Int = 4) {
        super.init(frame: .zero)
        label.stringValue = text
        configure(maximumNumberOfLines: maximumNumberOfLines)
    }

    init(attributedText: NSAttributedString, maximumNumberOfLines: Int = 8) {
        super.init(frame: .zero)
        label.attributedStringValue = attributedText
        configure(maximumNumberOfLines: maximumNumberOfLines)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure(maximumNumberOfLines: Int) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemYellow
            .withAlphaComponent(0.1).cgColor
        layer?.borderWidth = 0.75
        layer?.borderColor = NSColor.systemYellow
            .withAlphaComponent(0.34).cgColor

        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .systemYellow
        label.maximumNumberOfLines = maximumNumberOfLines
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }
}
