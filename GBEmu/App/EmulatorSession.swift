import Foundation
import Observation

/// Everything needed to play: one emulated Game Boy per player (P1 only, or
/// P1 + P2 joined by a link cable), the shared emulation thread, audio, input
/// routing and persistence. Created when a game opens and torn down when it
/// closes. Single-player is simply a session with one player.
@Observable
final class EmulatorSession {
    enum SessionError: LocalizedError {
        case missingBootROM
        case unreadableROM(Error)

        var errorDescription: String? {
            switch self {
            case .missingBootROM: "找不到內建的 boot ROM（cgb_boot.bin）。"
            case .unreadableROM(let error): "無法讀取 ROM：\(error.localizedDescription)"
            }
        }
    }

    /// P1's ROM; the game this session was opened with.
    let rom: ROMEntry
    let speed: SpeedController
    let controllers: GameControllerInput

    /// P1, plus P2 while linked.
    private(set) var players: [PlayerInstance]
    /// The player that receives touch / controller input and whose audio plays.
    private(set) var activePlayer: Player = .p1

    /// Paused by the user (menu, sheets) as opposed to by the system.
    private(set) var isPausedByUser = false
    @ObservationIgnored private var isPausedBySystem = false
    @ObservationIgnored private var isRunning = false

    @ObservationIgnored private let bootROM: Data
    @ObservationIgnored private let audioRing: AudioRingBuffer
    @ObservationIgnored private let loop: EmulationLoop
    @ObservationIgnored private let audio: AudioOutput
    @ObservationIgnored let batteryStore: BatterySaveStore
    @ObservationIgnored let stateStore = SaveStateStore()

    var isLinked: Bool { players.count > 1 }

    var active: PlayerInstance {
        instance(activePlayer) ?? players[0]
    }

    func instance(_ player: Player) -> PlayerInstance? {
        players.first { $0.player == player }
    }

    init(rom: ROMEntry) throws {
        guard let bootURL = Bundle.main.url(forResource: "cgb_boot", withExtension: "bin"),
              let bootROM = try? Data(contentsOf: bootURL) else {
            throw SessionError.missingBootROM
        }
        let speed = SpeedController()
        let batteryStore = BatterySaveStore()
        let ring = AudioRingBuffer(sampleRate: EmulatorCore.sampleRate)
        let p1 = try Self.makeInstance(
            player: .p1,
            rom: rom,
            batterySlot: BatterySlot(romName: rom.name, player: .p1),
            bootROM: bootROM,
            audioRing: ring,
            batteryStore: batteryStore
        )

        self.rom = rom
        self.bootROM = bootROM
        self.speed = speed
        self.batteryStore = batteryStore
        self.audioRing = ring
        players = [p1]
        audio = AudioOutput(ring: ring, sampleRate: EmulatorCore.sampleRate)
        loop = EmulationLoop(player: p1, speed: speed, audioRing: ring)
        controllers = GameControllerInput(target: p1.buttons)

        loop.onBatteryChanged = { player, data in
            batteryStore.save(data, to: player.batterySlot)
        }
        controllers.onHoldFastChanged = { [weak self] holding in
            self?.speed.setHolding(holding)
        }
        controllers.onToggleFast = { [weak self] in
            self?.speed.cycleToggle()
        }
    }

    private static func makeInstance(
        player: Player,
        rom: ROMEntry,
        batterySlot: BatterySlot,
        bootROM: Data,
        audioRing: AudioRingBuffer,
        batteryStore: BatterySaveStore
    ) throws -> PlayerInstance {
        let romData: Data
        do {
            romData = try Data(contentsOf: rom.url)
        } catch {
            throw SessionError.unreadableROM(error)
        }
        let frameBuffer = FrameBuffer()
        let core = EmulatorCore(bootROM: bootROM, frameBuffer: frameBuffer, audioRing: audioRing)
        core.loadROM(romData)
        if let battery = batteryStore.load(batterySlot) {
            core.loadBattery(battery)
        }
        return PlayerInstance(
            player: player,
            rom: rom,
            batterySlot: batterySlot,
            core: core,
            frameBuffer: frameBuffer,
            buttons: ButtonState()
        )
    }

    // MARK: - Lifecycle (main thread)

    func start(settings: AppSettings) {
        guard !isRunning else { return }
        isRunning = true
        apply(settings)
        audio.start(category: settings.audioCategory)
        loop.start()
        updatePaused()
    }

    /// Saves SRAM of every player and stops everything. The session cannot be restarted.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        saveBattery()
        loop.stop()
        batteryStore.flush()
        audio.stop()
        releaseAllButtons()
    }

    func apply(_ settings: AppSettings) {
        speed.holdMode = settings.holdSpeed
        loop.setMuteWhileFast(settings.muteWhileFast)
    }

    func setAudioCategory(_ category: AudioCategoryOption) {
        audio.setCategory(category)
    }

    func setPausedByUser(_ paused: Bool) {
        isPausedByUser = paused
        updatePaused()
    }

    /// App went to background / became inactive. Pauses every player.
    func setPausedBySystem(_ paused: Bool) {
        isPausedBySystem = paused
        updatePaused()
    }

    private func updatePaused() {
        guard isRunning else { return }
        let paused = isPausedByUser || isPausedBySystem
        if paused {
            releaseAllButtons()
            speed.setHolding(false)
            saveBattery()
        }
        loop.setPaused(paused)
    }

    private func releaseAllButtons() {
        for player in players {
            player.buttons.releaseAll()
        }
    }

    /// Resets the selected player's Game Boy.
    func reset() {
        let core = active.core
        loop.perform { _ in core.reset() }
    }

    // MARK: - Player selection & link cable (main thread)

    /// Routes input and audio to `player`. The other player keeps running.
    func setActivePlayer(_ player: Player) {
        guard player != activePlayer, let target = instance(player) else { return }
        active.buttons.releaseAll()
        activePlayer = player
        controllers.target = target.buttons
        loop.setActivePlayer(player)
    }

    /// Creates P2 running `p2ROM` and plugs the link cable into both players.
    /// P2 uses `BatterySlot.forLinkPartner`: an existing save is reused,
    /// otherwise it starts from blank SRAM and the file is created on first save.
    func enterLinkMode(p2ROM: ROMEntry) throws {
        guard !isLinked else { return }
        let p2 = try Self.makeInstance(
            player: .p2,
            rom: p2ROM,
            batterySlot: BatterySlot.forLinkPartner(rom: p2ROM, p1ROM: rom),
            bootROM: bootROM,
            audioRing: audioRing,
            batteryStore: batteryStore
        )
        let p1Core = players[0].core
        loop.perform { loop in
            loop.attach(p2)
            p1Core.connectLink(to: p2.core)
        }
        players.append(p2)
    }

    /// Unplugs the cable, writes P2's save, then releases P2.
    func exitLinkMode() {
        guard let p2 = instance(.p2) else { return }
        setActivePlayer(.p1)
        p2.buttons.releaseAll()
        let batteryStore = batteryStore
        loop.performAndWait { loop in
            p2.core.disconnectLink()
            if p2.core.hasBattery, let data = p2.core.batteryData() {
                batteryStore.save(data, to: p2.batterySlot)
            }
            loop.detach(.p2)
        }
        batteryStore.flush()
        players.removeAll { $0.player == .p2 }
    }

    // MARK: - Saves

    /// Writes the battery save of every player.
    func saveBattery() {
        let batteryStore = batteryStore
        for player in players {
            loop.perform { _ in
                guard player.core.hasBattery, let data = player.core.batteryData() else { return }
                batteryStore.save(data, to: player.batterySlot)
            }
        }
    }

    /// Save states are single-player only: restoring one Game Boy mid-transfer
    /// would desynchronise the link.
    var canUseSaveStates: Bool { !isLinked }

    func saveState(slot: Int, completion: @escaping (Bool) -> Void) {
        guard canUseSaveStates else {
            completion(false)
            return
        }
        let player = players[0]
        let thumbnail = SaveStateStore.thumbnailPNG(from: player.frameBuffer.snapshot())
        let store = stateStore
        let romName = rom.name
        loop.perform { _ in
            let state = player.core.saveState()
            let success = (try? store.save(state: state, thumbnail: thumbnail, romName: romName, slot: slot)) != nil
            DispatchQueue.main.async { completion(success) }
        }
    }

    func loadState(slot: Int, completion: @escaping (Bool) -> Void) {
        guard canUseSaveStates, let data = stateStore.load(romName: rom.name, slot: slot) else {
            completion(false)
            return
        }
        let core = players[0].core
        loop.perform { _ in
            let success = core.loadState(data)
            DispatchQueue.main.async { completion(success) }
        }
    }
}
