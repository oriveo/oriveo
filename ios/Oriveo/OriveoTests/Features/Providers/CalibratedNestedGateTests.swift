import CoreFoundation
import Testing
@testable import Oriveo

/// How the load-calibrated gate decides: a real slowdown of the code must go red, while a merely slower machine baseline must not (the numbers are of the order of a same-machine A/B).
@Suite("Load-calibrated gate decisions")
struct CalibratedNestedGateTests {
    private let nested: CFTimeInterval = 0.0420
    private let baseline: CFTimeInterval = 0.06055

    @Test("machine baseline unchanged, a fixed 12ms delay injected into the measured section: crosses the line")
    func injected_delay_on_same_machine_fails() {
        let gate = CalibratedNestedGate(reference: baseline, referenceBaseline: baseline, noise: 1.25)
        let healthy = nested * 1.1
        #expect(gate.passes(measured: healthy, nested: nested))
        #expect(!gate.passes(measured: healthy + 0.012, nested: nested))
    }

    @Test("whole machine baseline 40% slower (reference and measured section slow down in proportion): does not cross the line")
    func slower_machine_baseline_passes() {
        let slower = 1.4
        let gate = CalibratedNestedGate(reference: baseline * slower, referenceBaseline: baseline, noise: 1.25)
        let measured = nested * 1.1 * slower
        #expect(gate.passes(measured: measured, nested: nested))
        // An old gate without the scaling would misjudge this same measurement as red, which is exactly what calibration is for.
        #expect(measured > nested * 1.25)
    }

    @Test("machine baseline 40% slower and the code really gets another 12ms slower: still crosses the line")
    func slower_machine_plus_injected_delay_fails() {
        let slower = 1.4
        let gate = CalibratedNestedGate(reference: baseline * slower, referenceBaseline: baseline, noise: 1.25)
        #expect(!gate.passes(measured: nested * 1.1 * slower + 0.012, nested: nested))
    }
}
