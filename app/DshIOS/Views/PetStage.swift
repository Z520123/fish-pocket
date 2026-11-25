import SwiftUI

/// 桌宠：dsh-Go 的 Deepy 小鲸鱼，站在聊天页右下角。
///
/// 图集从 dsh-Go 仓库（`app/assets/pets/deepy-whale`）搬来，一张平铺 PNG 一段动画：
/// 每格 `box` 大小、按 `cols` 排成网格。播放就是把整张图按格宽放大、平移到当前格，
/// 外面套一个裁到 `box` 的窗口。数据先写死这一只，以后接宠物包时换成读 pack.json。
struct PetStage: View {
    /// 美术像素到屏幕点的倍率：dsh-Go 的宠物按 contentBox 定档，这里取标准档相近的大小。
    private static let scale: CGFloat = 2.6

    @State private var animation = PetAnimation.idle
    @State private var frame = 0
    @State private var reacting = false
    @State private var bubble: String?

    private let clock = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let bubbleTimer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let bubble {
                Text(bubble)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Self.scale * animation.box.height + 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }
            sprite
        }
    }

    private var sprite: some View {
        Group {
            if let image = animation.image() {
                let boxW = animation.box.width * Self.scale
                let boxH = animation.box.height * Self.scale
                let columns = animation.cols
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(columns) * boxW, height: CGFloat(animation.rows) * boxH)
                    .offset(x: -CGFloat(frame % columns) * boxW, y: -CGFloat(frame / columns) * boxH)
                    .frame(width: boxW, height: boxH, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { tap() }
                    .accessibilityLabel(Text("桌宠"))
                    .accessibilityHint(Text("点一下有反应"))
            }
        }
        .onReceive(clock) { _ in
            guard !reacting else { return }
            frame = (frame + 1) % animation.frames
        }
        .onReceive(bubbleTimer) { _ in
            if bubble != nil { bubble = nil }
        }
    }

    /// 点一下：随机一个反应，播完回到待机。
    private func tap() {
        Haptics.tap()
        play(Bool.random() ? .reactLeft : .reactRight, for: 1.4)
        bubble = ["在的", "戳我干嘛", "要干活吗", "好耶"].randomElement()
    }

    private func play(_ next: PetAnimation, for seconds: TimeInterval) {
        reacting = true
        animation = next
        frame = 0
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            animation = .idle
            frame = 0
            reacting = false
        }
    }
}

/// 一段宠物动画：一张图集、每格大小、几列、多少帧。
struct PetAnimation: Equatable {
    let sheet: String
    let cols: Int
    let frames: Int
    let rows: Int
    /// 这一格在画布上的位置与大小，美术像素。
    let box: CGRect

    static let idle = PetAnimation(sheet: "pet-deepy-idle", cols: 21, frames: 42, rows: 2,
                                   box: CGRect(x: 12, y: 26, width: 36, height: 24))
    static let thinking = PetAnimation(sheet: "pet-deepy-thinking", cols: 16, frames: 48, rows: 3,
                                       box: CGRect(x: 0, y: 6, width: 47, height: 44))
    static let working = PetAnimation(sheet: "pet-deepy-typing", cols: 12, frames: 48, rows: 4,
                                      box: CGRect(x: 0, y: 17, width: 52, height: 33))
    static let happy = PetAnimation(sheet: "pet-deepy-happy", cols: 13, frames: 52, rows: 4,
                                    box: CGRect(x: 0, y: 5, width: 52, height: 45))
    static let sleeping = PetAnimation(sheet: "pet-deepy-sleeping", cols: 16, frames: 64, rows: 4,
                                       box: CGRect(x: 2, y: 2, width: 44, height: 48))
    static let reactLeft = PetAnimation(sheet: "pet-deepy-react-left", cols: 14, frames: 40, rows: 3,
                                        box: CGRect(x: 1, y: 16, width: 50, height: 34))
    static let reactRight = PetAnimation(sheet: "pet-deepy-react-right", cols: 14, frames: 40, rows: 3,
                                         box: CGRect(x: 8, y: 16, width: 44, height: 34))

    /// 图集 PNG，bundle 根目录下带 `pet-deepy-` 前缀的那几张；解码一次就留着。
    private static let images = NSCache<NSString, UIImage>()

    func image() -> UIImage? {
        if let hit = Self.images.object(forKey: sheet as NSString) { return hit }
        guard let url = Bundle.main.url(forResource: sheet, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        Self.images.setObject(image, forKey: sheet as NSString)
        return image
    }
}
