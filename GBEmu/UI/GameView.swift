import SwiftUI

struct GameView: View {
    let rom: ROMEntry

    private enum Sheet: String, Identifiable {
        case saveState
        case loadState
        case settings
        case linkSetup

        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: EmulatorSession?
    @State private var loadError: String?
    @State private var sheet: Sheet?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                GameLayout(session: session, menu: menu)
            }
        }
        // Keep the system status bar (time, battery) visible; dark scheme
        // gives it light content over the black background.
        .preferredColorScheme(.dark)
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
            case .linkSetup:
                if let session { LinkSetupView(session: session) }
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
            let isLinked = session?.isLinked == true
            Button(action: { present(.saveState) }) {
                Label("即時存檔", systemImage: "square.and.arrow.down")
                if isLinked { Text("連線模式下無法使用即時存檔") }
            }
            .disabled(isLinked)
            Button(action: { present(.loadState) }) {
                Label("讀取存檔", systemImage: "square.and.arrow.up")
                if isLinked { Text("連線模式下無法使用即時存檔") }
            }
            .disabled(isLinked)
            Button(isLinked ? "重置 \(session?.activePlayer.label ?? "")" : "重置", systemImage: "arrow.counterclockwise") {
                session?.reset()
            }
            Divider()
            if isLinked {
                Button("結束連線", systemImage: "cable.connector.slash") { session?.exitLinkMode() }
            } else {
                Button("連線模式…", systemImage: "cable.connector") { present(.linkSetup) }
            }
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
            let session = try EmulatorSession(rom: rom)
            session.start(settings: settings)
            self.session = session
            #if DEBUG
            // Development aid: `-autolink <ROM name>` enters link mode right away.
            if let name = UserDefaults.standard.string(forKey: "autolink"),
               let p2ROM = appState.library.roms.first(where: { $0.name == name }) {
                try? session.enterLinkMode(p2ROM: p2ROM)
            }
            #endif
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

/// Portrait: screen(s) on top, controls below; when linked both players are
/// stacked. Landscape: the selected player's screen centered, controls at
/// both sides. Players that aren't shown keep running.
private struct GameLayout<MenuContent: View>: View {
    let session: EmulatorSession
    let menu: MenuContent
    @Environment(AppSettings.self) private var settings

    private var showsTouchControls: Bool {
        !(settings.hideTouchControlsWithController && session.controllers.isConnected)
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                ZStack {
                    screen(for: session.active)
                        .id(session.activePlayer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsTouchControls {
                        touchControls(layout: .landscape)
                            .ignoresSafeArea()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        playerSwitch
                        menu
                    }
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        playerSwitch
                            .padding(.leading, 8)
                        Spacer()
                        menu
                    }
                    if session.isLinked {
                        VStack(spacing: 6) {
                            ForEach(session.players, id: \.player) { player in
                                screen(for: player)
                                    .overlay {
                                        if player.player == session.activePlayer {
                                            Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 2)
                                        }
                                    }
                                    .onTapGesture { session.setActivePlayer(player.player) }
                            }
                        }
                        .frame(maxHeight: geometry.size.height * 0.56)
                        .padding(.horizontal, 8)
                    } else {
                        screen(for: session.active)
                            .padding(.horizontal, 8)
                    }
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

    @ViewBuilder
    private var playerSwitch: some View {
        if session.isLinked {
            PlayerSwitch(selection: session.activePlayer) { session.setActivePlayer($0) }
        }
    }

    private func screen(for player: PlayerInstance) -> some View {
        ScreenView(frameBuffer: player.frameBuffer)
            .aspectRatio(10.0 / 9.0, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                SpeedBadge(mode: session.speed.effectiveMode)
            }
            .overlay(alignment: .bottomLeading) {
                if session.isLinked {
                    Badge(text: player.player.label)
                }
            }
    }

    private func touchControls(layout: TouchControlsView.Layout) -> some View {
        TouchControls(
            buttons: session.active.buttons,
            layout: layout,
            style: settings.touchControlStyle,
            opacity: settings.buttonOpacity,
            hapticsEnabled: settings.hapticsEnabled,
            speedLabel: session.speed.baseMode.label,
            onToggleFast: { session.speed.cycleToggle() }
        )
    }
}

/// "P1 | P2" toggle selecting which player receives input and plays audio.
private struct PlayerSwitch: View {
    let selection: Player
    let select: (Player) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Player.allCases) { player in
                Button {
                    select(player)
                } label: {
                    Text(player.label)
                        .font(.subheadline.bold())
                        .foregroundStyle(player == selection ? .black : .white)
                        .frame(width: 40, height: 28)
                        .background(player == selection ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.2), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目前操作的玩家")
    }
}

private struct SpeedBadge: View {
    let mode: SpeedMode

    var body: some View {
        if mode != .normal {
            Badge(text: "▶▶ \(mode.label)")
        }
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)
            .allowsHitTesting(false)
    }
}
