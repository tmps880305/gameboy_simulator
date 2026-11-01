import SwiftUI

/// Grid of save-state slots used for both saving and loading.
struct SaveStatesView: View {
    enum Mode {
        case save
        case load
    }

    let session: GameSession
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var slots: [SaveStateSlot] = []
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(slots) { slot in
                        Button {
                            select(slot)
                        } label: {
                            SlotCell(slot: slot)
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking || (mode == .load && slot.isEmpty))
                    }
                }
                .padding()
            }
            .navigationTitle(mode == .save ? "即時存檔" : "讀取存檔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("操作失敗", isPresented: .constant(errorMessage != nil)) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        slots = session.stateStore.slots(romName: session.rom.name)
    }

    private func select(_ slot: SaveStateSlot) {
        isWorking = true
        switch mode {
        case .save:
            session.saveState(slot: slot.index) { success in
                isWorking = false
                if success { dismiss() } else { errorMessage = "無法寫入存檔。" }
            }
        case .load:
            session.loadState(slot: slot.index) { success in
                isWorking = false
                if success { dismiss() } else { errorMessage = "存檔損毀或與此 ROM 不相容。" }
            }
        }
    }
}

private struct SlotCell: View {
    let slot: SaveStateSlot

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle().fill(Color.black)
                if let thumbnail = slot.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .interpolation(.none)
                } else {
                    Text("空白")
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(10.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("欄位 \(slot.index + 1)")
                .font(.headline)
            Text(slot.date?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
