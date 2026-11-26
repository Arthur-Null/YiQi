import UIKit

// 按键震动：主 App 里的预览和键盘里的按键用同一套档位，试到的手感就是打字时的手感。
final class QiHaptic {
    static let levelTitles = ["关", "轻", "中", "强"]

    private var level = 1
    private var generator: UIImpactFeedbackGenerator?
    private var intensity: CGFloat = 0

    func setLevel(_ l: Int) {
        guard l != level || generator == nil else { return }
        level = l
        switch l {
        case 0: generator = nil
        case 1: generator = UIImpactFeedbackGenerator(style: .soft); intensity = 0.45
        case 2: generator = UIImpactFeedbackGenerator(style: .light); intensity = 0.8
        default: generator = UIImpactFeedbackGenerator(style: .medium); intensity = 1.0
        }
        generator?.prepare()
    }

    func tick() {
        guard let g = generator else { return }
        g.impactOccurred(intensity: intensity)
        g.prepare()
    }
}
