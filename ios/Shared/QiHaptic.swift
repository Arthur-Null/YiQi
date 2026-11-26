import UIKit

// 按键震动：主 App 里的预览和键盘里的按键用同一套档位，试到的手感就是打字时的手感。
// 三档的样式和力度都拉开（不用 .soft：在真机上弱到几乎感觉不到）。
final class QiHaptic {
    static let levelTitles = ["关", "轻", "中", "强"]

    private var level = 1
    private var generator: UIImpactFeedbackGenerator?

    func setLevel(_ l: Int) {
        guard l != level else { return }
        level = l
        generator = nil
    }

    private var style: UIImpactFeedbackGenerator.FeedbackStyle {
        switch level {
        case 1: return .light
        case 2: return .medium
        default: return .heavy
        }
    }

    private var intensity: CGFloat {
        switch level {
        case 1: return 0.5
        case 2: return 0.8
        default: return 1.0
        }
    }

    func tick() {
        guard level > 0 else { return }
        let g = generator ?? UIImpactFeedbackGenerator(style: style)
        generator = g
        g.impactOccurred(intensity: intensity)
    }
}
