import SwiftUI

/// 「本机操控」：让这个 App 自己操作这台手机，不走 iCTRL、不走电脑。
///
/// 两件事在这里做完：把自己和本机配对（App 在手机上起一个可配对主机，用户在「设置」里输
/// 一次六位数字），把开发者镜像下载并挂上。之后智能体点按、输入、读屏都在 App 自己的进程里，
/// 不再需要任何外部程序。
struct PhoneSetupView: View {
    @State private var state: [String: Any] = [:]
    @State private var message: String?
    @State private var busy = false

    private var stage: String { state["stage"] as? String ?? "idle" }
    private var detail: String { state["detail"] as? String ?? "" }
    private var pin: String { state["pin"] as? String ?? "" }
    private var paired: Bool { state["paired"] as? Bool ?? false }
    private var imagePresent: Bool { state["ddi"] as? Bool ?? false }
    private var keepAlive: Bool { state["locationKeepAlive"] as? Bool ?? false }

    var body: some View {
        List {
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 8, height: 8)
                        Text(title)
                    }
                    .foregroundStyle(.secondary)
                } label: {
                    Label("本机操控", systemImage: "iphone.gen3")
                }
                if !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                if !pin.isEmpty {
                    LabeledContent("配对数字") {
                        Text(pin).font(.system(.title2, design: .monospaced)).bold()
                    }
                }
            } footer: {
                Text("这一套跑在 App 自己里面：配对、下载开发者镜像、挂载都由它自己完成，不需要 iCTRL，也不需要电脑。")
            }
            .groupedRow()

            Section {
                if paired {
                    Label("已配对", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Button {
                        PhoneLink.shared.startPairing()
                    } label: {
                        Label("开始配对", systemImage: "dot.radiowaves.left.and.right")
                    }
                    if stage == "pairing" {
                        Button("取消配对", role: .destructive) { PhoneLink.shared.stopPairing() }
                    }
                }
                Button {
                    busy = true
                    message = nil
                    PhoneLink.shared.prepareDevice { problem in
                        busy = false
                        message = problem
                        refresh()
                    }
                } label: {
                    Label(busy ? "正在准备…" : (imagePresent ? "连接（镜像已在）" : "下载镜像并连接"), systemImage: "arrow.down.circle")
                }
                .disabled(busy || !paired)
            } header: {
                Text("第一步：配对和镜像")
            } footer: {
                Text("配对：点「开始配对」后打开「设置」，里面会出现一个 Fish Pocket 的配对条目，点进去输入这一页显示的六位数字。\n\n镜像：iOS 重启后要重新挂一次。挂载要连本机自己的 10.7.0.1，所以这一步需要把 10.7.0.1 绕回本机的隧道（代理 App 加一条规则，或者 LocalDevVPN）。挂上以后，点按、输入、读屏都不再走它，平时不需要开着。")
            }
            .groupedRow()

            Section {
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    busy = true
                    message = nil
                    DispatchQueue.global().async {
                        let probe = DshPhonePrepareSession() as? [String: Any] ?? [:]
                        DispatchQueue.main.async {
                            busy = false
                            message = (probe["ok"] as? Bool ?? false)
                                ? "会话开起来了：\(probe["seconds"] ?? "?") 秒"
                                : "会话被拒：\(probe["code"] ?? "未知") \(probe["detail"] ?? "")"
                        }
                    }
                } label: {
                    Label("测试会话", systemImage: "waveform.path.ecg")
                }
                .disabled(busy)
            } footer: {
                Text("只开一次自动化会话，什么都不点。第一次会弹 iOS 的授权，允许一次即可。")
            }
            .groupedRow()

            Section {
                Toggle(isOn: Binding(
                    get: { keepAlive },
                    set: { on in
                        PhoneLink.shared.locationKeepAlive = on
                        refresh()
                    }
                )) {
                    Label("定位保活", systemImage: "location.fill")
                }
            } footer: {
                Text("打开以后，App 退到后台也会一直有一条定位在更新，智能体点按到一半切出去也不会被挂起。代价是耗电，并且「设置」里的定位服务会显示 App 正在使用位置。")
            }
            .groupedRow()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("本机操控")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PhoneLink.stateChanged)) { _ in refresh() }
    }

    private func refresh() { state = PhoneLink.shared.stateJSON() }

    private var title: String {
        switch stage {
        case "pairing": return "等你配对"
        case "downloading": return "下载镜像"
        case "mounting": return "挂载中"
        case "ready": return "可以操控"
        case "failed": return "出错了"
        default: return paired ? "已配对" : "还没配"
        }
    }

    private var tint: Color {
        switch stage {
        case "ready": return .green
        case "failed": return .red
        case "pairing", "downloading", "mounting": return .orange
        default: return paired ? .green : .secondary
        }
    }
}
