import Compression
import Foundation
import SwiftUI
import UIKit

/// 一只宠物包：dsh-Go 创意工坊同款，一个目录里有 `pack.json` 和若干平铺 PNG。
///
/// `pack.json` 只用到这几项：名字、作者、图和动画。每个动画是一张图集，
/// `frameW × frameH` 一格、`cols` 列排下来，`frames` 给出播放顺序（每项 `i` 是图集里的格号）。
struct PetPack: Identifiable, Equatable {
    let id: String
    let name: String
    let author: String
    let dir: URL
    let animations: [String: PetAnim]

    static func == (a: PetPack, b: PetPack) -> Bool { a.id == b.id }

    /// 读一个包目录里的 pack.json；缺文件或格式不对就返回 nil。
    static func load(_ dir: URL) -> PetPack? {
        let json = dir.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw = root["animations"] as? [String: Any] ?? [:]
        var animations: [String: PetAnim] = [:]
        for (key, value) in raw {
            guard let spec = value as? [String: Any],
                  let sheet = spec["sheet"] as? String,
                  let cols = spec["cols"] as? Int,
                  let frameW = spec["frameW"] as? Double,
                  let frameH = spec["frameH"] as? Double,
                  let box = spec["box"] as? [String: Any],
                  let boxX = box["x"] as? Double, let boxY = box["y"] as? Double,
                  let boxW = box["w"] as? Double, let boxH = box["h"] as? Double
            else { continue }
            let list = (spec["frames"] as? [[String: Any]]) ?? []
            let indexes = list.compactMap { $0["i"] as? Int }
            let steps = list.compactMap { $0["ms"] as? Double }
            // 帧表可能是空的：那就按 cols 铺满、每帧一样长。
            let count = indexes.isEmpty ? max(cols, 1) : indexes.count
            let total = steps.reduce(0, +)
            let fps = total > 0 ? Double(count) * 1000 / total : 8
            animations[key] = PetAnim(
                sheet: dir.appendingPathComponent(sheet),
                frameW: frameW, frameH: frameH, cols: max(cols, 1),
                box: CGRect(x: boxX, y: boxY, width: boxW, height: boxH),
                indexes: indexes.isEmpty ? Array(0..<count) : indexes,
                fps: min(max(fps, 2), 24)
            )
        }
        guard !animations.isEmpty else { return nil }
        let id = (root["id"] as? String) ?? dir.lastPathComponent
        return PetPack(
            id: id,
            name: (root["name"] as? String) ?? id,
            author: (root["author"] as? String) ?? "",
            dir: dir,
            animations: animations
        )
    }
}

/// 一个动画的取帧方式。
struct PetAnim {
    let sheet: URL
    let frameW: CGFloat
    let frameH: CGFloat
    let cols: Int
    let box: CGRect
    /// 播放顺序：每个元素是图集里的格号。
    let indexes: [Int]
    let fps: Double

    /// 按格号算在网格里的行列。
    func origin(_ slot: Int) -> (col: Int, row: Int) {
        (slot % cols, slot / cols)
    }
}

/// 装了哪些宠物、现在用哪只。图集解码后留在内存里，来回切换不再读盘。
final class PetStore: ObservableObject {
    static let shared = PetStore()

    /// 内置的那只：图集在 bundle 根目录，数据写死在 `PetStage` 里。
    static let builtinID = "deepy-whale"

    @Published private(set) var packs: [PetPack] = []
    @Published var currentID: String {
        didSet { UserDefaults.standard.set(currentID, forKey: "dsh.pet.current") }
    }

    /// 导入目录：App 自己的 Documents/pets，一只一个文件夹。
    var root: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var cache = NSCache<NSString, UIImage>()

    private init() {
        currentID = UserDefaults.standard.string(forKey: "dsh.pet.current") ?? Self.builtinID
        reload()
    }

    var current: PetPack? {
        packs.first { $0.id == currentID }
    }

    /// 现在用的是不是内置那只。
    var usingBuiltin: Bool { currentID == Self.builtinID || currentID.isEmpty }

    func reload() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        packs = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { PetPack.load($0) }
            .sorted { $0.name < $1.name }
        if usingBuiltin == false, current == nil {
            currentID = Self.builtinID
        }
    }

    /// 导入一个宠物 zip：解到 `pets/<名字>/`，成功就切过去。
    @discardableResult
    func importZip(_ url: URL) throws -> PetPack {
        let fm = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "-")
        let target = root.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try ZipReader.unzip(url, into: target)
        // 包里可能多套一层目录（zip 时选了整个文件夹），往里找一层 pack.json。
        var candidate = target
        if PetPack.load(target) == nil {
            let inner = (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? []
            if let nested = inner.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
                candidate = nested
            }
        }
        guard let pack = PetPack.load(candidate) else {
            try? fm.removeItem(at: target)
            throw ImportError.noPackJSON
        }
        reload()
        currentID = pack.id
        return pack
    }

    func delete(_ pack: PetPack) {
        try? FileManager.default.removeItem(at: pack.dir)
        if currentID == pack.id { currentID = Self.builtinID }
        reload()
    }

    func image(for anim: PetAnim) -> UIImage? {
        let key = anim.sheet.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(contentsOfFile: anim.sheet.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    enum ImportError: LocalizedError {
        case noPackJSON
        var errorDescription: String? { "这个包里没有 pack.json" }
    }
}

/// 只解 zip 的 DEFLATE/存储两种条目 —— 宠物包够用，不引第三方库。
enum ZipReader {
    static func unzip(_ url: URL, into dir: URL) throws {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        // 从尾巴往前找中央目录结尾（EOCD），签名 0x06054b50。
        var eocd = -1
        let lowerBound = max(0, bytes.count - 66000)
        var i = bytes.count - 22
        while i >= lowerBound {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.badArchive }
        let count = Int(read16(bytes, eocd + 10))
        let cdOffset = Int(read32(bytes, eocd + 16))

        let fm = FileManager.default
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, read32(bytes, p) == 0x02014b50 else { break }
            let method = Int(read16(bytes, p + 10))
            let compSize = Int(read32(bytes, p + 20))
            let uncompSize = Int(read32(bytes, p + 24))
            let nameLen = Int(read16(bytes, p + 28))
            let extraLen = Int(read16(bytes, p + 30))
            let commentLen = Int(read16(bytes, p + 32))
            let localOffset = Int(read32(bytes, p + 42))
            let name = String(decoding: bytes[(p + 46)..<min(p + 46 + nameLen, bytes.count)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            // 目录条目只建出来。
            let target = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // 本地头：签名 30 字节 + 文件名 + 扩展区，之后才是压缩数据。
            guard localOffset + 30 <= bytes.count, read32(bytes, localOffset) == 0x04034b50 else { continue }
            let lNameLen = Int(read16(bytes, localOffset + 26))
            let lExtraLen = Int(read16(bytes, localOffset + 28))
            let start = localOffset + 30 + lNameLen + lExtraLen
            guard start + compSize <= bytes.count else { continue }
            let payload = Data(bytes[start..<(start + compSize)])

            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch method {
            case 0:
                try payload.write(to: target)
            case 8:
                guard let out = inflate(payload, expected: uncompSize) else { throw ZipError.badEntry(name) }
                try out.write(to: target)
            default:
                continue
            }
        }
    }

    private static func read16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private static func read32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// zip 里的 deflate 是裸流，正好对上 COMPRESSION_ZLIB。
    private static func inflate(_ data: Data, expected: Int) -> Data? {
        guard expected > 0 else { return Data() }
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, expected, srcBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? out.prefix(written) : nil
    }

    enum ZipError: LocalizedError {
        case badArchive
        case badEntry(String)
        var errorDescription: String? {
            switch self {
            case .badArchive: "这个文件不是 zip"
            case .badEntry(let name): "包里的 \(name) 解不开"
            }
        }
    }
}
