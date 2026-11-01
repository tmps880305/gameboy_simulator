import Foundation
import Darwin

/// Drives the emulator on a dedicated thread with its own clock.
///
/// Timing is independent of audio and display: each tick lasts one Game Boy
/// frame (~16.743 ms) and the speed controller decides how many emulated
/// frames run inside it. Only the last frame of a tick is rendered.
final class EmulationLoop {
    /// Interval between periodic battery-save checks.
    static let batteryCheckInterval: TimeInterval = 30
    /// Time budget per tick for unlimited fast-forward.
    static let unlimitedBudget: TimeInterval = 0.014

    private let core: EmulatorCore
    private let buttons: ButtonState
    private let speed: SpeedController
    private let audioRing: AudioRingBuffer

    /// Called on the emulation thread with fresh SRAM contents when the game
    /// wrote to battery-backed RAM since the last check.
    var onBatteryChanged: ((Data) -> Void)?

    private let lock = NSLock()
    private var commands: [(EmulatorCore) -> Void] = []
    private var paused = true
    private var stopRequested = false
    private var muteWhileFast = true
    private let wakeup = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    private let ticksPerSecond: Double

    init(core: EmulatorCore, buttons: ButtonState, speed: SpeedController, audioRing: AudioRingBuffer) {
        self.core = core
        self.buttons = buttons
        self.speed = speed
        self.audioRing = audioRing
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }

    // MARK: - Control (any thread)

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [self] in run() }
        thread.name = "Emulation"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops the thread after running any queued commands. Blocks until it exits.
    func stop() {
        guard thread != nil else { return }
        withLock { stopRequested = true }
        wakeup.signal()
        finished.wait()
        thread = nil
    }

    func setPaused(_ paused: Bool) {
        withLock { self.paused = paused }
        wakeup.signal()
    }

    func setMuteWhileFast(_ mute: Bool) {
        withLock { muteWhileFast = mute }
    }

    /// Runs `block` on the emulation thread before the next frame.
    func perform(_ block: @escaping (EmulatorCore) -> Void) {
        withLock { commands.append(block) }
        wakeup.signal()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.withLock(body)
    }

    // MARK: - Emulation thread

    private func drainCommands() {
        let pending = withLock {
            let pending = commands
            commands.removeAll()
            return pending
        }
        for command in pending {
            command(core)
        }
    }

    private func run() {
        let frameTicks = UInt64(ticksPerSecond / core.frameRate)
        let batteryCheckTicks = UInt64(ticksPerSecond * Self.batteryCheckInterval)
        let budgetTicks = UInt64(ticksPerSecond * Self.unlimitedBudget)

        var nextTick = mach_absolute_time()
        var nextBatteryCheck = nextTick + batteryCheckTicks
        var lastMode = SpeedMode.normal
        var averageFrameTicks: UInt64 = frameTicks / 20

        while true {
            drainCommands()
            let (paused, stop, mute) = withLock { (self.paused, stopRequested, muteWhileFast) }
            if stop {
                drainCommands()
                break
            }
            if paused {
                wakeup.wait()
                nextTick = mach_absolute_time()
                continue
            }

            let tickStart = mach_absolute_time()
            core.setKeys(buttons.current)

            let mode = speed.modeForEmulation()
            if mode != lastMode {
                if mode == .normal {
                    // Drop audio queued while fast-forwarding so latency doesn't build up.
                    audioRing.requestFlush()
                }
                lastMode = mode
            }
            core.audioEnabled = mode == .normal || !mute

            switch mode {
            case .normal:
                core.runFrame(render: true)
            case .fixed(let multiplier):
                for index in 0..<multiplier {
                    core.runFrame(render: index == multiplier - 1)
                }
            case .unlimited:
                let deadline = tickStart + budgetTicks
                while mach_absolute_time() + averageFrameTicks * 2 < deadline {
                    let frameStart = mach_absolute_time()
                    core.runFrame(render: false)
                    // Exponential moving average of the cost of one skipped frame.
                    averageFrameTicks = (averageFrameTicks * 7 + (mach_absolute_time() - frameStart)) / 8
                }
                core.runFrame(render: true)
            }

            let now = mach_absolute_time()
            if now >= nextBatteryCheck {
                nextBatteryCheck = now + batteryCheckTicks
                if core.isBatteryDirty, let data = core.batteryData() {
                    onBatteryChanged?(data)
                }
            }

            nextTick += frameTicks
            if now > nextTick + frameTicks * 4 {
                // Fell far behind (e.g. the thread was suspended); resync instead of catching up.
                nextTick = now
            } else if nextTick > now {
                mach_wait_until(nextTick)
            }
        }
        finished.signal()
    }
}
