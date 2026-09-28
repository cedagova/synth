// THROWAWAY (#98): proves CI uploads a downloadable .xcresult when a test
// fails. Reverted in the next commit; never merge this file.
import XCTest

final class CIResultBundleDemoTests: XCTestCase {
    func testDeliberateFailureForResultBundleDemo() {
        XCTFail("Deliberate failure: #98 result-bundle upload demonstration")
    }
}
