import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("API 키") {
                SecureField("OpenAI 또는 OpenRouter 키", text: $appState.apiKeyInput)
                Button("저장") { appState.saveAPIKey() }
                Text("Claude/Gemini는 OpenRouter 키(sk-or-…) 필요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("모델 (성능·비용)") {
                Picker("모델", selection: $appState.selectedModel) {
                    ForEach(SolvModelTier.allCases) { tier in
                        Section(tier.title) {
                            ForEach(SolvModel.models(for: tier)) { model in
                                Text(model.title).tag(model)
                            }
                        }
                    }
                }
                Text("기본은 Flash(저렴). 틀리면 균형→정확 순으로 올려보세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("단축키") {
                Text("Caps  ⌘⌥ 회색선 · ⌘⌥⌃ 선없음 · ⌘⌥C 전체")
                Text("마우스  ⌘⌃ 회색선 · ⌘⌥⌃Fn 선없음 · ⌘⌃C 전체")
                Text("클립보드  ⌘⇧ 회색선 · ⌘⇧⌥ 선없음 · ⌘⇧C 전체")
                Text("클립보드는 복사만 · Raycast는 직접 연 뒤 ⌘V")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("권한") {
                Button("화면 녹화 열기") { appState.openScreenRecordingSettings() }
                Button("손쉬운 사용 열기") { appState.openAccessibilitySettings() }
            }
        }
        .padding()
        .frame(width: 460, height: 380)
    }
}
