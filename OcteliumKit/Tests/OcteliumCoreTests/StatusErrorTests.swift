import Foundation
import XCTest

@testable import OcteliumCore

final class StatusErrorTests: XCTestCase {

    func testGetStatusError() {
        XCTAssertEqual(.invalidArgument, getStatusError(code: 3, message: "invalid").code)
        XCTAssertEqual("invalid", getStatusError(code: 3, message: "invalid").message)
        XCTAssertEqual(.unauthenticated, getStatusError(code: 16, message: "").code)
        XCTAssertEqual(.unknown, getStatusError(code: 0, message: "").code)
        XCTAssertEqual(.unknown, getStatusError(code: 17, message: "").code)
        XCTAssertEqual(.unknown, getStatusError(code: -1, message: "").code)
        XCTAssertEqual(17, StatusCode.allCases.count)
        XCTAssertEqual(17, Set(StatusCode.allCases.map(\.name)).count)
    }

    func testGetErrorMessage() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }

        XCTAssertEqual("invalid", getErrorMessage(getStatusError(code: 3, message: "invalid")))
        XCTAssertEqual("NOT_FOUND", getErrorMessage(StatusError(.notFound, "")))
        XCTAssertEqual("boom", getErrorMessage(TestError()))
        XCTAssertEqual("failed", getErrorMessage(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed"])))
        XCTAssertEqual(.aborted, getStatusCode(StatusError(.aborted, "")))
        XCTAssertNil(getStatusCode(TestError()))
        XCTAssertEqual("NOT_FOUND: missing", StatusError(.notFound, "missing").description)
    }
}
