import Foundation
import XCTest

@testable import OcteliumCore

final class NetworkWatcherTests: XCTestCase {

    func testGetReconnectBackoff() {
        for attempt in 0...20 {
            let ret = getReconnectBackoff(attempt)
            let base = min(reconnectBackoffMin * (1 << min(max(attempt - 1, 0), 6)), reconnectBackoffMax)

            XCTAssertGreaterThanOrEqual(ret, base)
            XCTAssertLessThanOrEqual(ret, reconnectBackoffMax)
            XCTAssertLessThanOrEqual(ret, base + base / 2)
        }
    }

    func testSet() async {
        let w = NetworkWatcher()
        XCTAssertTrue(w.isAvailable)

        var updates = w.updates().makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(NetworkState(isAvailable: true, id: ""), initial)

        w.set(NetworkState(isAvailable: true, id: ""))
        w.set(NetworkState(isAvailable: false, id: ""))
        XCTAssertFalse(w.isAvailable)

        let next = await updates.next()
        XCTAssertEqual(NetworkState(isAvailable: false, id: ""), next)
    }

    func testWaitReconnect() async throws {
        do {
            let w = NetworkWatcher { _ in .milliseconds(50) }

            let start = ContinuousClock.now
            await w.waitReconnect(1)
            XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(50))
        }

        do {
            let w = NetworkWatcher { _ in .seconds(60) }
            w.set(NetworkState(isAvailable: false, id: ""))

            let task = Task {
                await w.waitReconnect(1)
            }

            try await Task.sleep(for: .milliseconds(50))
            w.set(NetworkState(isAvailable: false, id: "other"))
            try await Task.sleep(for: .milliseconds(50))

            w.set(NetworkState(isAvailable: true, id: "100"))
            await task.value
            XCTAssertEqual(NetworkState(isAvailable: true, id: "100"), w.current)
        }

        do {
            let w = NetworkWatcher { _ in .seconds(60) }
            w.set(NetworkState(isAvailable: true, id: "100"))

            let task = Task {
                await w.waitReconnect(3)
            }

            try await Task.sleep(for: .milliseconds(50))
            w.set(NetworkState(isAvailable: true, id: "101"))
            await task.value
        }
    }
}
