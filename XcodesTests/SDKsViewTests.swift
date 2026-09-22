import XCTest
import XcodesKit

@testable import Xcodes

@MainActor
final class SDKsViewTests: XCTestCase {
    func testDisplaysVisionOSWhenItIsTheOnlySDK() {
        let sdks = SDKs(visionOS: .init(number: "26.0"))

        XCTAssertEqual(SDKsView(sdks: sdks).content, "visionOS: 26.0")
    }

    func testDisplaysAllSDKsInPlatformOrder() {
        let sdks = SDKs(
            macOS: .init(number: "26.0"),
            iOS: .init(number: "26.1"),
            watchOS: .init(number: "26.2"),
            tvOS: .init(number: "26.3"),
            visionOS: .init(number: "26.4")
        )

        XCTAssertEqual(
            SDKsView(sdks: sdks).content,
            "macOS: 26.0\niOS: 26.1\nwatchOS: 26.2\ntvOS: 26.3\nvisionOS: 26.4"
        )
    }

    func testOmitsMissingSDKMetadata() {
        XCTAssertEqual(SDKsView(sdks: nil).content, "")
        XCTAssertEqual(SDKsView(sdks: SDKs()).content, "")
        XCTAssertEqual(SDKsView(sdks: SDKs(visionOS: .init("23A123"))).content, "")
    }
}
