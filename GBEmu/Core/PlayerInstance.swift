import Foundation

/// Which emulated Game Boy a value belongs to. Single-player sessions only
/// have `.p1`; link-cable sessions have both.
enum Player: Int, CaseIterable, Identifiable {
    case p1
    case p2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .p1: "P1"
        case .p2: "P2"
        }
    }
}

/// One emulated Game Boy and everything that belongs to it exclusively:
/// its core, frame buffer, button state and battery save location.
final class PlayerInstance {
    let player: Player
    let rom: ROMEntry
    let batterySlot: BatterySlot
    let core: EmulatorCore
    let frameBuffer: FrameBuffer
    let buttons: ButtonState

    init(player: Player, rom: ROMEntry, batterySlot: BatterySlot, core: EmulatorCore, frameBuffer: FrameBuffer, buttons: ButtonState) {
        self.player = player
        self.rom = rom
        self.batterySlot = batterySlot
        self.core = core
        self.frameBuffer = frameBuffer
        self.buttons = buttons
    }
}
