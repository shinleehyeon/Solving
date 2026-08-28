import AppKit
import Foundation

/// Raycast를 강제 실행하지 않음.
/// 답을 클립보드에 넣어 두면, 사용자가 Raycast를 연 뒤 ⌘V 로 넣을 수 있음.
enum RaycastTyper {
    enum Outcome: Equatable {
        case ok
        case emptyText
    }

    /// 답을 일반 클립보드에 복사 (앱 실행/포커스 변경 없음).
    @discardableResult
    static func putAnswerReady(_ text: String) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)

        // Raycast가 가끔 별도 히스토리를 보는 경우를 위해 한 번 더 명시
        pb.declareTypes([.string], owner: nil)
        pb.setString(trimmed, forType: .string)

        return .ok
    }

    /// 하위 호환: 예전 openAndType 호출부 → 클립보드만
    @discardableResult
    static func openAndType(
        _ text: String,
        openDelayMs: UInt64 = 0,
        charDelayMs: UInt64 = 0
    ) async -> Outcome {
        _ = openDelayMs
        _ = charDelayMs
        return putAnswerReady(text)
    }
}
