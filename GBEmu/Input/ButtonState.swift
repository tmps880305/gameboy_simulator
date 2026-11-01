import Foundation
import SameBoyCore

/// The eight Game Boy buttons. Bit order matches SameBoy's `GB_key_t`.
struct GBButton: OptionSet, Hashable {
    let rawValue: UInt8

    static let right  = GBButton(rawValue: 1 << 0)
    static let left   = GBButton(rawValue: 1 << 1)
    static let up     = GBButton(rawValue: 1 << 2)
    static let down   = GBButton(rawValue: 1 << 3)
    static let a      = GBButton(rawValue: 1 << 4)
    static let b      = GBButton(rawValue: 1 << 5)
    static let select = GBButton(rawValue: 1 << 6)
    static let start  = GBButton(rawValue: 1 << 7)
}

/// Thread-safe button state. Each input source owns its own mask so touch and
/// game controller input never overwrite each other; the emulation thread
/// reads the union.
final class ButtonState {
    enum Source: Int, CaseIterable {
        case touch
        case controller
    }

    private let masks: UnsafeMutablePointer<UInt32>

    init() {
        masks = .allocate(capacity: Source.allCases.count)
        masks.initialize(repeating: 0, count: Source.allCases.count)
    }

    deinit {
        masks.deallocate()
    }

    func set(_ buttons: GBButton, from source: Source) {
        gbemu_atomic_store_u32(masks + source.rawValue, UInt32(buttons.rawValue))
    }

    func releaseAll() {
        for source in Source.allCases {
            set([], from: source)
        }
    }

    var current: GBButton {
        var value: UInt32 = 0
        for source in Source.allCases {
            value |= gbemu_atomic_load_u32(masks + source.rawValue)
        }
        return GBButton(rawValue: UInt8(truncatingIfNeeded: value))
    }
}
