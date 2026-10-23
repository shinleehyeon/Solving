import Foundation

/// OpenRouter 비전(이미지) 모델 한 줄.
struct SolvRemoteModel: Identifiable, Hashable, Codable {
    /// OpenRouter slug 예: google/gemini-2.5-flash
    let id: String
    let name: String
    /// anthropic / google / openai …
    let provider: String
    let contextLength: Int?
    /// prompt 가격 (USD / token), 정렬·표시용
    let promptPrice: Double?

    var title: String { name }
    var shortTitle: String {
        // "Anthropic: Claude Sonnet 4.6" → "Claude Sonnet 4.6"
        if let r = name.split(separator: ":", maxSplits: 1).last {
            return r.trimmingCharacters(in: .whitespaces)
        }
        return name
    }
    var menuTitle: String { shortTitle }
}

/// OpenRouter 모델 목록 + 선택 상태.
@MainActor
final class SolvModelCatalog: ObservableObject {
    static let shared = SolvModelCatalog()

    static let defaultModelId = "google/gemini-2.5-flash"
    private static let selectedKey = "solvOpenRouterModelId"
    private static let cacheKey = "solvOpenRouterModelCache_v1"

    /// 메뉴바용 즐겨찾기 (항상 노출)
    static let favoriteIds: [String] = [
        "google/gemini-2.5-flash",
        "google/gemini-2.5-flash-lite",
        "google/gemini-2.5-pro",
        "anthropic/claude-haiku-4.5",
        "anthropic/claude-sonnet-4.6",
        "anthropic/claude-opus-4.8",
        "openai/gpt-4.1-mini",
        "openai/gpt-4.1",
        "openai/gpt-4o-mini",
        "openai/gpt-4o"
    ]

    /// 예전 enum rawValue → OpenRouter id
    private static let legacyMap: [String: String] = [
        "gemini25Flash": "google/gemini-2.5-flash",
        "gemini25FlashLite": "google/gemini-2.5-flash-lite",
        "claudeHaiku45": "anthropic/claude-haiku-4.5",
        "gpt41Mini": "openai/gpt-4.1-mini",
        "gpt4oMini": "openai/gpt-4o-mini",
        "claudeSonnet4": "anthropic/claude-sonnet-4.6",
        "gpt41": "openai/gpt-4.1",
        "gpt4o": "openai/gpt-4o",
        "gemini25Pro": "google/gemini-2.5-pro",
        "claudeOpus4": "anthropic/claude-opus-4.8"
    ]

    @Published private(set) var models: [SolvRemoteModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published var selectedId: String {
        didSet {
            UserDefaults.standard.set(selectedId, forKey: Self.selectedKey)
        }
    }

    var selectedModel: SolvRemoteModel {
        if let m = models.first(where: { $0.id == selectedId }) { return m }
        if let m = favorites.first(where: { $0.id == selectedId }) { return m }
        return SolvRemoteModel(
            id: selectedId,
            name: selectedId,
            provider: selectedId.split(separator: "/").first.map(String.init) ?? "other",
            contextLength: nil,
            promptPrice: nil
        )
    }

    var favorites: [SolvRemoteModel] {
        Self.favoriteIds.compactMap { id in
            models.first(where: { $0.id == id })
                ?? SolvRemoteModel(id: id, name: id, provider: id.split(separator: "/").first.map(String.init) ?? "other", contextLength: nil, promptPrice: nil)
        }
    }

    /// provider → models (이름 순)
    var groupedByProvider: [(provider: String, models: [SolvRemoteModel])] {
        let grouped = Dictionary(grouping: models, by: \.provider)
        return grouped.keys.sorted().map { key in
            (key, (grouped[key] ?? []).sorted { $0.shortTitle.localizedCaseInsensitiveCompare($1.shortTitle) == .orderedAscending })
        }
    }

    private init() {
        // 선택값 마이그레이션
        let raw = UserDefaults.standard.string(forKey: Self.selectedKey)
            ?? UserDefaults.standard.string(forKey: "solvModel")
            ?? Self.defaultModelId
        selectedId = Self.legacyMap[raw] ?? raw

        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([SolvRemoteModel].self, from: data),
           !cached.isEmpty {
            models = cached
        } else {
            models = Self.favoriteIds.map {
                SolvRemoteModel(
                    id: $0,
                    name: $0,
                    provider: $0.split(separator: "/").first.map(String.init) ?? "other",
                    contextLength: nil,
                    promptPrice: nil
                )
            }
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let url = URL(string: "https://openrouter.ai/api/v1/models")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            // 키가 있으면 붙여도 되고, 목록은 공개
            if let key = KeychainStore.loadAPIKey(), !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastError = "모델 목록 HTTP 오류"
                return
            }
            let parsed = try Self.parseVisionModels(from: data)
            guard !parsed.isEmpty else {
                lastError = "비전 모델이 비어 있음"
                return
            }
            models = parsed
            if let encoded = try? JSONEncoder().encode(parsed) {
                UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
            }
            // 선택 모델이 목록에 없으면 기본으로
            if !parsed.contains(where: { $0.id == selectedId }) {
                selectedId = Self.defaultModelId
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func parseVisionModels(from data: Data) throws -> [SolvRemoteModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else {
            return []
        }
        var out: [SolvRemoteModel] = []
        out.reserveCapacity(arr.count)
        for m in arr {
            guard let id = m["id"] as? String, !id.isEmpty else { continue }
            // 배치 API용은 채팅에 안 씀
            if id.contains(":batch") { continue }
            guard supportsImage(m) else { continue }
            let name = (m["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = id.split(separator: "/").first.map(String.init) ?? "other"
            // "~openai/..." 같은 가상 슬러그 정리
            let cleanProvider = provider.trimmingCharacters(in: CharacterSet(charactersIn: "~"))
            let ctx = m["context_length"] as? Int
            var price: Double?
            if let pricing = m["pricing"] as? [String: Any] {
                if let s = pricing["prompt"] as? String { price = Double(s) }
                else if let d = pricing["prompt"] as? Double { price = d }
            }
            out.append(
                SolvRemoteModel(
                    id: id,
                    name: (name?.isEmpty == false) ? name! : id,
                    provider: cleanProvider,
                    contextLength: ctx,
                    promptPrice: price
                )
            )
        }
        return out.sorted { $0.id < $1.id }
    }

    private static func supportsImage(_ m: [String: Any]) -> Bool {
        let arch = m["architecture"] as? [String: Any] ?? [:]
        if let mods = arch["input_modalities"] as? [String], mods.contains("image") {
            return true
        }
        if let modality = arch["modality"] as? String, modality.contains("image") {
            return true
        }
        return false
    }

    /// OpenAI 공식 키일 때: OpenRouter id → OpenAI model id (없으면 gpt-4.1-mini)
    nonisolated static func openAIFallback(forOpenRouterId id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("gpt-4.1-mini") { return "gpt-4.1-mini" }
        if lower.contains("gpt-4.1") { return "gpt-4.1" }
        if lower.contains("gpt-4o-mini") { return "gpt-4o-mini" }
        if lower.contains("gpt-4o") { return "gpt-4o" }
        if lower.contains("o4-mini") { return "o4-mini" }
        return "gpt-4.1-mini"
    }

    nonisolated static func resolvedId(openRouterId: String, forOpenRouter: Bool) -> String {
        forOpenRouter ? openRouterId : openAIFallback(forOpenRouterId: openRouterId)
    }
}

// MARK: - 하위 호환 (구 코드 참조용 별칭)

typealias SolvModel = SolvRemoteModel

enum SolvModelTier: String, CaseIterable, Identifiable {
    case favorites, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .favorites: return "즐겨찾기"
        case .all: return "전체 (설정에서 검색)"
        }
    }
}
