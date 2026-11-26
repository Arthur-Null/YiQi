import UIKit

// 按键震动：主 App 里的预览和键盘里的按键用同一套档位，试到的手感就是打字时的手感。
final class QiHaptic {
    static let levelTitles = ["关", "轻", "中", "强"]

    // 键盘扩展里传入键盘视图：震动器绑定到这个视图，由系统按它判断是否播放；
    // 震动器在第一次按键时才创建（此时键盘已经显示在屏幕上）。
    private weak var view: UIView?
    private var level = 1
    private var generator: UIImpactFeedbackGenerator?

    init(view: UIView? = nil) {
        self.view = view
    }

    func setLevel(_ l: Int) {
        guard l != level else { return }
        level = l
        generator = nil
    }

    private var style: UIImpactFeedbackGenerator.FeedbackStyle {
        switch level {
        case 1: return .soft
        case 2: return .light
        default: return .medium
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
        if #available(iOS 17.5, *), let v = view {
            let g = generator ?? UIImpactFeedbackGenerator(style: style, view: v)
            generator = g
            g.impactOccurred(intensity: intensity, at: CGPoint(x: v.bounds.midX, y: v.bounds.midY))
        } else {
            let g = generator ?? UIImpactFeedbackGenerator(style: style)
            generator = g
            g.impactOccurred(intensity: intensity)
        }
    }
}
