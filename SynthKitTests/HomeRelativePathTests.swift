import XCTest
@testable import SynthKit

final class HomeRelativePathTests: XCTestCase {
    private let home = "/Users/owner"

    func testPathsInsideHomeAreAbbreviated() {
        XCTAssertEqual(
            HomeRelativePath.display(
                "/Users/owner/Library/Containers/com.cedagova.synth/Data/Library/Application Support/Synth",
                relativeTo: home
            ),
            "~/Library/Containers/com.cedagova.synth/Data/Library/Application Support/Synth"
        )
    }

    func testHomeItselfBecomesTilde() {
        XCTAssertEqual(HomeRelativePath.display(home, relativeTo: home), "~")
    }

    func testTrailingSlashOnHomeIsTolerated() {
        XCTAssertEqual(
            HomeRelativePath.display("/Users/owner/Music", relativeTo: "/Users/owner/"),
            "~/Music"
        )
    }

    func testPathsOutsideHomeAreLeftAlone() {
        XCTAssertEqual(
            HomeRelativePath.display("/Volumes/External/Synth", relativeTo: home),
            "/Volumes/External/Synth"
        )
    }

    func testASiblingDirectoryIsNotTreatedAsInsideHome() {
        XCTAssertEqual(
            HomeRelativePath.display("/Users/owner2/Music", relativeTo: home),
            "/Users/owner2/Music"
        )
    }

    func testAnEmptyHomeLeavesThePathUnchanged() {
        XCTAssertEqual(
            HomeRelativePath.display("/Users/owner/Music", relativeTo: ""),
            "/Users/owner/Music"
        )
    }

    func testRealHomeDirectoryIsAnAbsolutePath() {
        let home = HomeRelativePath.realHomeDirectory
        XCTAssertTrue(home.hasPrefix("/"), "Expected an absolute path, got \(home)")
        XCTAssertFalse(home.isEmpty)
    }
}
