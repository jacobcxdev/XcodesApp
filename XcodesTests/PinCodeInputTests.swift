import AppKit
import Testing

@testable import Xcodes

struct PinCodeInputTests {
    @Test(
        "Normalises verification-code input",
        arguments: [
            (input: "1", previous: "", expected: "1"),
            (input: "12", previous: "1", expected: "12"),
            (input: "123 456", previous: "", expected: "123456"),
            (input: "12987654", previous: "12", expected: "987654"),
            (input: "12345", previous: "123456", expected: "12345"),
            (input: "1234567", previous: "", expected: "123456"),
            (input: "12-AB 34", previous: "", expected: "12AB34"),
        ]
    )
    func normalisesInput(_ testCase: (input: String, previous: String, expected: String)) {
        #expect(
            PinCodeInput.normalise(
                testCase.input,
                replacing: testCase.previous,
                numberOfDigits: 6
            ) == testCase.expected
        )
    }

    @Test("Reports completion only at required length")
    func reportsCompletion() {
        #expect(PinCodeInput.isComplete("12345", numberOfDigits: 6) == false)
        #expect(PinCodeInput.isComplete("123456", numberOfDigits: 6))
    }

    @Test("Publishes edits and completion from the input")
    @MainActor
    func publishesInput() throws {
        let view = PinCodeTextView(
            numberOfDigits: 6,
            itemSpacing: 10,
            accessibilityLabel: "Verification code"
        )
        let inputField = try #require(textFields(in: view).first { $0.isEditable })
        var changes: [String] = []
        var completions: [String] = []
        view.codeDidChange = { changes.append($0) }
        view.codeDidComplete = { completions.append($0) }

        inputField.stringValue = "12"
        view.controlTextDidChange(textDidChangeNotification(for: inputField))
        inputField.stringValue = "12987654"
        view.controlTextDidChange(textDidChangeNotification(for: inputField))
        inputField.stringValue = "98765"
        view.controlTextDidChange(textDidChangeNotification(for: inputField))

        #expect(changes == ["12", "987654", "98765"])
        #expect(completions == ["987654"])
        #expect(view.currentCode == "98765")
    }

    @Test("Configures one accessible autofill input")
    @MainActor
    func configuresAccessibleInput() throws {
        let view = PinCodeTextView(
            numberOfDigits: 6,
            itemSpacing: 10,
            accessibilityLabel: "Verification code"
        )
        let textFields = textFields(in: view)
        let inputField = try #require(textFields.first { $0.isEditable })

        #expect(textFields.filter(\.isEditable).count == 1)
        #expect(textFields.filter { !$0.isEditable }.count == 6)
        #expect(inputField.contentType == .oneTimeCode)
        #expect(inputField.accessibilityLabel() == "Verification code")
        #expect(textFields.filter { !$0.isEditable }.allSatisfy { !$0.isAccessibilityElement() })
    }

    @Test("Forwards focus to the single input")
    @MainActor
    func forwardsFocus() throws {
        let view = PinCodeTextView(
            numberOfDigits: 6,
            itemSpacing: 10,
            accessibilityLabel: "Verification code"
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let inputField = try #require(textFields(in: view).first { $0.isEditable })

        #expect(view.becomeFirstResponder())
        let responder = window.firstResponder
        let fieldEditor = responder as? NSTextView
        #expect(responder === inputField || fieldEditor?.delegate === inputField)
    }

    @MainActor
    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            let field = (subview as? NSTextField).map { [$0] } ?? []
            return field + textFields(in: subview)
        }
    }

    private func textDidChangeNotification(for textField: NSTextField) -> Notification {
        Notification(name: NSControl.textDidChangeNotification, object: textField)
    }
}
