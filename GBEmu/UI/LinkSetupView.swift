import SwiftUI

/// Picks P2's ROM and shows which battery save P2 will use, then plugs in
/// the link cable.
struct LinkSetupView: View {
    let session: EmulatorSession

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var p2ROM: ROMEntry?
    @State private var errorMessage: String?

    private var selectedROM: ROMEntry { p2ROM ?? session.rom }

    private var slot: BatterySlot {
        BatterySlot.forLinkPartner(rom: selectedROM, p1ROM: session.rom)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("P2 遊戲", selection: Binding(get: { selectedROM }, set: { p2ROM = $0 })) {
                        ForEach(appState.library.roms) { rom in
                            Text(rom.name).tag(rom)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("P1 繼續執行「\(session.rom.name)」。兩台在同一支手機上透過模擬的通信線連接。")
                }

                Section("P2 存檔") {
                    saveDescription
                }

                Section {
                    Button("開始連線", systemImage: "cable.connector", action: connect)
                } footer: {
                    Text("連線期間無法使用即時存檔。用畫面上的 P1／P2 切換鈕決定要操作哪一台，未顯示的那台會繼續執行。")
                }
            }
            .navigationTitle("連線模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("無法開始連線", isPresented: .constant(errorMessage != nil)) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var saveDescription: some View {
        let store = session.batteryStore
        let fileName = store.url(for: slot).lastPathComponent
        if let date = store.modificationDate(of: slot) {
            LabeledContent("沿用現有存檔") {
                Text(date.formatted(date: .abbreviated, time: .shortened))
            }
            if let existing = store.existingURL(for: slot), existing.lastPathComponent != fileName {
                Text("讀取自 \(existing.lastPathComponent)，之後寫入 \(fileName)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(fileName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("尚無存檔，將建立新檔")
            Text(fileName)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if slot.player == .p1 {
            Text("P2 執行不同的遊戲時，使用該遊戲的主要存檔。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func connect() {
        do {
            try session.enterLinkMode(p2ROM: selectedROM)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
