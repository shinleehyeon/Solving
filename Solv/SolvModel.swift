import Foundation

/// 성능/비용 티어 — 메뉴에서 구간별로 고름.
enum SolvModelTier: String, CaseIterable, Identifiable {
    case fast, balanced, accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "빠름 · 저렴"
        case .balanced: return "균형"
        case .accurate: return "정확 · 비쌈"
        }
    }
}

/// Vision용 모델. OpenRouter 키(sk-or-) 기준.
enum SolvModel: String, CaseIterable, Identifiable {
    // 빠름
    case gemini25Flash
    case gemini25FlashLite
    case claudeHaiku45
    case gpt41Mini
    case gpt4oMini
    // 균형
    case claudeSonnet4
    case gpt41
    case gpt4o
    // 정확
    case gemini25Pro
    case claudeOpus4

    var id: String { rawValue }

    var tier: SolvModelTier {
        switch self {
        case .gemini25Flash, .gemini25FlashLite, .claudeHaiku45, .gpt41Mini, .gpt4oMini:
            return .fast
        case .claudeSonnet4, .gpt41, .gpt4o:
            return .balanced
        case .gemini25Pro, .claudeOpus4:
            return .accurate
        }
    }

    var title: String {
        switch self {
        case .gemini25Flash: return "Gemini 2.5 Flash"
        case .gemini25FlashLite: return "Gemini 2.5 Flash Lite"
        case .claudeHaiku45: return "Claude Haiku 4.5"
        case .gpt41Mini: return "GPT-4.1 Mini"
        case .gpt4oMini: return "GPT-4o Mini"
        case .claudeSonnet4: return "Claude Sonnet 4"
        case .gpt41: return "GPT-4.1"
        case .gpt4o: return "GPT-4o"
        case .gemini25Pro: return "Gemini 2.5 Pro"
        case .claudeOpus4: return "Claude Opus 4"
        }
    }

    /// 메뉴/상태줄용: "빠름 · Gemini 2.5 Flash"
    var menuTitle: String { "\(tier.title) · \(title)" }

    /// OpenRouter model slug
    var openRouterId: String {
        switch self {
        case .gemini25Flash: return "google/gemini-2.5-flash"
        case .gemini25FlashLite: return "google/gemini-2.5-flash-lite"
        case .claudeHaiku45: return "anthropic/claude-haiku-4.5"
        case .gpt41Mini: return "openai/gpt-4.1-mini"
        case .gpt4oMini: return "openai/gpt-4o-mini"
        case .claudeSonnet4: return "anthropic/claude-sonnet-4"
        case .gpt41: return "openai/gpt-4.1"
        case .gpt4o: return "openai/gpt-4o"
        case .gemini25Pro: return "google/gemini-2.5-pro"
        case .claudeOpus4: return "anthropic/claude-opus-4"
        }
    }

    /// OpenAI 공식 API용 (Claude/Gemini는 같은 티어 GPT로 대체)
    var openAIId: String {
        switch self {
        case .gpt41: return "gpt-4.1"
        case .gpt4o: return "gpt-4o"
        case .gpt41Mini: return "gpt-4.1-mini"
        case .gpt4oMini: return "gpt-4o-mini"
        case .gemini25Flash, .gemini25FlashLite, .claudeHaiku45:
            return "gpt-4.1-mini"
        case .claudeSonnet4:
            return "gpt-4.1"
        case .gemini25Pro, .claudeOpus4:
            return "gpt-4.1"
        }
    }

    static func models(for tier: SolvModelTier) -> [SolvModel] {
        allCases.filter { $0.tier == tier }
    }

    /// 기본: 빠르고 저렴한 Flash
    static var current: SolvModel {
        get {
            let raw = UserDefaults.standard.string(forKey: "solvModel") ?? SolvModel.gemini25Flash.rawValue
            return SolvModel(rawValue: raw) ?? .gemini25Flash
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "solvModel")
        }
    }

    func resolvedId(forOpenRouter: Bool) -> String {
        forOpenRouter ? openRouterId : openAIId
    }
}
