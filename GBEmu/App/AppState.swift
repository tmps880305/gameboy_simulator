import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    private enum Key {
        static let holdSpeed = "holdSpeed"
        static let muteWhileFast = "muteWhileFast"
        static let hapticsEnabled = "hapticsEnabled"
        static let audioCategory = "audioCategory"
        static let buttonOpacity = "buttonOpacity"
        static let hideTouchControlsWithController = "hideTouchControlsWithController"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var holdSpeed: SpeedMode {
        didSet { defaults.set(Int(holdSpeed.encoded), forKey: Key.holdSpeed) }
    }
    var muteWhileFast: Bool {
        didSet { defaults.set(muteWhileFast, forKey: Key.muteWhileFast) }
    }
    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }
    var audioCategory: AudioCategoryOption {
        didSet { defaults.set(audioCategory.rawValue, forKey: Key.audioCategory) }
    }
    var buttonOpacity: Double {
        didSet { defaults.set(buttonOpacity, forKey: Key.buttonOpacity) }
    }
    var hideTouchControlsWithController: Bool {
        didSet { defaults.set(hideTouchControlsWithController, forKey: Key.hideTouchControlsWithController) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.holdSpeed: Int(SpeedMode.fixed(4).encoded),
            Key.muteWhileFast: true,
            Key.hapticsEnabled: true,
            Key.audioCategory: AudioCategoryOption.ambient.rawValue,
            Key.buttonOpacity: 0.6,
            Key.hideTouchControlsWithController: true,
        ])
        holdSpeed = SpeedMode(encoded: Int32(defaults.integer(forKey: Key.holdSpeed)))
        muteWhileFast = defaults.bool(forKey: Key.muteWhileFast)
        hapticsEnabled = defaults.bool(forKey: Key.hapticsEnabled)
        audioCategory = AudioCategoryOption(rawValue: defaults.string(forKey: Key.audioCategory) ?? "") ?? .ambient
        buttonOpacity = defaults.double(forKey: Key.buttonOpacity)
        hideTouchControlsWithController = defaults.bool(forKey: Key.hideTouchControlsWithController)
    }
}

/// App-wide state: settings, the ROM library and the game being played.
@Observable
final class AppState {
    let settings = AppSettings()
    let library = ROMLibrary()
    var currentROM: ROMEntry?
}
