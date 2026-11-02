import Foundation

/// Identifies one battery save file: `Documents/Saves/<rom name>.<P1|P2>.sav`.
///
/// P1 files fall back to the pre-link-cable `<rom name>.sav` when no `.P1.sav`
/// exists yet. The legacy file is only ever read, never modified or deleted.
struct BatterySlot: Hashable {
    let romName: String
    let player: Player

    /// The save a link-cable P2 uses: its own `.P2.sav` when it runs the same
    /// ROM as P1, otherwise that ROM's regular (P1) save.
    static func forLinkPartner(rom: ROMEntry, p1ROM: ROMEntry) -> BatterySlot {
        BatterySlot(romName: rom.name, player: rom == p1ROM ? .p2 : .p1)
    }
}

/// Battery-backed SRAM saves in `Documents/Saves/`.
final class BatterySaveStore {
    private let queue = DispatchQueue(label: "BatterySaveStore", qos: .utility)

    /// Where `slot` is written.
    func url(for slot: BatterySlot) -> URL {
        AppDirectories.saves.appending(path: "\(slot.romName).\(slot.player.label).sav")
    }

    /// Pre-link-cable location, read as a fallback for P1.
    func legacyURL(romName: String) -> URL {
        AppDirectories.saves.appending(path: "\(romName).sav")
    }

    /// The file `load(_:)` would read, if any.
    func existingURL(for slot: BatterySlot) -> URL? {
        let fileManager = FileManager.default
        let primary = url(for: slot)
        if fileManager.fileExists(atPath: primary.path) {
            return primary
        }
        if slot.player == .p1 {
            let legacy = legacyURL(romName: slot.romName)
            if fileManager.fileExists(atPath: legacy.path) {
                return legacy
            }
        }
        return nil
    }

    func load(_ slot: BatterySlot) -> Data? {
        existingURL(for: slot).flatMap { try? Data(contentsOf: $0) }
    }

    func modificationDate(of slot: BatterySlot) -> Date? {
        existingURL(for: slot).flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    /// Writes atomically on a background queue.
    func save(_ data: Data, to slot: BatterySlot) {
        let url = url(for: slot)
        queue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("BatterySaveStore: failed to write \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// Blocks until all pending writes have finished.
    func flush() {
        queue.sync {}
    }
}
