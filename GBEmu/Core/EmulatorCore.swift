import Foundation
import SameBoyCore

/// Owns a SameBoy `GB_gameboy_t` instance. This is the only type in the app
/// that calls the SameBoy C API directly.
///
/// Threading: the instance may be configured on any thread before the
/// emulation loop starts; after that it must only be touched from the
/// emulation thread (use `EmulationLoop.perform`).
final class EmulatorCore {
    static let screenWidth = 160
    static let screenHeight = 144
    static let sampleRate = 48_000

    private let gb: UnsafeMutablePointer<GB_gameboy_t>
    private let bootROM: Data
    private let frameBuffer: FrameBuffer
    private let audioRing: AudioRingBuffer

    /// Whether APU samples are forwarded to the audio ring buffer.
    var audioEnabled = true

    private var renderingEnabled = true
    private var publishCurrentFrame = true

    init(bootROM: Data, frameBuffer: FrameBuffer, audioRing: AudioRingBuffer) {
        self.gb = GB_init(GB_alloc(), GB_MODEL_CGB_E)
        self.bootROM = bootROM
        self.frameBuffer = frameBuffer
        self.audioRing = audioRing

        GB_set_user_data(gb, Unmanaged.passUnretained(self).toOpaque())
        GB_set_border_mode(gb, GB_BORDER_NEVER)
        GB_set_color_correction_mode(gb, GB_COLOR_CORRECTION_MODERN_BALANCED)
        GB_set_highpass_filter_mode(gb, GB_HIGHPASS_ACCURATE)
        GB_set_sample_rate(gb, UInt32(Self.sampleRate))
        GB_set_pixels_output(gb, frameBuffer.writeBuffer)

        // Pixels are stored as RGBA bytes in memory (MTLPixelFormat.rgba8Unorm).
        GB_set_rgb_encode_callback(gb) { _, r, g, b in
            UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
        }
        GB_set_vblank_callback(gb) { gb, type in
            EmulatorCore.from(gb)?.handleVBlank(type)
        }
        GB_apu_set_sample_callback(gb) { gb, sample in
            guard let sample, let core = EmulatorCore.from(gb), core.audioEnabled else { return }
            core.audioRing.write(left: sample.pointee.left, right: sample.pointee.right)
        }
        GB_set_boot_rom_load_callback(gb) { gb, _ in
            EmulatorCore.from(gb)?.loadBootROM()
        }
        loadBootROM()
    }

    deinit {
        GB_free(gb)
        GB_dealloc(gb)
    }

    private static func from(_ gb: UnsafeMutablePointer<GB_gameboy_t>?) -> EmulatorCore? {
        guard let gb, let userData = GB_get_user_data(gb) else { return nil }
        return Unmanaged<EmulatorCore>.fromOpaque(userData).takeUnretainedValue()
    }

    private func loadBootROM() {
        bootROM.withUnsafeBytes { raw in
            GB_load_boot_rom_from_buffer(gb, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    private func handleVBlank(_ type: GB_vblank_type_t) {
        // REPEAT frames should keep the previous image on screen.
        guard publishCurrentFrame, type != GB_VBLANK_TYPE_REPEAT else { return }
        GB_set_pixels_output(gb, frameBuffer.publish())
    }

    // MARK: - ROM & reset

    func loadROM(_ data: Data) {
        data.withUnsafeBytes { raw in
            GB_load_rom_from_buffer(gb, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        GB_reset(gb)
    }

    func reset() {
        GB_reset(gb)
    }

    var frameRate: Double {
        GB_get_usual_frame_rate(gb)
    }

    // MARK: - Running

    func setKeys(_ buttons: GBButton) {
        GB_set_key_mask(gb, GB_key_mask_t(rawValue: UInt32(buttons.rawValue)))
    }

    /// Runs the emulator until the next vblank. When `render` is false the PPU
    /// skips pixel output and the frame is not published (used for fast-forward).
    func runFrame(render: Bool) {
        if render != renderingEnabled {
            GB_set_rendering_disabled(gb, !render)
            renderingEnabled = render
        }
        publishCurrentFrame = render
        GB_run_frame(gb)
    }

    // MARK: - Battery save

    var hasBattery: Bool {
        GB_save_battery_size(gb) > 0
    }

    var isBatteryDirty: Bool {
        GB_get_battery_dirty(gb)
    }

    func batteryData() -> Data? {
        let size = Int(GB_save_battery_size(gb))
        guard size > 0 else { return nil }
        var data = Data(count: size)
        // Returns 0 on success, an errno value otherwise.
        let error = data.withUnsafeMutableBytes { raw in
            GB_save_battery_to_buffer(gb, raw.bindMemory(to: UInt8.self).baseAddress, size)
        }
        guard error == 0 else { return nil }
        GB_clear_battery_dirty(gb)
        return data
    }

    func loadBattery(_ data: Data) {
        data.withUnsafeBytes { raw in
            GB_load_battery_from_buffer(gb, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        GB_clear_battery_dirty(gb)
    }

    // MARK: - Save states

    func saveState() -> Data {
        let size = GB_get_save_state_size(gb)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            GB_save_state_to_buffer(gb, raw.bindMemory(to: UInt8.self).baseAddress)
        }
        return data
    }

    func loadState(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            GB_load_state_from_buffer(gb, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) == 0
        }
    }
}
