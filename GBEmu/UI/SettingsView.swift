import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("按住加速倍率", selection: $settings.holdSpeed) {
                        ForEach(SpeedMode.holdChoices, id: \.self) { mode in
                            Text(mode == .unlimited ? "無上限" : mode.label).tag(mode)
                        }
                    }
                    Toggle("加速時靜音", isOn: $settings.muteWhileFast)
                } header: {
                    Text("倍速")
                } footer: {
                    Text("切換加速按鈕會在 1x → 2x → 4x → 無上限 之間循環。")
                }

                Section("音訊") {
                    Picker("音訊模式", selection: $settings.audioCategory) {
                        Text("混音（不打斷音樂）").tag(AudioCategoryOption.ambient)
                        Text("播放（忽略靜音鍵）").tag(AudioCategoryOption.playback)
                    }
                }

                Section {
                    Picker("按鍵配置", selection: $settings.touchControlStyle) {
                        ForEach(TouchControlStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Toggle("觸覺回饋", isOn: $settings.hapticsEnabled)
                    VStack(alignment: .leading) {
                        Text("按鍵透明度：\(Int(settings.buttonOpacity * 100))%")
                        Slider(value: $settings.buttonOpacity, in: 0.15...1)
                    }
                    Toggle("連接手把時隱藏觸控按鍵", isOn: $settings.hideTouchControlsWithController)
                } header: {
                    Text("按鍵")
                } footer: {
                    Text("單手模式：A、B 並排於右上方，縮小的十字鍵位於右下方，方便右手拇指單手操作。")
                }

                Section {
                    LabeledContent("右肩鍵 / 右板機", value: "按住加速")
                    LabeledContent("左肩鍵", value: "切換加速")
                    LabeledContent("右側面板鍵", value: "A")
                    LabeledContent("下方面板鍵", value: "B")
                    LabeledContent("Menu / Options", value: "Start / Select")
                } header: {
                    Text("手把配置")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
