import Foundation
import SameBoyCore

/// Owns a SameBoy `GB_gameboy_t` instance. This is the only type in the app
/// that calls the SameBoy C API directly.
///
/// Every C callback finds its owning instance through `GB_get_user_data`, so
/// any number of cores can coexist (one per player in link-cable mode).
///
/// Threading: the instance may be configured on any thread before it is
/// handed to the emulation loop; after that it must only be touched from the
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

    /// Link-cable partner. Not retained: the session keeps both cores alive
    /// and always disconnects before releasing either of them.
    private unowned(unsafe) var linkPartner: EmulatorCore?
    /// Bit this core clocked out at the start of the current serial bit.
    private var linkBit = true

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
        // The loop does its own pacing and drives the core with GB_run().
        // Uncapped turbo without frame skipping keeps SameBoy's internal
        // timekeeping from sleeping; these are exactly the settings
        // GB_run_frame() applies temporarily.
        GB_set_turbo_mode(gb, true, true)
        GB_set_turbo_cap(gb, 0)

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

    /// Whether frames completed from now on are rendered and published. When
    /// false the PPU skips pixel output (used for fast-forward).
    func setRender(_ render: Bool) {
        if render != renderingEnabled {
            GB_set_rendering_disabled(gb, !render)
            renderingEnabled = render
        }
        publishCurrentFrame = render
    }

    /// Runs `cores` (one, or two linked players) in lock step until each has
    /// completed at least one more frame, always advancing the core with the
    /// least accumulated time in `cycles` (8 MHz ticks, parallel to `cores`).
    /// Returns the largest clock gap seen between the cores.
    static func runFrameLockstep(_ cores: [EmulatorCore], cycles: inout [UInt64]) -> UInt64 {
        precondition((1...2).contains(cores.count) && cycles.count == cores.count)
        let gbs: [UnsafeMutablePointer<GB_gameboy_t>?] = cores.map(\.gb)
        return gbs.withUnsafeBufferPointer { gbs in
            cycles.withUnsafeMutableBufferPointer { cycles in
                gbemu_run_frame_lockstep(gbs.baseAddress, cycles.baseAddress, UInt32(gbs.count))
            }
        }
    }

    // MARK: - Link cable

    /// Connects this core's serial port to `partner` and vice versa.
    /// Emulation thread only.
    func connectLink(to partner: EmulatorCore) {
        linkPartner = partner
        partner.linkPartner = self
        linkBit = true
        partner.linkBit = true
        for core in [self, partner] {
            GB_set_serial_transfer_bit_start_callback(core.gb) { gb, bit in
                EmulatorCore.from(gb)?.linkBit = bit
            }
            GB_set_serial_transfer_bit_end_callback(core.gb) { gb in
                EmulatorCore.from(gb)?.linkBitEnd() ?? true
            }
        }
    }

    /// Unplugs the cable from both ends. Emulation thread only.
    func disconnectLink() {
        guard let partner = linkPartner else { return }
        GB_disconnect_serial(gb)
        GB_disconnect_serial(partner.gb)
        partner.linkPartner = nil
        linkPartner = nil
    }

    /// Same exchange as SameBoy's Cocoa and libretro front ends: read the
    /// partner's outgoing bit, shift ours into it, return what we received.
    private func linkBitEnd() -> Bool {
        guard let partner = linkPartner else { return true }
        let received = GB_serial_get_data_bit(partner.gb)
        GB_serial_set_data_bit(partner.gb, linkBit)
        return received
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
