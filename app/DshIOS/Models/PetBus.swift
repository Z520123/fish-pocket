import SwiftUI

/// 桌宠的对外接口：`fishpocket://pet?action=…` 的链接、快捷指令、插件，还有智能体的
/// `pet_react` 工具都到这里，由 `PetStage` 画出来。它自己做一会儿就散，调用方不用收尾。
/// 没有标 `@MainActor`：它照 `PetStore` 那样按主线程用，标了反而让
/// `PetStage` 的属性初始化器读不到 `shared`。所有写入都在主线程的任务里做。
final class PetBus: ObservableObject {
    static let shared = PetBus()

    /// 外面要求的动作；到点自己清掉，回到聊天页原本的状态。
    @Published private(set) var action: PetMood?
    /// 头顶气泡里那一句。
    @Published private(set) var text: String?

    private var clear: Task<Void, Never>?

    private init() {
        // 智能体那边走原生通知（`ios_native.m` 的 pet 能力），不经过 URL scheme：
        // 在 App 里打开自己的 scheme 不可靠，通知一定到。
        _ = NotificationCenter.default.addObserver(forName: .dshPetAction, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            let name = info["action"] as? String ?? "happy"
            let text = (info["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let seconds = (info["seconds"] as? NSNumber)?.doubleValue ?? 3
            Task { @MainActor in PetBus.shared.perform(name, text: text, seconds: seconds) }
        }
    }

    /// 按名字来一次：名字不认识就当没发生，返回 false 好让调用方说清楚。
    @discardableResult
    func perform(_ name: String, text: String? = nil, seconds: Double = 3) -> Bool {
        guard let mood = PetMood(named: name) else { return false }
        perform(mood, text: text, seconds: seconds)
        return true
    }

    func perform(_ mood: PetMood, text: String? = nil, seconds: Double = 3) {
        action = mood
        self.text = text
        clear?.cancel()
        clear = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(seconds, 0.5)))
            guard !Task.isCancelled else { return }
            action = nil
            self.text = nil
        }
    }
}

extension Notification.Name {
    /// `ios_native.m` 的 pet 能力发来的一个动作（智能体调 `pet_react`）。
    static let dshPetAction = Notification.Name("DshPetAction")
}
