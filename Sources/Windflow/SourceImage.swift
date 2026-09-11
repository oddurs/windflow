import AppKit
import CoreGraphics
import Foundation

/// Everything derived from one photograph that the painting reads but never
/// writes: the graded colour, its pyramid, and where the fine detail is.
///
/// It is a separate object purely so it can be built off the render thread.
/// Grading a full frame, building the pyramid and scanning for detail costs a
/// couple of hundred milliseconds, and doing that where the frames are drawn
/// freezes the screen at every change of picture. Its arrays are immutable once
/// built, so handing them to the canvas is a reference assignment, not a copy.
final class SourceImage {

    let width: Int
    let height: Int

    let level0: [UInt8]  // full resolution, sharp
    let level1: [UInt8]  // half resolution, softened
    let level2: [UInt8]  // quarter resolution, softer still
    let mid1W: Int, mid1H: Int
    let mid2W: Int, mid2H: Int

    /// Centres of the cells with the most local contrast — where fine brushes
    /// are worth spending. Scattering them evenly leaves the detailed regions
    /// mushy and wastes the work on an even sky.
    let detailX: [Float]
    let detailY: [Float]

    init(
        image: CGImage, width: Int, height: Int, saturation: Float,
        coverW: Int, coverH: Int
    ) {
        self.width = width
        self.height = height
        mid1W = max(2, width / 2); mid1H = max(2, height / 2)
        mid2W = max(2, width / 4); mid2H = max(2, height / 4)

        var raw = [UInt8](repeating: 0, count: width * height * 4)
        raw.withUnsafeMutableBytes { buf in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress,
                    width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.interpolationQuality = .high
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = max(CGFloat(width) / iw, CGFloat(height) / ih)
            let dw = iw * scale, dh = ih * scale
            ctx.draw(
                image,
                in: CGRect(
                    x: (CGFloat(width) - dw) / 2,
                    y: (CGFloat(height) - dh) / 2,
                    width: dw, height: dh))
        }

        var l0 = [UInt8](repeating: 0, count: width * height * 4)
        let inv: Float = 1.0 / 255.0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            var r = Float(raw[i]) * inv
            var g = Float(raw[i + 1]) * inv
            var b = Float(raw[i + 2]) * inv
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = l + (r - l) * saturation
            g = l + (g - l) * saturation
            b = l + (b - l) * saturation
            // Almost the identity. The paint converges on exactly what this
            // returns, so every liberty taken here is colour laid on top of the
            // photograph. All that is left is a whisper of contrast, and a floor
            // so pure black does not become a hole no stroke can show up in.
            @inline(__always) func curve(_ v: Float) -> Float {
                let c = min(max(v, 0), 1)
                let s = c * c * (3 - 2 * c)
                return 0.022 + 0.978 * min(max(c * 0.88 + s * 0.12, 0), 1)
            }
            l0[i] = UInt8(min(curve(r), 1) * 255)
            l0[i + 1] = UInt8(min(curve(g), 1) * 255)
            l0[i + 2] = UInt8(min(curve(b), 1) * 255)
            l0[i + 3] = 255
        }

        var l1 = [UInt8](repeating: 0, count: mid1W * mid1H * 4)
        var l2 = [UInt8](repeating: 0, count: mid2W * mid2H * 4)
        SourceImage.downsample(l0, sw: width, sh: height, into: &l1, dw: mid1W, dh: mid1H)
        SourceImage.downsample(l1, sw: mid1W, sh: mid1H, into: &l2, dw: mid2W, dh: mid2H)
        SourceImage.blur(&l1, w: mid1W, h: mid1H, radius: 2)
        SourceImage.blur(&l2, w: mid2W, h: mid2H, radius: 3)
        level0 = l0; level1 = l1; level2 = l2

        // Local contrast per coverage cell; keep the upper half.
        var values = [Float](repeating: 0, count: coverW * coverH)
        for cy in 0..<coverH {
            for cx in 0..<coverW {
                var lo: Float = 1, hi: Float = 0
                for oy in stride(from: 0, to: 8, by: 2) {
                    let y = cy * 8 + oy
                    if y >= height { break }
                    for ox in stride(from: 0, to: 8, by: 2) {
                        let x = cx * 8 + ox
                        if x >= width { break }
                        let o = (y * width + x) * 4
                        let lum =
                            (0.2126 * Float(l0[o]) + 0.7152 * Float(l0[o + 1])
                                + 0.0722 * Float(l0[o + 2])) * inv
                        lo = min(lo, lum); hi = max(hi, lum)
                    }
                }
                values[cy * coverW + cx] = hi - lo
            }
        }
        let sorted = values.sorted()
        let threshold = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.55))]
        var dx = [Float](), dy = [Float]()
        for cy in 0..<coverH {
            for cx in 0..<coverW where values[cy * coverW + cx] > threshold {
                dx.append(Float(cx * 8 + 4))
                dy.append(Float(cy * 8 + 4))
            }
        }
        detailX = dx; detailY = dy
    }

    private static func downsample(
        _ src: [UInt8], sw: Int, sh: Int,
        into dst: inout [UInt8], dw: Int, dh: Int
    ) {
        for y in 0..<dh {
            let sy0 = min(y * 2, sh - 1), sy1 = min(y * 2 + 1, sh - 1)
            for x in 0..<dw {
                let sx0 = min(x * 2, sw - 1), sx1 = min(x * 2 + 1, sw - 1)
                let o = (y * dw + x) * 4
                for c in 0..<3 {
                    let a = Int(src[(sy0 * sw + sx0) * 4 + c])
                    let b = Int(src[(sy0 * sw + sx1) * 4 + c])
                    let cc = Int(src[(sy1 * sw + sx0) * 4 + c])
                    let d = Int(src[(sy1 * sw + sx1) * 4 + c])
                    dst[o + c] = UInt8((a + b + cc + d) >> 2)
                }
                dst[o + 3] = 255
            }
        }
    }

    private static func blur(_ buf: inout [UInt8], w: Int, h: Int, radius: Int) {
        var tmp = buf
        let span = radius * 2 + 1
        for c in 0..<3 {
            for y in 0..<h {
                var acc = 0
                for k in -radius...radius {
                    acc += Int(buf[(y * w + min(max(k, 0), w - 1)) * 4 + c])
                }
                for x in 0..<w {
                    tmp[(y * w + x) * 4 + c] = UInt8(acc / span)
                    acc +=
                        Int(buf[(y * w + min(x + radius + 1, w - 1)) * 4 + c])
                        - Int(buf[(y * w + max(x - radius, 0)) * 4 + c])
                }
            }
            for x in 0..<w {
                var acc = 0
                for k in -radius...radius {
                    acc += Int(tmp[(min(max(k, 0), h - 1) * w + x) * 4 + c])
                }
                for y in 0..<h {
                    buf[(y * w + x) * 4 + c] = UInt8(acc / span)
                    acc +=
                        Int(tmp[(min(y + radius + 1, h - 1) * w + x) * 4 + c])
                        - Int(tmp[(max(y - radius, 0) * w + x) * 4 + c])
                }
            }
        }
    }
}
