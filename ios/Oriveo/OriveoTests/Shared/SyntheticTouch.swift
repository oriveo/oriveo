import Darwin
import Foundation
import UIKit

/// Synthesizes a real finger tap in the test host that goes through the same hit testing and gesture arbitration as
/// a real finger (SwiftUI's Button / onTapGesture decide among themselves who takes the tap; the test does not pick).
///
/// How: build an IOHIDEvent digitizer event (a hand plus one finger) and hand it to `UIApplication._enqueueHIDEvent:`,
/// the same entry point the system uses to deliver hardware events to the app, so UIKit creates the UITouch from the
/// event and does its own hit testing. This uses private UIKit / IOKit / BackBoardServices interfaces and is for unit
/// tests only. (The older KIF approach of building a `UITouch` + `UIEvent` and calling `sendEvent` only drives UIKit
/// controls on iOS 18; SwiftUI Buttons never see it.) If a system update changes the private interfaces this throws
/// instead of silently succeeding; every test that uses it should include a self check that tapping a plain Button
/// works.
@MainActor
enum SyntheticTouch {
    enum Failure: Error, CustomStringConvertible {
        case missingSelector(String)
        case missingSymbol(String)

        var description: String {
            switch self {
            case .missingSelector(let name): "private selector not found: \(name)"
            case .missingSymbol(let name): "private symbol not found: \(name)"
            }
        }
    }

    /// Touches down at `point` in window coordinates, holds briefly, and lifts at the same point.
    static func tap(at point: CGPoint, in window: UIWindow, holdFor hold: Duration = .milliseconds(60)) async throws {
        let screenPoint = window.convert(point, to: window.screen.coordinateSpace)
        try enqueue(try digitizerEvent(at: screenPoint, touching: true, window: window))
        try await Task.sleep(for: hold)
        try enqueue(try digitizerEvent(at: screenPoint, touching: false, window: window))
    }

    // MARK: - IOHIDEvent

    private typealias CreateHand = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
    ) -> OpaquePointer?
    private typealias CreateFinger = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Double, Double, Double, Double, Double,
        UInt8, UInt8, UInt32
    ) -> OpaquePointer?
    private typealias SetInteger = @convention(c) (OpaquePointer?, UInt32, Int) -> Void
    private typealias SetSender = @convention(c) (OpaquePointer?, UInt64) -> Void
    private typealias Append = @convention(c) (OpaquePointer?, OpaquePointer?, UInt32) -> Void
    private typealias SetDigitizerInfo = @convention(c) (OpaquePointer?, UInt32, UInt8, UInt8, CFString?, Double, Float) -> Void

    private static let transducerHand: UInt32 = 3
    private static let eventRange: UInt32 = 1 << 0
    private static let eventTouch: UInt32 = 1 << 1
    /// kIOHIDEventTypeDigitizer(11) << 16 | 25 (IsDisplayIntegrated)
    private static let fieldIsDisplayIntegrated: UInt32 = (11 << 16) | 25
    private static let senderID: UInt64 = 0x0000_0001_2345_6789

    private static func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            throw Failure.missingSymbol(name)
        }
        return unsafeBitCast(pointer, to: type)
    }

    /// A hand plus one finger digitizer event; the location is in screen points.
    private static func digitizerEvent(at location: CGPoint, touching: Bool, window: UIWindow) throws -> OpaquePointer? {
        let createHand = try symbol("IOHIDEventCreateDigitizerEvent", as: CreateHand.self)
        let createFinger = try symbol("IOHIDEventCreateDigitizerFingerEventWithQuality", as: CreateFinger.self)
        let setInteger = try symbol("IOHIDEventSetIntegerValue", as: SetInteger.self)
        let setSender = try symbol("IOHIDEventSetSenderID", as: SetSender.self)
        let append = try symbol("IOHIDEventAppendEvent", as: Append.self)

        let timestamp = mach_absolute_time()
        let flag: UInt8 = touching ? 1 : 0
        let hand = createHand(kCFAllocatorDefault, timestamp, transducerHand, 0, 0, eventTouch, 0, 0, 0, 0, 0, 0, flag, flag, 0)
        setInteger(hand, fieldIsDisplayIntegrated, 1)
        setSender(hand, senderID)
        let finger = createFinger(
            kCFAllocatorDefault, timestamp, 1, 2, eventRange | eventTouch,
            Double(location.x), Double(location.y), 0, touching ? 0.5 : 0, 0, 5, 5, 1, 1, 1,
            flag, flag, 0
        )
        setInteger(finger, fieldIsDisplayIntegrated, 1)
        append(hand, finger, 0)

        // Attribute the event to this window's CA context so UIKit routes it there (backboardd fills this in for
        // system events)
        if let setDigitizerInfo = try? symbol("BKSHIDEventSetDigitizerInfo", as: SetDigitizerInfo.self) {
            setDigitizerInfo(hand, try contextID(of: window), 0, 0, nil, 0, 0)
        }
        return hand
    }

    private static func contextID(of window: UIWindow) throws -> UInt32 {
        typealias Fn = @convention(c) (NSObject, Selector) -> UInt32
        let (fn, selector) = try implementation(window, "_contextId", as: Fn.self)
        return fn(window, selector)
    }

    private static func enqueue(_ event: OpaquePointer?) throws {
        typealias Fn = @convention(c) (NSObject, Selector, OpaquePointer?) -> Void
        let application = UIApplication.shared
        let (fn, selector) = try implementation(application, "_enqueueHIDEvent:", as: Fn.self)
        fn(application, selector, event)
    }

    // MARK: - Private selector calls

    private static func implementation<T>(_ target: NSObject, _ name: String, as type: T.Type) throws -> (T, Selector) {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { throw Failure.missingSelector(name) }
        return (unsafeBitCast(target.method(for: selector), to: type), selector)
    }
}
