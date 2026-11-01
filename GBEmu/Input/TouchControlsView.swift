import SwiftUI
import UIKit

/// Arrangement of the on-screen buttons.
enum TouchControlStyle: String, CaseIterable, Identifiable {
    /// D-pad on the left, A/B on the right, like the original hardware.
    case standard
    /// Everything reachable with the right thumb: A/B side by side up top,
    /// a smaller D-pad in the bottom-right corner.
    case oneHanded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "標準"
        case .oneHanded: "單手模式"
        }
    }
}

/// SwiftUI wrapper around `TouchControlsView`.
struct TouchControls: UIViewRepresentable {
    let buttons: ButtonState
    var layout: TouchControlsView.Layout
    var style: TouchControlStyle
    var opacity: Double
    var hapticsEnabled: Bool
    var onHoldFastChanged: (Bool) -> Void
    var onToggleFast: () -> Void

    func makeUIView(context: Context) -> TouchControlsView {
        TouchControlsView(buttons: buttons)
    }

    func updateUIView(_ view: TouchControlsView, context: Context) {
        view.layout = layout
        view.style = style
        view.controlOpacity = opacity
        view.hapticsEnabled = hapticsEnabled
        view.onHoldFastChanged = onHoldFastChanged
        view.onToggleFast = onToggleFast
    }

    static func dismantleUIView(_ view: TouchControlsView, coordinator: ()) {
        view.releaseAll()
    }
}

/// Multi-touch virtual Game Boy controls.
///
/// Every touch is assigned to the control it started on. The D-pad keeps
/// tracking its touch while the finger slides (including diagonals), and a
/// touch that started on A or B can slide between the two.
final class TouchControlsView: UIView {
    enum Layout {
        /// Controls fill the area below the screen.
        case portrait
        /// Controls sit in columns at both sides of a centered screen.
        case landscape
    }

    private enum Control: Hashable {
        case dpad
        case button(GBButton)
        case holdFast
        case toggleFast
    }

    var layout: Layout = .portrait {
        didSet { if layout != oldValue { setNeedsLayout() } }
    }
    var style: TouchControlStyle = .standard {
        didSet { if style != oldValue { setNeedsLayout() } }
    }
    var controlOpacity: Double = 0.6 {
        didSet { updateAppearance() }
    }
    var hapticsEnabled = true
    var onHoldFastChanged: ((Bool) -> Void)?
    var onToggleFast: (() -> Void)?

    private let buttons: ButtonState
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private let dpadView = DPadView()
    private let aView = RoundButtonView(title: "A")
    private let bView = RoundButtonView(title: "B")
    private let selectView = PillButtonView(title: "SELECT")
    private let startView = PillButtonView(title: "START")
    private let holdFastView = PillButtonView(title: "▶▶ 按住")
    private let toggleFastView = PillButtonView(title: "▶▶ 切換")

    private var touchControls: [UITouch: Control] = [:]
    private var touchButtons: [UITouch: GBButton] = [:]
    private var pressed: GBButton = []
    private var holdingFast = false

    init(buttons: ButtonState) {
        self.buttons = buttons
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        for view in allControlViews {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var allControlViews: [UIView] {
        [dpadView, aView, bView, selectView, startView, holdFastView, toggleFastView]
    }

    private func updateAppearance() {
        for view in allControlViews {
            view.alpha = controlOpacity
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        switch (layout, style) {
        case (.portrait, .standard): layoutPortrait()
        case (.landscape, .standard): layoutLandscape()
        case (.portrait, .oneHanded): layoutPortraitOneHanded()
        case (.landscape, .oneHanded): layoutLandscapeOneHanded()
        }
    }

    private func layoutPortrait() {
        let b = bounds.inset(by: UIEdgeInsets(top: 8, left: 16, bottom: max(safeAreaInsets.bottom, 12), right: 16))
        let pillSize = CGSize(width: 76, height: 28)

        holdFastView.frame = CGRect(origin: CGPoint(x: b.minX, y: b.minY), size: pillSize)
        toggleFastView.frame = CGRect(origin: CGPoint(x: b.maxX - pillSize.width, y: b.minY), size: pillSize)

        let dpadSize = min(b.width * 0.42, b.height * 0.62, 180)
        let centerY = b.minY + pillSize.height + (b.height - pillSize.height - pillSize.height - 16) / 2
        dpadView.frame = CGRect(x: b.minX, y: centerY - dpadSize / 2, width: dpadSize, height: dpadSize)

        layoutFaceButtons(rightEdge: b.maxX, centerY: centerY, size: dpadSize)

        let startSelectY = b.maxY - pillSize.height
        selectView.frame = CGRect(x: b.midX - pillSize.width - 8, y: startSelectY, width: pillSize.width, height: pillSize.height)
        startView.frame = CGRect(x: b.midX + 8, y: startSelectY, width: pillSize.width, height: pillSize.height)
    }

    private func layoutLandscape() {
        let b = bounds.inset(by: UIEdgeInsets(top: 12, left: max(safeAreaInsets.left, 16), bottom: max(safeAreaInsets.bottom, 12), right: max(safeAreaInsets.right, 16)))
        // Screen is 10:9 and as tall as the view; controls use what's left on each side.
        let screenWidth = bounds.height * 10 / 9
        let columnWidth = max((bounds.width - screenWidth) / 2 - b.minX, 120)
        let pillSize = CGSize(width: min(76, columnWidth - 8), height: 28)
        let dpadSize = min(columnWidth - 8, b.height * 0.5, 170)
        let centerY = b.midY

        dpadView.frame = CGRect(x: b.minX, y: centerY - dpadSize / 2, width: dpadSize, height: dpadSize)
        layoutFaceButtons(rightEdge: b.maxX, centerY: centerY, size: dpadSize)

        holdFastView.frame = CGRect(origin: CGPoint(x: b.minX, y: b.minY), size: pillSize)
        toggleFastView.frame = CGRect(origin: CGPoint(x: b.maxX - pillSize.width, y: b.minY), size: pillSize)
        selectView.frame = CGRect(origin: CGPoint(x: b.minX, y: b.maxY - pillSize.height), size: pillSize)
        startView.frame = CGRect(origin: CGPoint(x: b.maxX - pillSize.width, y: b.maxY - pillSize.height), size: pillSize)
    }

    private func layoutPortraitOneHanded() {
        let b = bounds.inset(by: UIEdgeInsets(top: 8, left: 16, bottom: max(safeAreaInsets.bottom, 12), right: 16))
        let pillSize = CGSize(width: 76, height: 28)

        holdFastView.frame = CGRect(origin: CGPoint(x: b.minX, y: b.minY), size: pillSize)
        toggleFastView.frame = CGRect(origin: CGPoint(x: b.maxX - pillSize.width, y: b.minY), size: pillSize)

        let standardDpad = min(b.width * 0.42, b.height * 0.62, 180)
        let cluster = CGRect(x: b.minX + pillSize.width + 16, y: b.minY + pillSize.height + 12,
                             width: b.width - pillSize.width - 16, height: b.height - pillSize.height - 12)
        layoutOneHandedCluster(in: cluster, standardDpad: standardDpad)

        // Start/Select stacked just left of the D-pad, within reach of the thumb
        // but clear of the D-pad's touch slop.
        let startSelectX = max(b.minX, dpadView.frame.minX - 32 - pillSize.width)
        startView.frame = CGRect(origin: CGPoint(x: startSelectX, y: b.maxY - pillSize.height), size: pillSize)
        selectView.frame = CGRect(origin: CGPoint(x: startSelectX, y: startView.frame.minY - 12 - pillSize.height), size: pillSize)
    }

    private func layoutLandscapeOneHanded() {
        let b = bounds.inset(by: UIEdgeInsets(top: 12, left: max(safeAreaInsets.left, 16), bottom: max(safeAreaInsets.bottom, 12), right: max(safeAreaInsets.right, 16)))
        let screenWidth = bounds.height * 10 / 9
        let columnWidth = max((bounds.width - screenWidth) / 2 - b.minX, 120)
        let pillSize = CGSize(width: min(76, columnWidth - 8), height: 28)

        holdFastView.frame = CGRect(origin: CGPoint(x: b.minX, y: b.minY), size: pillSize)
        toggleFastView.frame = CGRect(origin: CGPoint(x: b.maxX - pillSize.width, y: b.minY), size: pillSize)
        startView.frame = CGRect(origin: CGPoint(x: b.minX, y: b.maxY - pillSize.height), size: pillSize)
        selectView.frame = CGRect(origin: CGPoint(x: b.minX, y: startView.frame.minY - 12 - pillSize.height), size: pillSize)

        let standardDpad = min(columnWidth - 8, b.height * 0.5, 170)
        let cluster = CGRect(x: b.maxX - columnWidth, y: b.minY + pillSize.height + 12,
                             width: columnWidth, height: b.height - pillSize.height - 12)
        layoutOneHandedCluster(in: cluster, standardDpad: standardDpad)
    }

    /// One-handed cluster: a smaller D-pad in the bottom-right corner of
    /// `region`, with B and A side by side just above it.
    private func layoutOneHandedCluster(in region: CGRect, standardDpad: CGFloat) {
        let diameter = min(standardDpad * 0.4, region.width / 2.4, region.height * 0.3)
        let gap = diameter * 0.3
        let pairWidth = diameter * 2 + gap

        // Gap between A/B and the D-pad: close enough for the thumb, wide
        // enough that the D-pad's touch slop doesn't swallow A/B presses.
        let spacing: CGFloat = 28
        let dpadSize = max(min(standardDpad * 0.8, region.height - diameter - spacing, region.width), 60)
        let centerX = min(region.maxX - pairWidth / 2, region.maxX - dpadSize / 2)
        dpadView.frame = CGRect(x: centerX - dpadSize / 2, y: region.maxY - dpadSize, width: dpadSize, height: dpadSize)

        // A/B sit just above the D-pad rather than at the top of the region.
        let buttonY = max(region.minY, dpadView.frame.minY - spacing - diameter)
        aView.frame = CGRect(x: region.maxX - diameter, y: buttonY, width: diameter, height: diameter)
        bView.frame = CGRect(x: region.maxX - pairWidth, y: buttonY, width: diameter, height: diameter)
    }

    /// A and B on a diagonal, like the original hardware.
    private func layoutFaceButtons(rightEdge: CGFloat, centerY: CGFloat, size: CGFloat) {
        let diameter = size * 0.4
        aView.frame = CGRect(x: rightEdge - diameter, y: centerY - diameter * 0.85, width: diameter, height: diameter)
        bView.frame = CGRect(x: rightEdge - diameter * 2.15, y: centerY - diameter * 0.15, width: diameter, height: diameter)
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let control = control(at: touch.location(in: self)) else { continue }
            touchControls[touch] = control
            if control == .toggleFast {
                toggleFastView.isPressed = true
                onToggleFast?()
                playHaptic()
            }
        }
        update(touches: touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(touches: touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    func releaseAll() {
        touchControls.removeAll()
        touchButtons.removeAll()
        recompute()
    }

    private func end(_ touches: Set<UITouch>) {
        for touch in touches {
            if touchControls[touch] == .toggleFast {
                toggleFastView.isPressed = false
            }
            touchControls[touch] = nil
            touchButtons[touch] = nil
        }
        recompute()
    }

    private func update(touches: Set<UITouch>) {
        for touch in touches {
            guard let control = touchControls[touch] else { continue }
            let point = touch.location(in: self)
            switch control {
            case .dpad:
                touchButtons[touch] = dpadView.direction(at: convert(point, to: dpadView))
            case .button(let button) where button == .a || button == .b:
                // Allow sliding between A and B.
                if aView.hitFrame.contains(point) {
                    touchButtons[touch] = .a
                } else if bView.hitFrame.contains(point) {
                    touchButtons[touch] = .b
                } else if touchButtons[touch] == nil {
                    touchButtons[touch] = button
                }
            case .button(let button):
                touchButtons[touch] = button
            case .holdFast, .toggleFast:
                break
            }
        }
        recompute()
    }

    private func control(at point: CGPoint) -> Control? {
        if aView.hitFrame.contains(point) { return .button(.a) }
        if bView.hitFrame.contains(point) { return .button(.b) }
        if dpadView.frame.insetBy(dx: -24, dy: -24).contains(point) { return .dpad }
        if selectView.frame.insetBy(dx: -8, dy: -10).contains(point) { return .button(.select) }
        if startView.frame.insetBy(dx: -8, dy: -10).contains(point) { return .button(.start) }
        if holdFastView.frame.insetBy(dx: -8, dy: -10).contains(point) { return .holdFast }
        if toggleFastView.frame.insetBy(dx: -8, dy: -10).contains(point) { return .toggleFast }
        return nil
    }

    private func recompute() {
        let newPressed = touchButtons.values.reduce(into: GBButton()) { $0.formUnion($1) }
        if !newPressed.subtracting(pressed).isEmpty {
            playHaptic()
        }
        pressed = newPressed
        buttons.set(newPressed, from: .touch)

        dpadView.pressed = newPressed.intersection([.up, .down, .left, .right])
        aView.isPressed = newPressed.contains(.a)
        bView.isPressed = newPressed.contains(.b)
        selectView.isPressed = newPressed.contains(.select)
        startView.isPressed = newPressed.contains(.start)

        let holding = touchControls.values.contains(.holdFast)
        if holding != holdingFast {
            holdingFast = holding
            holdFastView.isPressed = holding
            if holding { playHaptic() }
            onHoldFastChanged?(holding)
        }
    }

    private func playHaptic() {
        guard hapticsEnabled else { return }
        haptics.impactOccurred()
    }
}

// MARK: - Control visuals

private let controlFill = UIColor(white: 0.25, alpha: 1)
private let controlPressedFill = UIColor(white: 0.55, alpha: 1)

private final class DPadView: UIView {
    var pressed: GBButton = [] {
        didSet { if pressed != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Maps a point to up to two directions using eight 45° sectors.
    func direction(at point: CGPoint) -> GBButton {
        let dx = point.x - bounds.midX
        let dy = bounds.midY - point.y
        let radius = bounds.width / 2
        guard hypot(dx, dy) > radius * 0.18 else { return [] }
        let sector = Int((atan2(dy, dx) / (.pi / 4)).rounded()) & 7
        switch sector {
        case 0: return [.right]
        case 1: return [.right, .up]
        case 2: return [.up]
        case 3: return [.left, .up]
        case 4: return [.left]
        case 5: return [.left, .down]
        case 6: return [.down]
        default: return [.right, .down]
        }
    }

    override func draw(_ rect: CGRect) {
        let arm = bounds.width / 3
        let arms: [(GBButton, CGRect)] = [
            (.up, CGRect(x: arm, y: 0, width: arm, height: arm)),
            (.down, CGRect(x: arm, y: arm * 2, width: arm, height: arm)),
            (.left, CGRect(x: 0, y: arm, width: arm, height: arm)),
            (.right, CGRect(x: arm * 2, y: arm, width: arm, height: arm)),
        ]
        controlFill.setFill()
        UIBezierPath(rect: CGRect(x: arm, y: arm, width: arm, height: arm)).fill()
        for (button, frame) in arms {
            (pressed.contains(button) ? controlPressedFill : controlFill).setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: arm * 0.15).fill()
        }
    }
}

private final class RoundButtonView: UIView {
    private let label = UILabel()

    var isPressed = false {
        didSet { backgroundColor = isPressed ? controlPressedFill : controlFill }
    }

    /// Generous touch target in superview coordinates.
    var hitFrame: CGRect {
        frame.insetBy(dx: -frame.width * 0.15, dy: -frame.height * 0.15)
    }

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = controlFill
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        label.frame = bounds
    }
}

private final class PillButtonView: UIView {
    private let label = UILabel()

    var isPressed = false {
        didSet { backgroundColor = isPressed ? controlPressedFill : controlFill }
    }

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = controlFill
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: 4, dy: 0)
    }
}
