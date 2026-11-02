import Foundation
import Darwin

/// Drives every emulated Game Boy of a session on one dedicated thread with
/// its own clock.
///
/// Timing is independent of audio and display: each tick lasts one Game Boy
/// frame (~16.743 ms) and the speed controller decides how many emulated
/// frames run inside it. Only the last frame of a tick is rendered.
///
/// With two players (link cable) the cores advance in lock step: the loop
/// keeps each core's accumulated emulated time and always runs a short slice
/// on whichever core is behind, the same scheme SameBoy's own front ends use.
/// A single-player session is simply the one-core case of the same code.
final class EmulationLoop {
    /// Interval between periodic battery-save checks.
    static let batteryCheckInterval: TimeInterval = 30
    /// Time budget per tick for unlimited fast-forward.
    static let unlimitedBudget: TimeInterval = 0.014

    private let speed: SpeedController
    private let audioRing: AudioRingBuffer

    /// Called on the emulation thread with fresh SRAM contents when a game
    /// wrote to battery-backed RAM since the last check.
    var onBatteryChanged: ((PlayerInstance, Data) -> Void)?

    // Emulation-thread state (or any thread before `start()`).
    private var players: [PlayerInstance]
    /// Emulated time each player has run, in 8 MHz ticks. Parallel to `players`.
    private var cycles: [UInt64]

    private let lock = NSLock()
    private var commands: [(EmulationLoop) -> Void] = []
    private var paused = true
    private var stopRequested = false
    private var muteWhileFast = true
    private var activePlayer = Player.p1
    private let wakeup = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    private let ticksPerSecond: Double

    #if DEBUG
    /// Largest gap between the cores' clocks seen since the last log line.
    private var maxSkew: UInt64 = 0
    #endif

    init(player: PlayerInstance, speed: SpeedController, audioRing: AudioRingBuffer) {
        self.players = [player]
        self.cycles = [0]
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

    /// Selects whose audio is played. The ring buffer is flushed on change.
    func setActivePlayer(_ player: Player) {
        withLock { activePlayer = player }
    }

    /// Runs `block` on the emulation thread before the next frame. Runs it
    /// paused or not.
    func perform(_ block: @escaping (EmulationLoop) -> Void) {
        withLock { commands.append(block) }
        wakeup.signal()
    }

    /// Like `perform`, but blocks the caller until `block` has run. Runs it
    /// inline when the thread isn't running.
    func performAndWait(_ block: @escaping (EmulationLoop) -> Void) {
        guard thread != nil else {
            block(self)
            return
        }
        let done = DispatchSemaphore(value: 0)
        perform { loop in
            block(loop)
            done.signal()
        }
        done.wait()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.withLock(body)
    }

    // MARK: - Players (emulation thread, from `perform` blocks)

    /// Adds a player and resets the lock-step clocks so all cores start even.
    func attach(_ player: PlayerInstance) {
        players.append(player)
        cycles = Array(repeating: 0, count: players.count)
    }

    func detach(_ player: Player) {
        guard let index = players.firstIndex(where: { $0.player == player }) else { return }
        players.remove(at: index)
        cycles = Array(repeating: 0, count: players.count)
    }

    // MARK: - Emulation thread

    private func drainCommands() {
        let pending = withLock {
            let pending = commands
            commands.removeAll()
            return pending
        }
        for command in pending {
            command(self)
        }
    }

    /// Runs every core until each has completed at least one more frame,
    /// always advancing the core that has run the least emulated time.
    private func runFrameStep(render: Bool) {
        if players.count == 1 {
            // Fast path, equivalent to GB_run_frame().
            let core = players[0].core
            core.setRender(render)
            let target = core.vblankCount &+ 1
            while core.vblankCount != target {
                cycles[0] &+= core.runSlice()
            }
            return
        }

        for player in players {
            player.core.setRender(render)
        }
        let startCounts = players.map(\.core.vblankCount)
        var pending = players.count
        var finishedFrame = Array(repeating: false, count: players.count)
        while pending > 0 {
            var behind = 0
            for index in 1..<players.count where cycles[index] < cycles[behind] {
                behind = index
            }
            let core = players[behind].core
            cycles[behind] &+= core.runSlice()
            #if DEBUG
            let skew = (cycles.max() ?? 0) - (cycles.min() ?? 0)
            if skew > maxSkew { maxSkew = skew }
            #endif
            if !finishedFrame[behind], core.vblankCount != startCounts[behind] {
                finishedFrame[behind] = true
                pending -= 1
            }
        }
        // Keep the counters small; only their difference matters.
        let base = cycles.min() ?? 0
        for index in cycles.indices {
            cycles[index] -= base
        }
    }

    private func run() {
        let frameTicks = UInt64(ticksPerSecond / players[0].core.frameRate)
        let batteryCheckTicks = UInt64(ticksPerSecond * Self.batteryCheckInterval)
        let budgetTicks = UInt64(ticksPerSecond * Self.unlimitedBudget)

        var nextTick = mach_absolute_time()
        var nextBatteryCheck = nextTick + batteryCheckTicks
        var lastMode = SpeedMode.normal
        var lastActive = Player.p1
        var averageFrameTicks: UInt64 = frameTicks / 20
        #if DEBUG
        var nextSkewLog = nextTick
        #endif

        while true {
            drainCommands()
            let (paused, stop, mute, active) = withLock { (self.paused, stopRequested, muteWhileFast, activePlayer) }
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
            for player in players {
                player.core.setKeys(player.buttons.current)
            }

            let mode = speed.modeForEmulation()
            if mode != lastMode || active != lastActive {
                if mode == .normal || active != lastActive {
                    // Drop audio queued while fast-forwarding (so latency doesn't
                    // build up) or produced by the previously selected player.
                    audioRing.requestFlush()
                }
                lastMode = mode
                lastActive = active
            }
            let audible = mode == .normal || !mute
            for player in players {
                player.core.audioEnabled = audible && player.player == active
            }

            switch mode {
            case .normal:
                runFrameStep(render: true)
            case .fixed(let multiplier):
                for index in 0..<multiplier {
                    runFrameStep(render: index == multiplier - 1)
                }
            case .unlimited:
                let deadline = tickStart + budgetTicks
                while mach_absolute_time() + averageFrameTicks * 2 < deadline {
                    let frameStart = mach_absolute_time()
                    runFrameStep(render: false)
                    // Exponential moving average of the cost of one skipped frame step.
                    averageFrameTicks = (averageFrameTicks * 7 + (mach_absolute_time() - frameStart)) / 8
                }
                runFrameStep(render: true)
            }

            let now = mach_absolute_time()
            #if DEBUG
            if players.count > 1, now >= nextSkewLog {
                nextSkewLog = now + UInt64(ticksPerSecond)
                print("EmulationLoop: link max clock skew \(maxSkew) ticks (8 MHz), mode \(mode.label)")
                maxSkew = 0
            }
            #endif
            if now >= nextBatteryCheck {
                nextBatteryCheck = now + batteryCheckTicks
                for player in players where player.core.isBatteryDirty {
                    if let data = player.core.batteryData() {
                        onBatteryChanged?(player, data)
                    }
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
