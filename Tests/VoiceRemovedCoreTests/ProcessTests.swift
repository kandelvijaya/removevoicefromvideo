import XCTest
import Foundation
@testable import VoiceRemovedCore

final class ProcessTests: XCTestCase {
    func testStderrDrainPreventsPipeDeadlockAndReportsFailure() throws {
        let tools = try Tools()
        let script = "BEGIN { for (i=0; i<20000; i++) { print \"diagnostic diagnostic diagnostic\" > \"/dev/stderr\"; print \"output output output\" }; print \"tail-marker\" > \"/dev/stderr\"; exit 7 }"
        XCTAssertThrowsError(try tools.capture(URL(fileURLWithPath: "/usr/bin/awk"), [script], Cancellation())) { error in
            XCTAssertTrue(String(describing: error).contains("tail-marker"))
            XCTAssertTrue(String(describing: error).contains("failed (7)"))
            XCTAssertLessThan(String(describing: error).utf8.count, 66000)
        }
    }
    func testOutputLimitAbortsChild() throws {
        let tools = try Tools()
        XCTAssertThrowsError(try tools.capture(URL(fileURLWithPath: "/usr/bin/yes"), [], Cancellation(), limit: 1024))
    }
    func testCancellationTerminatesBlockedChild() throws {
        let cancellation = Cancellation()
        let child = try Child(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], cancellation: cancellation)
        defer { child.abort() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.cancel() }
        let start = Date()
        XCTAssertThrowsError(try child.finish())
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
