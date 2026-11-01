import Foundation
import SameBoyCore

/// Lock-free triple buffer for 160×144 RGBA frames.
///
/// The emulation thread writes into `writeBuffer` and calls `publish()` at
/// vblank. The render side (main thread) calls `acquireLatest()` to get the
/// newest complete frame. Neither side ever blocks the other.
final class FrameBuffer {
    static let width = EmulatorCore.screenWidth
    static let height = EmulatorCore.screenHeight
    static let pixelCount = width * height
    static let bytesPerRow = width * MemoryLayout<UInt32>.size

    private static let indexMask: UInt32 = 0b11
    private static let freshFlag: UInt32 = 0b100

    private let storage: UnsafeMutablePointer<UInt32>
    /// Index of the shared "middle" buffer plus `freshFlag` when it holds an unread frame.
    private let middle: UnsafeMutablePointer<UInt32>
    /// Owned by the writer.
    private var backIndex: UInt32 = 0
    /// Owned by the reader.
    private var frontIndex: UInt32 = 2

    init() {
        storage = .allocate(capacity: Self.pixelCount * 3)
        storage.initialize(repeating: 0xFFFF_FFFF, count: Self.pixelCount * 3)
        middle = .allocate(capacity: 1)
        middle.initialize(to: 1)
    }

    deinit {
        storage.deallocate()
        middle.deallocate()
    }

    private func buffer(_ index: UInt32) -> UnsafeMutablePointer<UInt32> {
        storage + Int(index) * Self.pixelCount
    }

    // MARK: Writer (emulation thread)

    var writeBuffer: UnsafeMutablePointer<UInt32> {
        buffer(backIndex)
    }

    /// Publishes the current write buffer and returns the next one to write into.
    func publish() -> UnsafeMutablePointer<UInt32> {
        let old = gbemu_atomic_exchange_u32(middle, backIndex | Self.freshFlag)
        backIndex = old & Self.indexMask
        return writeBuffer
    }

    // MARK: Reader (main thread)

    /// Returns the newest frame and whether it changed since the last call.
    func acquireLatest() -> (pixels: UnsafePointer<UInt32>, isNew: Bool) {
        if gbemu_atomic_load_u32(middle) & Self.freshFlag != 0 {
            let old = gbemu_atomic_exchange_u32(middle, frontIndex)
            frontIndex = old & Self.indexMask
            return (UnsafePointer(buffer(frontIndex)), true)
        }
        return (UnsafePointer(buffer(frontIndex)), false)
    }

    /// Copies the newest frame. Reader side only.
    func snapshot() -> [UInt32] {
        let pixels = acquireLatest().pixels
        return Array(UnsafeBufferPointer(start: pixels, count: Self.pixelCount))
    }
}
