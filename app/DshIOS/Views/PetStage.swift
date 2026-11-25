import SwiftUI

/// 桌宠：站在聊天页底部，可以左右拖着走，点一下有反应。
///
/// 内置的是 dsh-Go 的 Deepy 小鲸鱼（图集在 bundle 根目录，数据写死）；
/// 装了宠物包以后改读 `pack.json`，图和帧表都用包里的。
struct PetStage: View {
    /// 美术像素到点的倍率，三档大小。
    @AppStorage("dsh.pet.size") private var sizeRaw = 1
    /// 相对右边缘向左挪了多少点，拖动后记住。
    @AppStorage("dsh.pet.offsetX") private var storedX = 0.0

    @ObservedObject private var store = PetStore.shared

    @State private var builtin = PetAnimation.idle
    @State private var reaction: PetAnim?
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
                if let bubble {
                    Text(bubble)
                        .font(.caption2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }
                sprite(spec, k: k)
                Text(store.usingBuiltin ? "小鲸鱼" : (store.current?.name ?? ""))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 78)
                    .allowsHitTesting(false)
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
            .position(x: x, y: geo.size.height - h / 2 - 8)
        }
        .onReceive(clock) { _ in
            guard !reacting else { return }
            frame = (frame + 1) % max(currentSpec.anim.indexes.count, 1)
        }
        .onReceive(bubbleTimer) { _ in
            if bubble != nil { bubble = nil }
        }
        .accessibilityLabel(Text("桌宠"))
        .accessibilityHint(Text("点一下有反应，可以左右拖"))
    }

    /// 现在该画哪一只：反应动画 > 宠物包 > 内置待机。
    private var currentSpec: PetSpec {
        if !store.usingBuiltin, let pack = store.current {
            if let reaction, let image = store.image(for: reaction) {
                return PetSpec(image: image, anim: reaction)
            }
            let key = pack.animations["idle"] != nil ? "idle" : (pack.animations.keys.sorted().first ?? "idle")
            if let anim = pack.animations[key], let image = store.image(for: anim) {
                return PetSpec(image: image, anim: anim)
            }
        }
        return PetSpec(image: builtin.image(), anim: builtin.anim)
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
            reaction = Bool.random() ? left : right
        } else {
            builtin = Bool.random() ? .reactLeft : .reactRight
        }
        bubble = ["在的", "戳我干嘛", "要干活吗", "好耶"].randomElement()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            reaction = nil
            builtin = .idle
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

/// 内置那只的数据：图集在 bundle 根目录，帧表照 dsh-Go 的 pack.json 写死。
struct PetAnimation {
    let sheet: String
    let anim: PetAnim

    static let idle = builtin("pet-deepy-idle", cols: 21, count: 42, box: CGRect(x: 12, y: 26, width: 36, height: 24))
    static let thinking = builtin("pet-deepy-thinking", cols: 16, count: 48, box: CGRect(x: 0, y: 6, width: 47, height: 44))
    static let working = builtin("pet-deepy-typing", cols: 12, count: 48, box: CGRect(x: 0, y: 17, width: 52, height: 33))
    static let happy = builtin("pet-deepy-happy", cols: 13, count: 52, box: CGRect(x: 0, y: 5, width: 52, height: 45))
    static let sleeping = builtin("pet-deepy-sleeping", cols: 16, count: 64, box: CGRect(x: 2, y: 2, width: 44, height: 48))
    static let reactLeft = builtin("pet-deepy-react-left", cols: 14, count: 40, box: CGRect(x: 1, y: 16, width: 50, height: 34))
    static let reactRight = builtin("pet-deepy-react-right", cols: 14, count: 40, box: CGRect(x: 8, y: 16, width: 44, height: 34))

    private static func builtin(_ sheet: String, cols: Int, count: Int, box: CGRect) -> PetAnimation {
        PetAnimation(
            sheet: sheet,
            anim: PetAnim(
                sheet: Bundle.main.url(forResource: sheet, withExtension: "png") ?? URL(fileURLWithPath: "/"),
                // dsh-Go 的图集一格是 180×120 像素，box 用 canvas 单位写的。
                frameW: 180,
                frameH: 120,
                cols: cols,
                box: box,
                indexes: Array(0..<count),
                fps: 10
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
