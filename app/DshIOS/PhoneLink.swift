import Foundation
import CoreLocation
import UIKit
import PokiCore

/// 手机操控：把自己和本机配对、把开发者镜像挂上、把 App 退到后台也留住。
///
/// 三层各管一段，谁也不替谁：
///   · Rust 的 launcher（native/poki-launcher）在手机上起一个可配对主机，配好以后用配对文件
///     连本机、把镜像挂上去；
///   · PokiCore 的 `DeveloperDiskImage` 从 doronz88 的镜像站下载开发者镜像，按 BuildManifest
///     里的 SHA-384 逐个校验，存进 App 的容器；
///   · `PKInProcess`（native/poki-phone，ObjC 那一侧）在 App 自己的进程里开 XCTest 会话。
///
/// 一件要说清的事：挂载镜像要连 10.7.0.1:49152，那是本机自己的服务，得有一条把 10.7.0.1
/// 绕回本机的隧道（代理 App 的规则或 LocalDevVPN）。镜像挂上以后，点按、输入、读屏都不再
/// 走它，所以平时不需要隧道。
@objc(PhoneLink)
final class PhoneLink: NSObject {
    @objc static let shared = PhoneLink()

    /// 状态变了就发一条，页面和能力的回执都听这个。
    static let stateChanged = Notification.Name("PhoneLinkStateChanged")

    enum Stage: String {
        case idle          // 还没有配对文件
        case pairing       // 等用户在「设置」里配对
        case downloading   // 正在下载开发者镜像
        case mounting      // 正在挂载镜像
        case ready         // 镜像在，可以开会话
        case failed
    }

    private let fm = FileManager.default
    private var stage: Stage = .idle
    private var detail: String = ""
    private var pin: String = ""
    private var pairService: NetService?

    private(set) var launcher: OpaquePointer?
    private var pairingHandle: OpaquePointer?

    /// 配对文件：配对成功后 Rust 写在这里，之后每次启动都由它连本机。
    var pairingFile: URL { support.appendingPathComponent("pairing.plist") }
    /// 开发者镜像的目录，Rust 的 `ddi_dir`。
    var ddiDir: URL { support.appendingPathComponent("ddi") }

    private lazy var support: URL = {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("PhoneControl", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private override init() {
        super.init()
        if fm.fileExists(atPath: pairingFile.path) {
            stage = .idle
        }
    }

    // MARK: - 状态

    /// 给页面和回执用的一份快照。
    @objc func stateJSON() -> [String: Any] {
        var out: [String: Any] = [
            "stage": stage.rawValue,
            "detail": detail,
            "paired": fm.fileExists(atPath: pairingFile.path),
            "ddi": fm.fileExists(atPath: ddiDir.appendingPathComponent("BuildManifest.plist").path),
            "pin": pin,
            "locationKeepAlive": LocationKeepAlive.shared.running,
        ]
        if let text = launcherStatus() { out["launcher"] = text }
        return out
    }

    private func launcherStatus() -> String? {
        guard let launcher else { return nil }
        guard let raw = poki_launcher_status(launcher) else { return nil }
        defer { poki_string_free(raw) }
        return String(cString: raw)
    }

    private func set(_ new: Stage, _ text: String) {
        let changed = (stage != new) || (detail != text)
        stage = new
        detail = text
        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PhoneLink.stateChanged, object: nil)
            }
        }
    }

    // MARK: - 配对

    /// 起一次配对：Rust 开一个端口，这里把 `_remotepairing-pairable-host._tcp` 通过 Bonjour
    /// 广播出去，用户在「设置」里选中本 App 并输入 App 显示的六位数字。
    @objc func startPairing() {
        guard pairingHandle == nil else { return }
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "host_name": "Fish Pocket",
            "out_path": pairingFile.path,
            "identity_path": support.appendingPathComponent("host-identity").path,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return }
        pairService?.stop()
        set(.pairing, "正在等你在「设置」里配对")
        pairingHandle = poki_pair_start(json, PhoneLink.onPairEvent, Unmanaged.passUnretained(self).toOpaque())
        if pairingHandle == nil { set(.failed, "配对没有启动起来") }
    }

    @objc func stopPairing() {
        if let handle = pairingHandle { poki_pair_cancel(handle) }
        pairingHandle = nil
        pairService?.stop()
        pairService = nil
        pin = ""
        if stage == .pairing { set(.idle, "") }
    }

    private func pairEvent(_ text: String) {
        guard let value = PhoneLink.decode(text), let event = value["event"] as? String else { return }
        switch event {
        case "advertise":
            let type = value["service_type"] as? String ?? "_remotepairing-pairable-host._tcp"
            let name = value["instance"] as? String ?? "Fish Pocket"
            let port = (value["port"] as? NSNumber)?.int32Value ?? 0
            let txt = value["txt"] as? [String: String] ?? [:]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let service = NetService(domain: "local.", type: type, name: name, port: port)
                service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
                service.delegate = self
                service.publish()
                self.pairService = service
            }
        case "pin":
            pin = value["pin"] as? String ?? ""
            set(.pairing, "在「设置」里输入这串数字")
        case "paired":
            pin = ""
            pairingHandle = nil
            pairService?.stop()
            pairService = nil
            set(.idle, "配对完成，可以连接了")
        case "failed":
            pin = ""
            pairingHandle = nil
            pairService?.stop()
            pairService = nil
            set(.failed, value["detail"] as? String ?? "配对失败")
        default:
            break
        }
    }

    // MARK: - 镜像与挂载

    /// 镜像挂了就能直接开会话；没挂就下载、再让 Rust 挂上。
    /// `completion` 在主线程回调，成功时为空。
    @objc func prepareDevice(_ completion: @escaping (String?) -> Void) {
        if DshPhoneFrameworksAvailable() {
            set(.ready, "开发者镜像已在，可以直接操控")
            completion(nil)
            return
        }
        guard fm.fileExists(atPath: pairingFile.path) else {
            completion("还没有配对：先在「操控手机」里点「开始配对」，在「设置」里输一次数字。")
            return
        }
        set(.downloading, "正在下载开发者镜像")
        downloadImage { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.set(.failed, "下载开发者镜像失败：\(error.localizedDescription)")
                completion("下载开发者镜像失败：\(error.localizedDescription)")
            case .success:
                self.set(.mounting, "正在挂载开发者镜像")
                self.startLauncher { problem in
                    if let problem { self.set(.failed, problem) }
                    completion(problem)
                }
            }
        }
    }

    private func downloadImage(_ done: @escaping (Result<String, Error>) -> Void) {
        try? fm.createDirectory(at: ddiDir, withIntermediateDirectories: true)
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let build = try await DeveloperDiskImage.ensure(in: self.ddiDir) { line in
                    self.set(.downloading, line)
                }
                done(.success(build))
            } catch {
                done(.failure(error))
            }
        }
    }

    /// 起 Rust 的 launcher：它读配对文件连本机，镜像不在就挂上。
    private func startLauncher(_ done: @escaping (String?) -> Void) {
        if launcher != nil {
            poki_launcher_free(launcher)
            launcher = nil
        }
        let config: [String: Any] = [
            "device_address": "10.7.0.1",
            "pairing_file": pairingFile.path,
            "host_name": "Fish Pocket",
            "ddi_dir": ddiDir.path,
            "wda_host": "127.0.0.1",
            "wda_port": 8100,
            "in_process": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else {
            done("配置写不出来")
            return
        }
        launcher = poki_launcher_new(json, PhoneLink.onLaunchEvent, Unmanaged.passUnretained(self).toOpaque())
        guard let launcher else {
            done("launcher 没有建起来")
            return
        }
        poki_launcher_start(launcher)
        // Rust 在后台挂载并重试，事件随后到；这里只把手交回去，成败由事件说。
        done(nil)
    }

    private func launcherEvent(_ text: String) {
        guard let value = PhoneLink.decode(text) else { return }
        let state = value["state"] as? String ?? ""
        let note = value["detail"] as? String ?? value["fix"] as? String ?? ""
        switch state {
        case "running":
            set(.ready, note.isEmpty ? "镜像已挂上，可以操控" : note)
        case "failed":
            set(.failed, note.isEmpty ? "挂载失败" : note)
        case "waiting_network", "connecting", "mounting_ddi", "launching", "idle":
            set(.mounting, note.isEmpty ? "正在连接本机" : note)
        default:
            break
        }
    }

    @objc func stopDevice() {
        if let launcher { poki_launcher_free(launcher) }
        launcher = nil
        stopPairing()
        set(.idle, "")
    }

    // MARK: - 保活

    @objc var locationKeepAlive: Bool {
        get { LocationKeepAlive.shared.running }
        set { LocationKeepAlive.shared.setRunning(newValue) }
    }

    // MARK: - 工具

    private static func decode(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static let onPairEvent: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, text in
        guard let context, let text else { return }
        let link = Unmanaged<PhoneLink>.fromOpaque(context).takeUnretainedValue()
        link.pairEvent(String(cString: text))
    }

    static let onLaunchEvent: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, text in
        guard let context, let text else { return }
        let link = Unmanaged<PhoneLink>.fromOpaque(context).takeUnretainedValue()
        link.launcherEvent(String(cString: text))
    }
}

extension PhoneLink: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        set(.pairing, "已广播，去「设置」里找 Fish Pocket")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        set(.failed, "广播失败：\(errorDict)")
    }
}

/// 定位保活：一个只在开着的定位更新，让 App 退到后台以后不被挂起。
///
/// 它会一直有一条定位在跑，所以「设置 → 隐私与安全性 → 定位服务」里会看到 App 在用位置；
/// 页面上的说明和它一致。
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = LocationKeepAlive()
    private let manager = CLLocationManager()
    private(set) var running = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: PhoneLink.stateChanged, object: nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if running, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
