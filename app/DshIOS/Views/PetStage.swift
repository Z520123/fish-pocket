import SwiftUI

/// 桌宠：站在聊天页底部，可以左右拖着走，点一下有反应。
///
/// 内置的是 dsh-Go 的 Deepy 小鲸鱼（图集在 bundle 根目录，数据写死）；
/// 装了宠物包以后改读 `pack.json`，图和帧表都用包里的。
struct PetStage: View {
    /// 现在该做什么：跟着智能体的状态换动作，不是一直待机。
    var mood: PetMood = .idle
    /// 美术像素到点的倍率，三档大小。
    @AppStorage("dsh.pet.size") private var sizeRaw = 1
    /// 相对右边缘向左挪了多少点，拖动后记住。
    @AppStorage("dsh.pet.offsetX") private var storedX = 0.0

    @ObservedObject private var store = PetStore.shared
    /// 外部（链接、快捷指令、智能体工具）要求做的动作。
    @ObservedObject private var bus = PetBus.shared

    /// 待机久了挪两步。
    @State private var roaming = false
    @State private var idleTicks = 0
    /// 这一次待机走动的门槛，每回走完重掷。
    @State private var roamAfter = Int.random(in: 140...380)
    /// 点一下的反应：内置那只和宠物包各存一份，类型不同。
    @State private var builtinReaction: PetAnimation?
    @State private var packReaction: PetAnim?
    /// 一段活干完先乐一会儿。
    @State private var celebrating = false
    @State private var frame = 0
    @State private var reacting = false
    @State private var bubble: String?
    @State private var dragX: CGFloat = 0

    private let clock = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let bubbleTimer = Timer.publish(every: 2.4, on: .main, in: .common).autoconnect()

    private var pointScale: CGFloat {
        switch Int(sizeRaw) {
        case 0: 1.9
        case 2: 3.4
        default: 2.6
        }
    }

    var body: some View {
        GeometryReader { geo in
            let spec = currentSpec
            let k = pointScale
            let w = spec.anim.box.width * k
            let h = spec.anim.box.height * k
            let margin: CGFloat = 10
            let leftEdge = w / 2 + 4
            let rightEdge = max(leftEdge, geo.size.width - w / 2 - margin)
            let x = min(max(rightEdge + storedX + dragX, leftEdge), rightEdge)

            VStack(spacing: 2) {
                if let bubble = bus.text ?? bubble {
                    Text(bubble)
                        .font(.caption2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }
                sprite(spec, k: k)
            }
            .fixedSize()
            .contentShape(Rectangle())
            // 拖：跟着手指走，松手把新位置记住（相对右边缘，负数是往左）。
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in dragX = value.translation.width }
                    .onEnded { _ in
                        storedX = min(max(storedX + dragX, -2000), 0)
                        dragX = 0
                    }
            )
            .onTapGesture { tap() }
            .position(x: x, y: geo.size.height - h / 2)
        }
        .onReceive(clock) { _ in
            // 反应动画也照常播帧：只显示第一帧的话，看着像卡住了。
            frame = (frame + 1) % max(currentSpec.anim.indexes.count, 1)
            // 闲下来了就隔一阵挪两步：不动的话桌宠看着像张画。
            let quiet = mood == .idle && bus.action == nil && builtinReaction == nil && packReaction == nil && !celebrating
            if quiet, !roaming {
                idleTicks += 1
                if idleTicks >= roamAfter { roam() }
            } else {
                idleTicks = 0
            }
        }
        .onReceive(bubbleTimer) { _ in
            if bubble != nil { bubble = nil }
        }
        // 换动作从头播，不然会从上一段的中途接着走。
        .onChange(of: mood) { old, new in
            frame = 0
            // 刚干完活：先乐一会儿再回待机。
            if (old == .working || old == .thinking), new == .idle {
                celebrating = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    celebrating = false
                    frame = 0
                }
            }
        }
        .accessibilityLabel(Text("桌宠"))
        .accessibilityHint(Text("点一下有反应，可以左右拖"))
    }

    /// 现在该画哪一只：点一下的反应 > 宠物包 > 内置，按当前状态取动作。
    private var currentSpec: PetSpec {
        if !store.usingBuiltin, let pack = store.current {
            if let packReaction, let image = store.image(for: packReaction) {
                return PetSpec(image: image, anim: packReaction)
            }
            let key = (bus.action ?? mood).packKey
            let fallback = pack.animations["idle"] != nil ? "idle" : (pack.animations.keys.sorted().first ?? "idle")
            if let anim = pack.animations[key] ?? pack.animations[fallback], let image = store.image(for: anim) {
                return PetSpec(image: image, anim: anim)
            }
        }
        let builtin = builtinAnimation
        return PetSpec(image: builtin.image(), anim: builtin.anim)
    }

    /// 内置那只现在该播哪一段：反应 > 干完活的开心 > 状态本身。
    private var builtinAnimation: PetAnimation {
        if let action = bus.action { return animation(for: action) }
        if let builtinReaction { return builtinReaction }
        if celebrating { return .happy }
        if roaming { return .roamHop }
        return animation(for: mood)
    }

    private func animation(for mood: PetMood) -> PetAnimation {
        switch mood {
        case .idle: return .idle
        case .thinking: return .thinking
        case .working: return .typing
        case .happy: return .happy
        case .sleeping: return .sleeping
        case .alert: return .notification
        }
    }

    /// 待机久了跳两步：播 `roam-hop`，位置也挪一段，走完继续待机。
    private func roam() {
        idleTicks = 0
        roamAfter = Int.random(in: 140...380)
        roaming = true
        let delta = Bool.random() ? CGFloat.random(in: 36...88) : -CGFloat.random(in: 36...88)
        withAnimation(.easeInOut(duration: 0.9)) {
            storedX = min(max(storedX + delta, -2000), 0)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            roaming = false
        }
    }

    /// 一张图集按格切：整张图缩到「每格 = box 的大小」，再平移到当前格，外面裁一个 box 大的窗口。
    ///
    /// 尺度以 `box` 为准（dsh-Go 的 canvas 单位），不是 PNG 的像素：图集里一格 180px，
    /// 但 box 只有 36 个单位，按像素算会让宠物被裁成一个角。`box` 在格子里的偏移按比例补上。
    @ViewBuilder
    private func sprite(_ spec: PetSpec, k: CGFloat) -> some View {
        let anim = spec.anim
        let cols = max(anim.cols, 1)
        let rows = max(1, Int(ceil(Double((anim.indexes.max() ?? 0) + 1) / Double(cols))))
        let cellW = anim.box.width * k
        let cellH = anim.box.height * k
        let slot = anim.indexes[min(frame, max(anim.indexes.count - 1, 0))]
        if let image = spec.image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .frame(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows))
                .offset(x: -CGFloat(slot % cols) * cellW,
                        y: -CGFloat(slot / cols) * cellH)
                .frame(width: cellW, height: cellH, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
        } else {
            Color.clear.frame(width: cellW, height: cellH)
        }
    }

    /// 点一下：随机一个反应，播完回到待机。
    private func tap() {
        Haptics.tap()
        frame = 0
        reacting = true
        if !store.usingBuiltin, let pack = store.current,
           let left = pack.animations["react-left"] ?? pack.animations["idle"],
           let right = pack.animations["react-right"] ?? pack.animations["idle"] {
            packReaction = Bool.random() ? left : right
        } else {
            builtinReaction = Bool.random() ? .reactLeft : .reactRight
        }
        bubble = ["在的", "戳我干嘛", "要干活吗", "好耶"].randomElement()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            builtinReaction = nil
            packReaction = nil
            frame = 0
            reacting = false
        }
    }
}

/// 一次绘制需要的全部东西：解码好的图 + 取帧规则。
private struct PetSpec {
    let image: UIImage?
    let anim: PetAnim
}

/// 内置那只的数据：图集在 bundle 根目录，帧表照 dsh-Go 的 `pack.json` 写死。
struct PetAnimation {
    let sheet: String
    let anim: PetAnim

    static let idle = builtin("pet-deepy-idle", cols: 21, count: 48, box: CGRect(x: 12, y: 26, width: 36, height: 24), frame: CGSize(width: 180, height: 120))
    static let thinking = builtin("pet-deepy-thinking", cols: 16, count: 48, box: CGRect(x: 0, y: 6, width: 47, height: 44), frame: CGSize(width: 235, height: 220))
    static let typing = builtin("pet-deepy-typing", cols: 12, count: 48, box: CGRect(x: 0, y: 17, width: 52, height: 33), frame: CGSize(width: 260, height: 165))
    static let happy = builtin("pet-deepy-happy", cols: 13, count: 52, box: CGRect(x: 0, y: 5, width: 52, height: 45), frame: CGSize(width: 260, height: 225))
    static let sleeping = builtin("pet-deepy-sleeping", cols: 16, count: 64, box: CGRect(x: 2, y: 2, width: 44, height: 48), frame: CGSize(width: 220, height: 240))
    static let waking = builtin("pet-deepy-waking", cols: 15, count: 30, box: CGRect(x: 8, y: 4, width: 44, height: 46), frame: CGSize(width: 220, height: 230))
    static let roamHop = builtin("pet-deepy-roam-hop", cols: 13, count: 24, box: CGRect(x: 10, y: 20, width: 37, height: 30), frame: CGSize(width: 185, height: 150))
    static let reactLeft = builtin("pet-deepy-react-left", cols: 14, count: 40, box: CGRect(x: 1, y: 16, width: 50, height: 34), frame: CGSize(width: 250, height: 170))
    static let reactRight = builtin("pet-deepy-react-right", cols: 14, count: 40, box: CGRect(x: 8, y: 16, width: 44, height: 34), frame: CGSize(width: 220, height: 170))
    static let notification = builtin("pet-deepy-notification", cols: 16, count: 32, box: CGRect(x: 3, y: 7, width: 47, height: 43), frame: CGSize(width: 235, height: 215))

    private static func builtin(_ sheet: String, cols: Int, count: Int, box: CGRect, frame: CGSize) -> PetAnimation {
        PetAnimation(
            sheet: sheet,
            anim: PetAnim(
                sheet: Bundle.main.url(forResource: sheet, withExtension: "png") ?? URL(fileURLWithPath: "/"),
                frameW: frame.width,
                frameH: frame.height,
                cols: cols,
                box: box,
                indexes: Array(0..<count),
                fps: 20
            )
        )
    }

    /// 图集 PNG，解码一次就留着。
    private static let images = NSCache<NSString, UIImage>()

    func image() -> UIImage? {
        if let hit = Self.images.object(forKey: sheet as NSString) { return hit }
        guard let url = Bundle.main.url(forResource: sheet, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        Self.images.setObject(image, forKey: sheet as NSString)
        return image
    }
}

/// 桌宠现在该做什么，跟着智能体的状态走。
enum PetMood: Equatable {
    case idle, thinking, working, happy, sleeping, alert

    /// 按名字认一个：链接、快捷指令、智能体工具都用名字说话。
    init?(named name: String) {
        switch name.lowercased() {
        case "idle", "待机": self = .idle
        case "thinking", "思考": self = .thinking
        case "working", "typing", "干活": self = .working
        case "happy", "开心": self = .happy
        case "sleeping", "睡觉": self = .sleeping
        case "alert", "notification", "提醒": self = .alert
        default: return nil
        }
    }

    /// 宠物包里对应的动画名，和 dsh-Go 的 `states` 一致。
    var packKey: String {
        switch self {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .working: return "typing"
        case .happy: return "happy"
        case .sleeping: return "sleeping"
        case .alert: return "notification"
        }
    }
}
