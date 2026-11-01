import Foundation

/// Battery-backed SRAM saves at `Documents/Saves/<rom name>.sav`.
final class BatterySaveStore {
    private let queue = DispatchQueue(label: "BatterySaveStore", qos: .utility)

    func url(for romName: String) -> URL {
        AppDirectories.saves.appending(path: "\(romName).sav")
    }

    func load(romName: String) -> Data? {
        try? Data(contentsOf: url(for: romName))
    }

    /// Writes atomically on a background queue.
    func save(_ data: Data, romName: String) {
        let url = url(for: romName)
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
