import SwiftUI

/// 「操控手机」：这个 App 自己操作这台手机，不走 iCTRL、不走电脑。
///
/// 配对、下载开发者镜像、挂载镜像、定位保活和测试会话都在这一个页面里。智能体点按、
/// 输入、读屏全部在 App 自己的进程里完成；挂载那一步需要一条把 10.7.0.1 绕回本机的隧道，
/// 下载和挂载因为网络条件相反，所以是两个按钮。
struct PhoneControlView: View {
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
            } footer: {
                Text("配对：点「开始配对」后打开「设置」，里面会出现一个 Fish Pocket 的配对条目，点进去输入这一页显示的六位数字。")
            }
            .groupedRow()

            Section {
                Button {
                    busy = true
                    message = nil
                    PhoneLink.shared.downloadImageOnly { problem in
                        busy = false
                        message = problem
                        refresh()
                    }
                } label: {
                    Label(imagePresent ? "镜像已下载" : "下载开发者镜像", systemImage: "arrow.down.circle")
                }
                .disabled(busy || !paired || imagePresent)

                Button {
                    busy = true
                    message = nil
                    PhoneLink.shared.mountImage { problem in
                        busy = false
                        message = problem
                        refresh()
                    }
                } label: {
                    Label(busy ? "正在挂载…" : "挂载镜像", systemImage: "externaldrive.connected.to.line.below")
                }
                .disabled(busy || !imagePresent)
            } header: {
                Text("镜像")
            } footer: {
                Text("下载和挂载是两件事，因为网络要求正好相反：下载走 GitHub，要能连上 GitHub（代理或全局 VPN）；挂载连的是本机自己的 10.7.0.1，要的是把那个地址绕回本机的隧道。先关隧道下载，再开隧道挂载。\n\niOS 重启后镜像要重新挂一次，文件还在，只要再点「挂载镜像」。挂上以后，点按、输入、读屏都不再走那条隧道。")
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

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("截图会发给模型服务商", systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                    Text("智能体看到的其他 App 画面，会随对话发给你选的模型服务商。付款、删除、替你发消息前，它会先问你；密码和验证码由你自己输入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("使用须知")
            }
            .groupedRow()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("操控手机")
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

/// 侧边栏「操控手机」那一行要一个状态：现在读的是 App 自己的本机操控，不再是 iCTRL。
/// 页面本身不再需要它，留着是因为 `ExploreTabView` 和 `DrawerView` 都拿它决定那一行写什么。
@MainActor @Observable
final class PhoneControlService {
    enum State: Equatable {
        case checking, notInstalled, stopped, running

        var title: String {
            switch self {
            case .checking: String(localized: "检查中…")
            case .notInstalled: String(localized: "还没配")
            case .stopped: String(localized: "待挂镜像")
            case .running: String(localized: "可以操控")
            }
        }

        var tint: Color {
            switch self {
            case .running: .green
            case .stopped: .orange
            case .notInstalled, .checking: .gray
            }
        }
    }

    private(set) var state: State = .checking

    func refresh() async {
        let s = PhoneLink.shared.stateJSON()
        let paired = s["paired"] as? Bool ?? false
        let stage = s["stage"] as? String ?? "idle"
        let image = s["ddi"] as? Bool ?? false
        if !paired {
            state = .notInstalled
        } else if stage == "ready" || image {
            state = .running
        } else {
            state = .stopped
        }
    }
}
