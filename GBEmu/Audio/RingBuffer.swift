import Foundation
import SameBoyCore

/// Lock-free single-producer / single-consumer ring buffer of stereo Int16 frames.
///
/// Producer: the emulation thread (`write`, `requestFlush`).
/// Consumer: the audio render thread (`read`). The consumer side never
/// allocates, locks or calls into blocking APIs.
final class AudioRingBuffer {
    let capacity: Int
    private let mask: Int
    private let samples: UnsafeMutablePointer<Int16>
    /// [0] = total frames written, [1] = total frames read.
    private let counters: UnsafeMutablePointer<UInt64>
    private let flushRequested: UnsafeMutablePointer<UInt32>
    /// Consumer-owned: playback has buffered enough after an underrun.
    private let primed: UnsafeMutablePointer<Bool>

    /// Playback (re)starts once this many frames are buffered.
    let startThreshold: Int
    /// When more than this is buffered, the oldest frames are dropped...
    let maxLatency: Int
    /// ...down to this amount.
    let targetLatency: Int

    init(sampleRate: Int, capacity: Int = 8192) {
        precondition(capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        samples = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
        counters = .allocate(capacity: 2)
        counters.initialize(repeating: 0, count: 2)
        flushRequested = .allocate(capacity: 1)
        flushRequested.initialize(to: 0)
        primed = .allocate(capacity: 1)
        primed.initialize(to: false)

        startThreshold = sampleRate * 50 / 1000
        targetLatency = sampleRate * 60 / 1000
        maxLatency = sampleRate * 80 / 1000
    }

    deinit {
        samples.deallocate()
        counters.deallocate()
        flushRequested.deallocate()
        primed.deallocate()
    }

    // MARK: Producer

    func write(left: Int16, right: Int16) {
        let written = gbemu_atomic_load_u64(counters)
        let read = gbemu_atomic_load_u64(counters + 1)
        // Full: drop the new frame. The consumer trims old frames well before this.
        guard written &- read < UInt64(capacity) else { return }
        let slot = Int(written & UInt64(mask)) * 2
        samples[slot] = left
        samples[slot + 1] = right
        gbemu_atomic_store_u64(counters, written &+ 1)
    }

    /// Asks the consumer to discard everything buffered (e.g. after fast-forward).
    func requestFlush() {
        gbemu_atomic_store_u32(flushRequested, 1)
    }

    // MARK: Consumer

    /// Fills `frames` frames of non-interleaved float output. Missing frames are silence.
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let written = gbemu_atomic_load_u64(counters)
        var read = gbemu_atomic_load_u64(counters + 1)

        if gbemu_atomic_exchange_u32(flushRequested, 0) != 0 {
            read = written
            primed.pointee = false
        }

        var available = Int(written &- read)
        if !primed.pointee {
            if available >= startThreshold {
                primed.pointee = true
            } else {
                gbemu_atomic_store_u64(counters + 1, read)
                fillSilence(left: left, right: right, from: 0, to: frames)
                return
            }
        }

        if available > maxLatency {
            read = written &- UInt64(targetLatency)
            available = targetLatency
        }

        let count = min(frames, available)
        let scale: Float = 1.0 / 32768.0
        for i in 0..<count {
            let slot = Int((read &+ UInt64(i)) & UInt64(mask)) * 2
            left[i] = Float(samples[slot]) * scale
            right[i] = Float(samples[slot + 1]) * scale
        }
        if count < frames {
            // Underrun: wait for the buffer to refill before resuming.
            primed.pointee = false
            fillSilence(left: left, right: right, from: count, to: frames)
        }
        gbemu_atomic_store_u64(counters + 1, read &+ UInt64(count))
    }

    private func fillSilence(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, from: Int, to: Int) {
        guard to > from else { return }
        (left + from).update(repeating: 0, count: to - from)
        (right + from).update(repeating: 0, count: to - from)
    }
}
