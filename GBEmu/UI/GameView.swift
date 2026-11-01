import SwiftUI

struct GameView: View {
    let rom: ROMEntry

    private enum Sheet: String, Identifiable {
        case saveState
        case loadState
        case settings

        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: GameSession?
    @State private var loadError: String?
    @State private var sheet: Sheet?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                GameLayout(session: session, menu: menu)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: startSession)
        .onDisappear { session?.stop() }
        .onChange(of: scenePhase) { _, phase in
            session?.setPausedBySystem(phase != .active)
        }
        .onChange(of: settings.holdSpeed) { session?.apply(settings) }
        .onChange(of: settings.muteWhileFast) { session?.apply(settings) }
        .onChange(of: settings.audioCategory) { _, category in
            session?.setAudioCategory(category)
        }
        .sheet(item: $sheet, onDismiss: { session?.setPausedByUser(false) }) { sheet in
            switch sheet {
            case .saveState:
                if let session { SaveStatesView(session: session, mode: .save) }
            case .loadState:
                if let session { SaveStatesView(session: session, mode: .load) }
            case .settings:
                SettingsView()
            }
        }
        .alert("無法開啟遊戲", isPresented: .constant(loadError != nil)) {
            Button("好") {
                loadError = nil
                appState.currentROM = nil
            }
        } message: {
            Text(loadError ?? "")
        }
    }

    private var menu: some View {
        Menu {
            Button("即時存檔", systemImage: "square.and.arrow.down") { present(.saveState) }
            Button("讀取存檔", systemImage: "square.and.arrow.up") { present(.loadState) }
            Button("重置", systemImage: "arrow.counterclockwise") { session?.reset() }
            Button("設定", systemImage: "gearshape") { present(.settings) }
            Divider()
            Button("返回遊戲庫", systemImage: "chevron.backward") { close() }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .padding(8)
                .contentShape(Rectangle())
        }
    }

    private func startSession() {
        guard session == nil else { return }
        do {
            let session = try GameSession(rom: rom)
            session.start(settings: settings)
            self.session = session
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func present(_ sheet: Sheet) {
        session?.setPausedByUser(true)
        self.sheet = sheet
    }

    private func close() {
        session?.stop()
        appState.currentROM = nil
    }
}

/// Portrait: screen on top, controls below. Landscape: screen centered,
/// controls at both sides.
private struct GameLayout<MenuContent: View>: View {
    let session: GameSession
    let menu: MenuContent
    @Environment(AppSettings.self) private var settings

    private var showsTouchControls: Bool {
        !(settings.hideTouchControlsWithController && session.controllers.isConnected)
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                ZStack {
                    screen
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsTouchControls {
                        touchControls(layout: .landscape)
                            .ignoresSafeArea()
                    }
                }
                .overlay(alignment: .topTrailing) { menu }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        menu
                    }
                    screen
                        .padding(.horizontal, 8)
                    if showsTouchControls {
                        touchControls(layout: .portrait)
                            .ignoresSafeArea(edges: .bottom)
                    } else {
                        Spacer()
                    }
                }
            }
        }
    }

    private var screen: some View {
        ScreenView(frameBuffer: session.frameBuffer)
            .aspectRatio(10.0 / 9.0, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                SpeedBadge(mode: session.speed.effectiveMode)
            }
    }

    private func touchControls(layout: TouchControlsView.Layout) -> some View {
        TouchControls(
            buttons: session.buttons,
            layout: layout,
            opacity: settings.buttonOpacity,
            hapticsEnabled: settings.hapticsEnabled,
            onHoldFastChanged: { session.speed.setHolding($0) },
            onToggleFast: { session.speed.cycleToggle() }
        )
    }
}

private struct SpeedBadge: View {
    let mode: SpeedMode

    var body: some View {
        if mode != .normal {
            Text("▶▶ \(mode.label)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(6)
                .allowsHitTesting(false)
        }
    }
}
