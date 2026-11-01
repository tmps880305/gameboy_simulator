import Foundation
import Observation
import SameBoyCore

enum SpeedMode: Hashable {
    case normal
    case fixed(Int)
    case unlimited

    /// Order used by the toggle button.
    static let toggleCycle: [SpeedMode] = [.normal, .fixed(2), .fixed(4), .unlimited]
    /// Choices for the hold-to-fast-forward setting.
    static let holdChoices: [SpeedMode] = [.fixed(2), .fixed(4), .fixed(8), .unlimited]

    /// Compact integer form shared with the emulation thread and UserDefaults.
    /// 0 = unlimited, 1 = normal, n = fixed n×.
    var encoded: Int32 {
        switch self {
        case .normal: 1
        case .fixed(let multiplier): Int32(multiplier)
        case .unlimited: 0
        }
    }

    init(encoded: Int32) {
        switch encoded {
        case 0: self = .unlimited
        case 1: self = .normal
        default: self = .fixed(Int(encoded))
        }
    }

    var label: String {
        switch self {
        case .normal: "1x"
        case .fixed(let multiplier): "\(multiplier)x"
        case .unlimited: "∞"
        }
    }
}

/// Fast-forward state. Mutated on the main thread; the emulation thread
/// reads the effective mode through `modeForEmulation()`.
@Observable
final class SpeedController {
    private(set) var baseMode: SpeedMode = .normal
    private(set) var isHolding = false
    var holdMode: SpeedMode = .fixed(4) {
        didSet { publish() }
    }

    var effectiveMode: SpeedMode {
        isHolding ? holdMode : baseMode
    }

    @ObservationIgnored private let shared: UnsafeMutablePointer<Int32>

    init() {
        shared = .allocate(capacity: 1)
        shared.initialize(to: SpeedMode.normal.encoded)
    }

    deinit {
        shared.deallocate()
    }

    /// Cycles 1x → 2x → 4x → unlimited → 1x.
    func cycleToggle() {
        let cycle = SpeedMode.toggleCycle
        let index = cycle.firstIndex(of: baseMode) ?? 0
        baseMode = cycle[(index + 1) % cycle.count]
        publish()
    }

    func setHolding(_ holding: Bool) {
        guard holding != isHolding else { return }
        isHolding = holding
        publish()
    }

    private func publish() {
        gbemu_atomic_store_i32(shared, effectiveMode.encoded)
    }

    /// Safe to call from any thread.
    func modeForEmulation() -> SpeedMode {
        SpeedMode(encoded: gbemu_atomic_load_i32(shared))
    }
}
