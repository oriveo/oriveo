import XCTest
@testable import Oriveo

@MainActor
final class StreamingDisplayClockTests: XCTestCase {
    func testStartsPaused() {
        let clock = StreamingDisplayClock()
        XCTAssertFalse(clock.isRunning)
    }

    func testResumeStartsTickingWithSubscriber() {
        let clock = StreamingDisplayClock()
        let token = clock.addSubscriber { _ in }
        clock.resume()
        XCTAssertTrue(clock.isRunning)
        clock.pause()
        XCTAssertFalse(clock.isRunning)
        clock.removeSubscriber(token)
    }

    func testResumeWithNoSubscriberStaysPaused() {
        let clock = StreamingDisplayClock()
        clock.resume()
        XCTAssertFalse(clock.isRunning)
    }

    func testSubscriberReceivesTimestamp() {
        let clock = StreamingDisplayClock()
        let expectation = self.expectation(description: "tick received")
        var observedTimestamp: CFTimeInterval = 0

        let token = clock.addSubscriber { timestamp in
            observedTimestamp = timestamp
            expectation.fulfill()
        }
        clock.resume()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertGreaterThan(observedTimestamp, 0)
        clock.removeSubscriber(token)
    }

    func testPausesWhenAllSubscribersRemoved() {
        let clock = StreamingDisplayClock()
        let token = clock.addSubscriber { _ in }
        clock.resume()
        XCTAssertTrue(clock.isRunning)
        clock.removeSubscriber(token)
        XCTAssertFalse(clock.isRunning)
    }
}
