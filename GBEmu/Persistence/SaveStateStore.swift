import Foundation
import UIKit

struct SaveStateSlot: Identifiable {
    let index: Int
    let date: Date?
    let thumbnail: UIImage?

    var id: Int { index }
    var isEmpty: Bool { date == nil }
}

/// Save states at `Documents/States/<rom name>.<slot>.state`, each with a
/// `<rom name>.<slot>.png` thumbnail next to it.
final class SaveStateStore {
    static let slotCount = 4

    func stateURL(romName: String, slot: Int) -> URL {
        AppDirectories.states.appending(path: "\(romName).\(slot).state")
    }

    func thumbnailURL(romName: String, slot: Int) -> URL {
        AppDirectories.states.appending(path: "\(romName).\(slot).png")
    }

    func slots(romName: String) -> [SaveStateSlot] {
        (0..<Self.slotCount).map { slot in
            let url = stateURL(romName: romName, slot: slot)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let thumbnail = date == nil ? nil : UIImage(contentsOfFile: thumbnailURL(romName: romName, slot: slot).path)
            return SaveStateSlot(index: slot, date: date, thumbnail: thumbnail)
        }
    }

    func save(state: Data, thumbnail: Data?, romName: String, slot: Int) throws {
        try state.write(to: stateURL(romName: romName, slot: slot), options: .atomic)
        if let thumbnail {
            try thumbnail.write(to: thumbnailURL(romName: romName, slot: slot), options: .atomic)
        }
    }

    func load(romName: String, slot: Int) -> Data? {
        try? Data(contentsOf: stateURL(romName: romName, slot: slot))
    }

    /// Encodes RGBA pixels from `FrameBuffer` as PNG.
    static func thumbnailPNG(from pixels: [UInt32]) -> Data? {
        let width = FrameBuffer.width
        let height = FrameBuffer.height
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: FrameBuffer.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
