import AppKit
import Foundation

struct VisionImagePayload {
    let data: Data
    let mime: String // image/png or image/jpeg
    let width: Int
    let height: Int
    let bytes: Int
    let format: String
}

enum VisionImageEncoder {
    /// API 전송용 — 작게·JPEG로 올려 업로드/토큰 지연을 줄임.
    /// - Parameter fast: true면 긴 변 ~1600, 품질 낮춤 (일반 풀이)
    static func encodeForAPI(_ image: NSImage, fast: Bool = true) -> VisionImagePayload? {
        let maxEdge: CGFloat = fast ? 1600 : 2048
        let prepared = image.scaledToLongEdge(max: maxEdge) ?? image
        let size = prepared.pixelSize
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        guard let rep = bitmapRep(from: prepared) else { return nil }

        var quality: CGFloat = fast ? 0.82 : 0.90
        var jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        let limit = fast ? 1_200_000 : 2_500_000
        while let d = jpeg, d.count > limit, quality > 0.55 {
            quality -= 0.05
            jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        guard let data = jpeg else { return nil }
        saveDebug(data, ext: "jpg")
        return VisionImagePayload(
            data: data,
            mime: "image/jpeg",
            width: w,
            height: h,
            bytes: data.count,
            format: String(format: "api-jpg q=%.2f", quality)
        )
    }

    /// 로컬 OCR/디버그용 고해상도 (기존)
    static func encode(_ image: NSImage) -> VisionImagePayload? {
        let prepared = image.scaledToLongEdge(max: 2880) ?? image
        let size = prepared.pixelSize
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))

        guard let rep = bitmapRep(from: prepared) else { return nil }

        if let png = rep.representation(using: .png, properties: [:]), png.count <= 8_000_000 {
            saveDebug(png, ext: "png")
            return VisionImagePayload(data: png, mime: "image/png", width: w, height: h, bytes: png.count, format: "png")
        }

        var quality: CGFloat = 0.97
        var jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        while let d = jpeg, d.count > 12_000_000, quality > 0.75 {
            quality -= 0.04
            jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        guard let data = jpeg else { return nil }
        saveDebug(data, ext: "jpg")
        return VisionImagePayload(
            data: data,
            mime: "image/jpeg",
            width: w,
            height: h,
            bytes: data.count,
            format: String(format: "jpg q=%.2f", quality)
        )
    }

    private static func bitmapRep(from image: NSImage) -> NSBitmapImageRep? {
        let px = image.pixelSize
        guard px.width > 0, px.height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(px.width),
            pixelsHigh: Int(px.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: px.width, height: px.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: px.width, height: px.height),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func saveDebug(_ data: Data, ext: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Solv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("last-capture.\(ext)")
        try? data.write(to: url)
        // 이전 포맷 잔여 삭제
        let other = ext == "png" ? "jpg" : "png"
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("last-capture.\(other)"))
    }
}

extension NSImage {
    var pixelSize: CGSize {
        if let rep = representations.first, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return CGSize(width: size.width, height: size.height)
    }

    /// 긴 변만 줄임. 이미 작으면 원본.
    func scaledToLongEdge(max maxEdge: CGFloat) -> NSImage? {
        let px = pixelSize
        let long = max(px.width, px.height)
        guard long > maxEdge, long > 0 else { return self }
        let scale = maxEdge / long
        let nw = max(1, (px.width * scale).rounded())
        let nh = max(1, (px.height * scale).rounded())
        let out = NSImage(size: NSSize(width: nw, height: nh))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: NSRect(x: 0, y: 0, width: nw, height: nh),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        out.unlockFocus()
        return out
    }
}
