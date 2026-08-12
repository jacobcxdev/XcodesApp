import Cocoa
import SwiftUI

enum PinCodeInput {
    static func normalise(
        _ input: String,
        replacing previousCode: String,
        numberOfDigits: Int
    ) -> String {
        guard numberOfDigits > 0 else { return "" }

        if let insertedText = insertedText(from: previousCode, to: input) {
            let insertedCode = sanitise(insertedText, numberOfDigits: numberOfDigits)
            if insertedText.count > 1, insertedCode.count == numberOfDigits {
                return insertedCode
            }
        }

        return sanitise(input, numberOfDigits: numberOfDigits)
    }

    static func isComplete(_ code: String, numberOfDigits: Int) -> Bool {
        code.count == numberOfDigits
    }

    static func sanitise(_ input: String, numberOfDigits: Int) -> String {
        guard numberOfDigits > 0 else { return "" }
        return String(input.filter { $0.isLetter || $0.isNumber }.prefix(numberOfDigits))
    }

    private static func insertedText(from oldValue: String, to newValue: String) -> String? {
        guard newValue.count > oldValue.count else { return nil }

        let oldCharacters = Array(oldValue)
        let newCharacters = Array(newValue)
        var prefixCount = 0
        while prefixCount < oldCharacters.count,
              oldCharacters[prefixCount] == newCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < oldCharacters.count - prefixCount,
              oldCharacters[oldCharacters.count - suffixCount - 1]
                == newCharacters[newCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        return String(newCharacters[prefixCount..<(newCharacters.count - suffixCount)])
    }
}

struct PinCodeTextField: NSViewRepresentable {
    typealias NSViewType = PinCodeTextView

    @Binding var code: String
    let numberOfDigits: Int
    let accessibilityLabel: String
    let complete: (String) -> Void

    func makeNSView(context: Context) -> NSViewType {
        let view = PinCodeTextView(
            numberOfDigits: numberOfDigits,
            itemSpacing: 10,
            accessibilityLabel: accessibilityLabel
        )
        view.codeDidChange = { code = $0 }
        view.codeDidComplete = complete
        return view
    }

    func updateNSView(_ nsView: NSViewType, context: Context) {
        nsView.setCode(code)
        nsView.updateAccessibilityLabel(accessibilityLabel)
    }
}

struct PinCodeTextField_Previews: PreviewProvider {
    struct PreviewContainer: View {
        @State private var code = "1234567890"

        var body: some View {
            PinCodeTextField(
                code: $code,
                numberOfDigits: 11,
                accessibilityLabel: "Verification code"
            ) {
                print("Input is complete \($0)")
            }
            .padding()
        }
    }

    static var previews: some View {
        PreviewContainer()
    }
}

final class PinCodeTextView: NSControl, NSTextFieldDelegate {
    var codeDidChange: ((String) -> Void)?
    var codeDidComplete: ((String) -> Void)?

    private(set) var currentCode = ""

    private let numberOfDigits: Int
    private let stackView = NSStackView(frame: .zero)
    private var characterBoxes: [PinCodeCharacterBox] = []
    private let inputField = PinCodeInputField()
    private var firstResponderObservation: NSKeyValueObservation?

    init(numberOfDigits: Int, itemSpacing: CGFloat, accessibilityLabel: String) {
        precondition(numberOfDigits > 0)
        self.numberOfDigits = numberOfDigits
        super.init(frame: .zero)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.spacing = itemSpacing
        stackView.orientation = .horizontal
        stackView.distribution = .fillEqually
        stackView.alignment = .centerY
        addSubview(stackView)

        characterBoxes = (0..<numberOfDigits).map { _ in
            let box = PinCodeCharacterBox()
            box.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(box)
            stackView.heightAnchor.constraint(equalTo: box.heightAnchor).isActive = true
            return box
        }

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.delegate = self
        inputField.setAccessibilityLabel(accessibilityLabel)
        addSubview(inputField)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            inputField.topAnchor.constraint(equalTo: topAnchor),
            inputField.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputField.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        updateBoxes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCode(_ code: String) {
        let normalisedCode = PinCodeInput.sanitise(code, numberOfDigits: numberOfDigits)
        guard normalisedCode != currentCode else { return }

        currentCode = normalisedCode
        inputField.stringValue = normalisedCode
        updateBoxes()
    }

    func updateAccessibilityLabel(_ accessibilityLabel: String) {
        inputField.setAccessibilityLabel(accessibilityLabel)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        firstResponderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateBoxes()
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === window else {
                return
            }
            window.makeFirstResponder(self.inputField)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === inputField, isEnabled else { return }

        let normalisedCode = PinCodeInput.normalise(
            inputField.stringValue,
            replacing: currentCode,
            numberOfDigits: numberOfDigits
        )
        inputField.replaceText(with: normalisedCode)
        guard normalisedCode != currentCode else { return }

        currentCode = normalisedCode
        updateBoxes()
        codeDidChange?(normalisedCode)

        if PinCodeInput.isComplete(normalisedCode, numberOfDigits: numberOfDigits) {
            codeDidComplete?(normalisedCode)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(inputField) ?? inputField.becomeFirstResponder()
    }

    override var isEnabled: Bool {
        didSet { inputField.isEnabled = isEnabled }
    }

    private func updateBoxes() {
        let characters = Array(currentCode)
        let activeIndex = isInputFocused ? min(characters.count, numberOfDigits - 1) : nil

        for (index, box) in characterBoxes.enumerated() {
            box.character = index < characters.count ? characters[index] : nil
            box.isActive = index == activeIndex
        }
    }

    private var isInputFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === inputField { return true }
        return (responder as? NSTextView)?.delegate === inputField
    }
}

private final class PinCodeInputField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBordered = false
        drawsBackground = false
        focusRingType = .none
        textColor = .clear
        usesSingleLineMode = true
        cell?.isScrollable = true
        contentType = .oneTimeCode
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            updateFieldEditor()
        }
        return didBecomeFirstResponder
    }

    func replaceText(with text: String) {
        guard stringValue != text else { return }
        stringValue = text
        updateFieldEditor()
    }

    private func updateFieldEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = .clear
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor.clear,
            .foregroundColor: NSColor.clear,
        ]
        editor.setSelectedRange(NSRange(location: stringValue.utf16.count, length: 0))
    }
}

private final class PinCodeCharacterBox: NSTextField {
    var character: Character? {
        didSet { stringValue = character.map(String.init) ?? "" }
    }

    var isActive = false {
        didSet {
            layer?.borderWidth = isActive ? 2 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.cornerRadius = isActive ? 3 : 0
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        isEditable = false
        isSelectable = false
        alignment = .center
        maximumNumberOfLines = 1
        font = .boldSystemFont(ofSize: 48)
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = NSAttributedString(
            string: "0",
            attributes: [.font: font as Any]
        ).size()
        size.width += 16
        size.height += 8
        return size
    }
}
