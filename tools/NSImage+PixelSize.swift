import AppKit

extension NSImage {
    var pixelSize: CGSize {
        if let rep = representations.first, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return CGSize(width: size.width, height: size.height)
    }
}
