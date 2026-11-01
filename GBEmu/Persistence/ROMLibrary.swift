import Foundation
import Observation
import UniformTypeIdentifiers

/// Well-known folders inside Documents (visible in the Files app).
enum AppDirectories {
    static let documents = URL.documentsDirectory
    static let roms = documents.appending(path: "ROMs", directoryHint: .isDirectory)
    static let saves = documents.appending(path: "Saves", directoryHint: .isDirectory)
    static let states = documents.appending(path: "States", directoryHint: .isDirectory)

    static func createAll() {
        for url in [roms, saves, states] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

extension UTType {
    static let gameBoyROM = UTType(importedAs: "com.jywang.gbemu.gb-rom")
    static let gameBoyColorROM = UTType(importedAs: "com.jywang.gbemu.gbc-rom")
}

struct ROMEntry: Identifiable, Hashable {
    let url: URL

    var id: URL { url }
    /// File name without extension; also the key for saves and states.
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isColor: Bool { url.pathExtension.lowercased() == "gbc" }
}

/// ROMs stored in `Documents/ROMs/`.
@Observable
final class ROMLibrary {
    static let supportedExtensions: Set<String> = ["gb", "gbc"]

    private(set) var roms: [ROMEntry] = []

    init() {
        AppDirectories.createAll()
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppDirectories.roms,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        roms = urls
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map(ROMEntry.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copies picked files into the library. Returns names that failed.
    @discardableResult
    func importROMs(from urls: [URL]) -> [String] {
        var failures: [String] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else {
                failures.append(source.lastPathComponent)
                continue
            }
            let destination = AppDirectories.roms.appending(path: source.lastPathComponent)
            do {
                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: .atomic)
            } catch {
                failures.append(source.lastPathComponent)
            }
        }
        refresh()
        return failures
    }

    func delete(_ rom: ROMEntry) {
        try? FileManager.default.removeItem(at: rom.url)
        refresh()
    }
}
