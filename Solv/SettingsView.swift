import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var catalog = SolvModelCatalog.shared
    @State private var query = ""

    private var filteredGroups: [(provider: String, models: [SolvRemoteModel])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return catalog.groupedByProvider }
        return catalog.groupedByProvider.compactMap { group in
            let models = group.models.filter {
                $0.id.lowercased().contains(q)
                    || $0.name.lowercased().contains(q)
                    || $0.provider.lowercased().contains(q)
            }
            return models.isEmpty ? nil : (group.provider, models)
        }
    }

    var body: some View {
        Form {
            Section("API 키") {
                SecureField("OpenRouter sk-or-v1-… (권장)", text: $appState.apiKeyInput)
                HStack {
                    Button("저장·연결확인") { appState.saveAPIKey() }
                    Button("연결 테스트") {
                        Task { await appState.testAPIKey() }
                    }
                    Button("키 발급 페이지") { appState.openOpenRouterKeysPage() }
                }
                Text("User not found = 키 무효/삭제됨. openrouter.ai/keys 에서 새 키 발급")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("모델 검색 (이름·id·제공사)", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Button(catalog.isLoading ? "불러오는 중…" : "목록 새로고침") {
                        Task { await catalog.refresh() }
                    }
                    .disabled(catalog.isLoading)
                }
                Text("선택: \(catalog.selectedModel.shortTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("id: \(catalog.selectedId)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let err = catalog.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Text("이미지 입력 가능한 OpenRouter 모델 \(catalog.models.count)개 (:batch 제외)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 즐겨찾기
                Text("즐겨찾기").font(.headline)
                ForEach(catalog.favorites) { model in
                    modelRow(model)
                }

                // 전체 (제공사별)
                ForEach(filteredGroups, id: \.provider) { group in
                    Text(group.provider).font(.headline).padding(.top, 6)
                    ForEach(group.models) { model in
                        modelRow(model)
                    }
                }
            } header: {
                Text("모델 (OpenRouter 전체 · 비전)")
            }

            Section("단축키") {
                Text("손바닥  ⌘⌥ 선없음 · 커서 N번")
                Text("Caps  ⌘⌥⌃ 선없음 · ⌘⌥C 전체")
                Text("마우스 OCR  ⌘⌃ 회색선 · ⌘⌥⌃Fn 선없음 · ⌘⌃C 전체")
                Text("클립보드  ⌘⇧ 회색선 · ⌘⇧⌥ 선없음 · ⌘⇧C 전체")
                Text("클립보드+설명  ⌘⌥⌃Fn⇧ 선없음 · 정답·모든 선지·설명 복사")
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
        .frame(width: 560, height: 640)
        .task {
            if catalog.models.count < 20 {
                await catalog.refresh()
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: SolvRemoteModel) -> some View {
        Button {
            catalog.selectedId = model.id
            appState.statusText = "모델: \(model.shortTitle)"
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.shortTitle)
                    Text(model.id)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.id == catalog.selectedId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
