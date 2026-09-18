import Cocoa
import SwiftUI
import XCTest

@testable import Xcodes

@MainActor
final class SignInCredentialsViewTests: XCTestCase {
    func test_MarksCredentialFieldsForAutofill() {
        let appState = AppState()
        let hostingView = NSHostingView(rootView: SignInCredentialsView().environmentObject(appState))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        hostingView.layoutSubtreeIfNeeded()

        let editableTextFields = hostingView.recursiveSubviews(ofType: NSTextField.self)
            .filter(\.isEditable)
        let contentTypes = Set(editableTextFields.compactMap(\.contentType))

        XCTAssertTrue(contentTypes.contains(.username))
        XCTAssertTrue(contentTypes.contains(.password))
    }
}

private extension NSView {
    func recursiveSubviews<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.compactMap { $0 as? T } + subviews.flatMap { $0.recursiveSubviews(ofType: type) }
    }
}
