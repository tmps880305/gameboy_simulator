import Foundation
import Observation

/// Everything needed to play one ROM: core, emulation thread, audio, input
/// and persistence. Created when a game opens and torn down when it closes.
@Observable
final class GameSession {
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

    let rom: ROMEntry
    let speed: SpeedController
    let buttons: ButtonState
    let frameBuffer: FrameBuffer
    let controllers: GameControllerInput

    /// Paused by the user (menu, sheets) as opposed to by the system.
    private(set) var isPausedByUser = false
    @ObservationIgnored private var isPausedBySystem = false
    @ObservationIgnored private var isRunning = false

    @ObservationIgnored private let core: EmulatorCore
    @ObservationIgnored private let loop: EmulationLoop
    @ObservationIgnored private let audio: AudioOutput
    @ObservationIgnored private let batteryStore: BatterySaveStore
    @ObservationIgnored let stateStore = SaveStateStore()

    init(rom: ROMEntry) throws {
        guard let bootURL = Bundle.main.url(forResource: "cgb_boot", withExtension: "bin"),
              let bootROM = try? Data(contentsOf: bootURL) else {
            throw SessionError.missingBootROM
        }
        let romData: Data
        do {
            romData = try Data(contentsOf: rom.url)
        } catch {
            throw SessionError.unreadableROM(error)
        }

        let frameBuffer = FrameBuffer()
        let buttons = ButtonState()
        let speed = SpeedController()
        let batteryStore = BatterySaveStore()
        let ring = AudioRingBuffer(sampleRate: EmulatorCore.sampleRate)
        let core = EmulatorCore(bootROM: bootROM, frameBuffer: frameBuffer, audioRing: ring)
        core.loadROM(romData)
        if let battery = batteryStore.load(romName: rom.name) {
            core.loadBattery(battery)
        }

        self.rom = rom
        self.frameBuffer = frameBuffer
        self.buttons = buttons
        self.speed = speed
        self.batteryStore = batteryStore
        self.core = core
        audio = AudioOutput(ring: ring, sampleRate: EmulatorCore.sampleRate)
        loop = EmulationLoop(core: core, buttons: buttons, speed: speed, audioRing: ring)
        controllers = GameControllerInput(buttons: buttons)

        let romName = rom.name
        loop.onBatteryChanged = { data in
            batteryStore.save(data, romName: romName)
        }
        controllers.onHoldFastChanged = { [weak self] holding in
            self?.speed.setHolding(holding)
        }
        controllers.onToggleFast = { [weak self] in
            self?.speed.cycleToggle()
        }
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

    /// Saves SRAM and stops everything. The session cannot be restarted.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        saveBattery()
        loop.stop()
        batteryStore.flush()
        audio.stop()
        buttons.releaseAll()
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

    /// App went to background / became inactive.
    func setPausedBySystem(_ paused: Bool) {
        isPausedBySystem = paused
        updatePaused()
    }

    private func updatePaused() {
        guard isRunning else { return }
        let paused = isPausedByUser || isPausedBySystem
        if paused {
            buttons.releaseAll()
            speed.setHolding(false)
            saveBattery()
        }
        loop.setPaused(paused)
    }

    func reset() {
        loop.perform { core in core.reset() }
    }

    // MARK: - Saves

    func saveBattery() {
        let batteryStore = batteryStore
        let romName = rom.name
        loop.perform { core in
            guard core.hasBattery, let data = core.batteryData() else { return }
            batteryStore.save(data, romName: romName)
        }
    }

    func saveState(slot: Int, completion: @escaping (Bool) -> Void) {
        let thumbnail = SaveStateStore.thumbnailPNG(from: frameBuffer.snapshot())
        let store = stateStore
        let romName = rom.name
        loop.perform { core in
            let state = core.saveState()
            let success = (try? store.save(state: state, thumbnail: thumbnail, romName: romName, slot: slot)) != nil
            DispatchQueue.main.async { completion(success) }
        }
    }

    func loadState(slot: Int, completion: @escaping (Bool) -> Void) {
        guard let data = stateStore.load(romName: rom.name, slot: slot) else {
            completion(false)
            return
        }
        loop.perform { core in
            let success = core.loadState(data)
            DispatchQueue.main.async { completion(success) }
        }
    }
}
