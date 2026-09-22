import AppKit
import SwiftUI
import XCTest

@testable import Xcodes

@MainActor
final class ProgressButtonTests: XCTestCase {
    func testBusyButtonPreservesItsSize() {
        let idle = makeHost(isInProgress: false)
        let busy = makeHost(isInProgress: true)

        XCTAssertEqual(idle.fittingSize.width, busy.fittingSize.width, accuracy: 0.5)
        XCTAssertEqual(idle.fittingSize.height, busy.fittingSize.height, accuracy: 0.5)
    }

    private func makeHost(isInProgress: Bool) -> NSHostingView<ProgressButton<Text>> {
        let host = NSHostingView(rootView: ProgressButton(isInProgress: isInProgress, action: {}) {
            Text(verbatim: "Continue")
        })
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 40)
        host.layoutSubtreeIfNeeded()
        return host
    }

}
