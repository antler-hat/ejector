import XCTest
import Darwin
@testable import Ejector

final class VolumeManagerTests: XCTestCase {
    func testAcceptsTheCurrentProcessIdentity() throws {
        let manager = VolumeManager()
        let pid = Int(getpid())
        let startedAt = try XCTUnwrap(manager.processStartTime(for: pid))

        XCTAssertTrue(manager.isCurrent(ProcessInfo(name: "EjectorTests", pid: pid, startedAt: startedAt)))
    }

    func testRejectsAStaleProcessIdentity() {
        let manager = VolumeManager()
        XCTAssertFalse(manager.isCurrent(ProcessInfo(name: "sleep", pid: 1, startedAt: "stale")))
    }
}
