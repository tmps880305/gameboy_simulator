import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @State private var importFailures: [String] = []

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Group {
                if appState.library.roms.isEmpty {
                    ContentUnavailableView {
                        Label("尚無遊戲", systemImage: "gamecontroller")
                    } description: {
                        Text("點右上角的「+」匯入 .gb 或 .gbc 檔案。")
                    } actions: {
                        Button("匯入 ROM") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(appState.library.roms) { rom in
                            Button {
                                appState.currentROM = rom
                            } label: {
                                HStack {
                                    Image(systemName: rom.isColor ? "gamecontroller.fill" : "gamecontroller")
                                        .foregroundStyle(rom.isColor ? .purple : .secondary)
                                    Text(rom.name)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                appState.library.delete(appState.library.roms[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("遊戲庫")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("設定", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("匯入", systemImage: "plus") { isImporting = true }
                }
            }
            .refreshable { appState.library.refresh() }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.gameBoyROM, .gameBoyColorROM],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                importFailures = appState.library.importROMs(from: urls)
            }
        }
        .alert("部分檔案匯入失敗", isPresented: .constant(!importFailures.isEmpty)) {
            Button("好") { importFailures = [] }
        } message: {
            Text(importFailures.joined(separator: "\n"))
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .fullScreenCover(item: $appState.currentROM) { rom in
            GameView(rom: rom)
        }
        #if DEBUG
        .onAppear {
            // Development aid: launch with `-autoplay <ROM name>` to open a game directly.
            if let name = UserDefaults.standard.string(forKey: "autoplay") {
                appState.currentROM = appState.library.roms.first { $0.name == name }
            }
        }
        #endif
    }
}
