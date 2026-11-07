import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Covers: memory, then disk, then the house. Decoded and shrunk to the size they are
/// drawn at off the main thread, so a list scrolls without decoding 1000 px JPEGs.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private let lock = NSLock()
    private var inflight: [String: Task<Data?, Never>] = [:]

    var api: API?

    static func memoryKey(_ url: URL, _ pixels: Int) -> NSString {
        "\(url.absoluteString)#\(pixels)" as NSString
    }

    func cached(_ url: URL, pixels: Int) -> UIImage? {
        memory.object(forKey: ImagePipeline.memoryKey(url, pixels))
    }

    private func diskFile(_ url: URL) -> URL {
        let h = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(String(h.prefix(40)))
    }

    func image(_ url: URL, pixels: Int) async -> UIImage? {
        let key = ImagePipeline.memoryKey(url, pixels)
        if let m = memory.object(forKey: key) { return m }
        guard let data = await bytes(url) else { return nil }
        guard let img = ImagePipeline.downsample(data, pixels: pixels) else { return nil }
        memory.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
        return img
    }

    /// The file's bytes: from disk, or fetched once however many views ask at once.
    private func bytes(_ url: URL) async -> Data? {
        let file = diskFile(url)
        if let d = try? Data(contentsOf: file) { return d }
        let k = url.absoluteString
        let task: Task<Data?, Never> = startOrJoin(k) { [weak self] in
            guard let self = self, let api = self.api else { return nil }
            do {
                let (d, r) = try await api.transport.send(api.authorized(url))
                guard r.statusCode == 200, !d.isEmpty else { return nil }
                try? d.write(to: file, options: .atomic)
                return d
            } catch {
                return nil
            }
        }
        let d = await task.value
        finished(k)
        return d
    }

    private func startOrJoin(_ k: String, _ make: @escaping @Sendable () async -> Data?) -> Task<Data?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let t = inflight[k] { return t }
        let t = Task.detached(priority: .userInitiated) { await make() }
        inflight[k] = t
        return t
    }

    private func finished(_ k: String) {
        lock.lock()
        inflight[k] = nil
        lock.unlock()
    }

    static func downsample(_ data: Data, pixels: Int) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumb = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixels, 16),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb) else { return nil }
        return UIImage(cgImage: cg)
    }

    func diskBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// A cover at a fixed size, its own colour shown until the picture is there.
struct CoverView: View {
    let url: URL?
    var color: String? = nil
    let size: CGFloat
    var radius: CGFloat = 4

    var body: some View {
        CoverImage(url: url, color: color, pixels: Int(size * UIScreen.main.scale))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A cover filling whatever frame it is given.
struct CoverImage: View {
    let url: URL?
    var color: String?
    let pixels: Int
    @State private var image: UIImage?

    init(url: URL?, color: String?, pixels: Int) {
        self.url = url
        self.color = color
        self.pixels = pixels
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0, pixels: pixels) })
    }

    var body: some View {
        ZStack {
            Theme.placeholder(color)
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if url == nil {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.faint)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url = url else { image = nil; return }
            if let m = ImagePipeline.shared.cached(url, pixels: pixels) {
                image = m
                return
            }
            let got = await ImagePipeline.shared.image(url, pixels: pixels)
            if !Task.isCancelled, let got = got {
                withAnimation(.easeOut(duration: 0.15)) { image = got }
            }
        }
    }
}
