import AppKit
import SwiftUI

/// RunCat 러너 분류. (분류표는 바이너리에서 복원하지 못해 이름·색 기준으로 추정한 것)
enum RunnerCategory: CaseIterable {
    case basic, animal, inanimate, special, seasonal

    var title: String {
        switch self {
        case .basic: "기본 러너"
        case .animal: "동물 러너"
        case .inanimate: "무생물 러너"
        case .special: "특별 컬러 러너"
        case .seasonal: "계절한정 러너"
        }
    }

    private static let basicOrder = [
        "cat", "cat-b", "cat-c", "cat-tail", "mock-nyan-cat", "parrot", "human", "push-up", "sit-up", "dogeza",
    ]
    private static let seasonalIDs: Set<String> = ["jack-o-lantern", "reindeer-sleigh", "snowman", "sparkler", "wind-chime"]
    private static let animalIDs: Set<String> = [
        "bird", "butterfly", "chameleon", "cheetah", "chicken", "dog", "dolphin", "dragon", "fishman", "fox", "frog",
        "greyhound", "hedgehog", "horse", "mouse", "octopus", "otter", "owl", "penguin", "penguin2", "pig", "puppy",
        "rabbit", "sheep", "squirrel", "terrier", "welsh-corgi", "whale",
    ]

    static func of(_ r: Runner) -> RunnerCategory {
        if basicOrder.contains(r.id) { return .basic }
        if seasonalIDs.contains(r.id) { return .seasonal }
        if !r.template { return .special }  // 색이 있는 러너
        return animalIDs.contains(r.id) ? .animal : .inanimate
    }

    var runners: [Runner] {
        let list = Runner.all.filter { Self.of($0) == self }
        if self == .basic {
            return Self.basicOrder.compactMap { id in list.first { $0.id == id } }
        }
        return list
    }
}

/// RunCat 같은 러너 선택 창: 분류별 둥근 카드, 이름 + 미리보기. 높이는 maxHeight 로 제한하고 스크롤.
struct RunnerPicker: View {
    static let width: CGFloat = 340
    static let maxHeight: CGFloat = 380

    @State private var selected = CatAnimator.shared.style

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(RunnerCategory.allCases, id: \.self) { cat in
                    let runners = cat.runners
                    if !runners.isEmpty {
                        RCCard {
                            RCSectionLabel(cat.title)
                            ForEach(Array(runners.enumerated()), id: \.element.id) { i, runner in
                                if i > 0 { RCDivider() }
                                RunnerRow(runner: runner, isSelected: runner == selected) {
                                    CatAnimator.shared.style = runner
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width, height: Self.maxHeight)
        .onReceive(CatAnimator.shared.$style) { selected = $0 }
    }
}

private struct RunnerRow: View {
    let runner: Runner
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    private var frames: [NSImage] { CatAnimator.frames(of: runner) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Circle()
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(width: 13, height: 13)
                Text(runner.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                preview
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.07) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// 평소엔 첫 프레임, 마우스를 올리면 움직인다.
    @ViewBuilder private var preview: some View {
        if hovering {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let i = Int(ctx.date.timeIntervalSinceReferenceDate * 10) % max(frames.count, 1)
                image(frames[i])
            }
        } else {
            image(frames[0])
        }
    }

    private func image(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .renderingMode(runner.template ? .template : .original)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(height: 28)
    }
}
