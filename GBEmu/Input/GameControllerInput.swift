import GameController
import Observation

/// Maps extended-gamepad controllers (Bluetooth / MFi) to Game Boy buttons.
///
/// Face buttons are mapped by position: the right face button (B on Xbox,
/// A on Nintendo layouts) is the Game Boy A button, the bottom one is B.
/// Right shoulder/trigger = hold to fast-forward, left shoulder = cycle speed.
@Observable
final class GameControllerInput {
    private(set) var isConnected = false

    @ObservationIgnored var onHoldFastChanged: ((Bool) -> Void)?
    @ObservationIgnored var onToggleFast: (() -> Void)?

    /// Where controller input is sent. Changing it releases everything on
    /// the old target and re-sends the current pad state to the new one.
    @ObservationIgnored var target: ButtonState {
        didSet {
            guard target !== oldValue else { return }
            oldValue.set([], from: .controller)
            target.set(lastMask, from: .controller)
        }
    }
    @ObservationIgnored private var lastMask: GBButton = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var holdingFast = false
    @ObservationIgnored private var toggleWasPressed = false

    init(target: ButtonState) {
        self.target = target
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController {
                self?.configure(controller)
            }
            self?.refreshConnection()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConnection()
            self?.lastMask = []
            self?.target.set([], from: .controller)
        })
        GCController.controllers().forEach(configure)
        refreshConnection()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
    }

    private func refreshConnection() {
        isConnected = GCController.controllers().contains { $0.extendedGamepad != nil }
    }

    private func configure(_ controller: GCController) {
        controller.handlerQueue = .main
        controller.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, _ in
            self?.update(from: gamepad)
        }
    }

    private func update(from pad: GCExtendedGamepad) {
        var mask: GBButton = []
        let stick = pad.leftThumbstick
        if pad.dpad.up.isPressed || stick.yAxis.value > 0.5 { mask.insert(.up) }
        if pad.dpad.down.isPressed || stick.yAxis.value < -0.5 { mask.insert(.down) }
        if pad.dpad.left.isPressed || stick.xAxis.value < -0.5 { mask.insert(.left) }
        if pad.dpad.right.isPressed || stick.xAxis.value > 0.5 { mask.insert(.right) }
        if pad.buttonB.isPressed { mask.insert(.a) }
        if pad.buttonA.isPressed { mask.insert(.b) }
        if pad.buttonMenu.isPressed { mask.insert(.start) }
        if pad.buttonOptions?.isPressed == true { mask.insert(.select) }
        lastMask = mask
        target.set(mask, from: .controller)

        let holding = pad.rightShoulder.isPressed || pad.rightTrigger.isPressed
        if holding != holdingFast {
            holdingFast = holding
            onHoldFastChanged?(holding)
        }

        let toggle = pad.leftShoulder.isPressed
        if toggle && !toggleWasPressed {
            onToggleFast?()
        }
        toggleWasPressed = toggle
    }
}
