import Foundation
import AppKit
import CoreGraphics

/// The drawing surface. Three layers, all at render resolution or a fraction of
/// it:
///
///  * `target` — the graded photograph. Never drawn directly; it is only ever
///    revealed through `reveal`.
///  * `reveal` — a coverage mask that grows wherever a line has passed. Half
///    resolution, because it is a smooth field and nobody can see the difference.
///  * `glow`   — additive light from the lines themselves, faded every frame.
///    The fade is what turns a moving point into a streak.
///
/// The final frame is `target * reveal + glow + bloom(glow)`, so every lit pixel
/// on screen was put there by something that moved through it.
final class Canvas {

    let width: Int
    let height: Int

    /// Graded photograph, RGBX at render resolution.
    private(set) var target: [UInt8]
    /// Line colour for each pixel: the photograph's hue held at a high, even
    /// value. Sampling `target` directly would make lines invisible over the
    /// dark parts of the image, which is where the interesting structure is.
    private(set) var lineColor: [UInt8]

    private let revealW: Int
    private let revealH: Int
    private var reveal: [UInt16]

    private var glow: [UInt8]           // RGBX, additive, faded each frame

    private let bloomW: Int
    private let bloomH: Int
    private var bloom: [Float]
    private var bloomScratch: [Float]

    private let xRev0: [Int32]
    private let xRev1: [Int32]
    private let xRevF: [Float]
    private let xBloom0: [Int32]
    private let xBloom1: [Int32]
    private let xBloomF: [Float]
    private let xVignette: [Float]

    private let bytesPerRow: Int
    private let byteCount: Int
    private var outputs: [UnsafeMutableRawPointer]
    private var nextOutput = 0

    init(width: Int, height: Int) {
        self.width = max(16, width)
        self.height = max(16, height)
        let n = self.width * self.height

        target = [UInt8](repeating: 0, count: n * 4)
        lineColor = [UInt8](repeating: 0, count: n * 4)

        revealW = max(8, self.width / 2)
        revealH = max(8, self.height / 2)
        reveal = [UInt16](repeating: 0, count: revealW * revealH)

        glow = [UInt8](repeating: 0, count: n * 4)

        bloomW = max(4, self.width / 4)
        bloomH = max(4, self.height / 4)
        bloom = [Float](repeating: 0, count: bloomW * bloomH * 3)
        bloomScratch = [Float](repeating: 0, count: bloomW * bloomH * 3)

        var r0 = [Int32](), r1 = [Int32](), rf = [Float]()
        var b0 = [Int32](), b1 = [Int32](), bf = [Float]()
        var vx = [Float]()
        let halfW = Float(self.width) * 0.5, halfH = Float(self.height) * 0.5
        let invR2 = 1 / (halfW * halfW + halfH * halfH)
        for x in 0..<self.width {
            let rx = Float(x) * 0.5
            let i0 = min(Int(rx), revealW - 1)
            r0.append(Int32(i0)); r1.append(Int32(min(i0 + 1, revealW - 1)))
            rf.append(rx - Float(i0))

            let bx = Float(x) * 0.25
            let j0 = min(Int(bx), bloomW - 1)
            b0.append(Int32(j0)); b1.append(Int32(min(j0 + 1, bloomW - 1)))
            bf.append(bx - Float(j0))

            let dx = Float(x) - halfW
            vx.append(dx * dx * invR2)
        }
        xRev0 = r0; xRev1 = r1; xRevF = rf
        xBloom0 = b0; xBloom1 = b1; xBloomF = bf
        xVignette = vx

        bytesPerRow = self.width * 4
        byteCount = bytesPerRow * self.height
        let bytes = byteCount
        var allocated: [UnsafeMutableRawPointer] = []
        for _ in 0..<3 {
            let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            memset(p, 0, bytes)
            allocated.append(p)
        }
        outputs = allocated
    }

    deinit { outputs.forEach { $0.deallocate() } }

    // MARK: - Image

    /// Aspect-fill the photograph, then grade it: saturation up, a filmic
    /// rolloff, and shadows lifted into a cold blue-black instead of a dead
    /// neutral. Glacial water goes properly deep; sunlit silt glows.
    func setImage(_ image: CGImage, saturation: Float) {
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        raw.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress,
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
            ctx.draw(image, in: CGRect(x: (CGFloat(width) - dw) / 2,
                                       y: (CGFloat(height) - dh) / 2,
                                       width: dw, height: dh))
        }

        let shadow: (Float, Float, Float) = (0.010, 0.017, 0.038)
        let inv: Float = 1.0 / 255.0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            var r = Float(raw[i]) * inv
            var g = Float(raw[i + 1]) * inv
            var b = Float(raw[i + 2]) * inv
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b

            r = l + (r - l) * saturation
            g = l + (g - l) * saturation
            b = l + (b - l) * saturation

            @inline(__always) func curve(_ v: Float) -> Float {
                let c = min(max(v, 0), 1)
                let s = c * c * (3 - 2 * c)
                return min(max(c * 0.40 + s * 0.60, 0), 1)
            }
            r = curve(r); g = curve(g); b = curve(b)

            let lift = 1 - min(max(l * 1.6, 0), 1)
            r = min(r + shadow.0 * lift, 1)
            g = min(g + shadow.1 * lift, 1)
            b = min(b + shadow.2 * lift, 1)

            target[i] = UInt8(r * 255)
            target[i + 1] = UInt8(g * 255)
            target[i + 2] = UInt8(b * 255)
            target[i + 3] = 255

            // Hue-preserving value normalisation for the line colour: scale all
            // three channels by one factor, so the hue and saturation are
            // untouched and only the brightness is raised.
            let m = max(r, max(g, b))
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if m > 0.004 {
                let wanted = 0.62 + 0.38 * powf(lum, 0.5)
                let f = min(wanted / m, 14)
                lineColor[i] = UInt8(min(r * f, 1) * 255)
                lineColor[i + 1] = UInt8(min(g * f, 1) * 255)
                lineColor[i + 2] = UInt8(min(b * f, 1) * 255)
            } else {
                lineColor[i] = 40; lineColor[i + 1] = 60; lineColor[i + 2] = 90
            }
            lineColor[i + 3] = 255
        }
    }

    func reset() {
        for i in 0..<reveal.count { reveal[i] = 0 }
        for i in 0..<glow.count { glow[i] = 0 }
    }

    /// Mean coverage, sampled. Drives the reveal-to-hold transition.
    func meanReveal() -> Float {
        var sum: Float = 0
        var count = 0
        let step = max(1, reveal.count / 4000)
        var i = 0
        while i < reveal.count { sum += Float(reveal[i]); count += 1; i += step }
        return count > 0 ? sum / Float(count) / 65535 : 0
    }

    /// Coverage at a canvas coordinate, clamped — callers sample slightly
    /// outside the frame when choosing where to start a line.
    func revealFraction(atX x: Float, y: Float) -> Float {
        let rx = min(max(Int(x * 0.5), 0), revealW - 1)
        let ry = min(max(Int(y * 0.5), 0), revealH - 1)
        return Float(reveal[ry * revealW + rx]) / 65535
    }

    /// Separable box blur over the coverage mask. Used sparingly and late.
    func smoothReveal() {
        let w = revealW, h = revealH
        var scratch = [UInt16](repeating: 0, count: reveal.count)
        reveal.withUnsafeMutableBufferPointer { r in
            scratch.withUnsafeMutableBufferPointer { t in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        let a = UInt32(r[row + max(x - 1, 0)])
                        let b = UInt32(r[row + x])
                        let c = UInt32(r[row + min(x + 1, w - 1)])
                        t[row + x] = UInt16((a + b + b + c) >> 2)
                    }
                }
                for x in 0..<w {
                    for y in 0..<h {
                        let a = UInt32(t[max(y - 1, 0) * w + x])
                        let b = UInt32(t[y * w + x])
                        let c = UInt32(t[min(y + 1, h - 1) * w + x])
                        r[y * w + x] = UInt16((a + b + b + c) >> 2)
                    }
                }
            }
        }
    }

    func decayReveal(_ keep: Float) {
        let k = UInt32(min(max(keep, 0), 1) * 65536)
        reveal.withUnsafeMutableBufferPointer { r in
            for i in 0..<r.count { r[i] = UInt16((UInt32(r[i]) &* k) >> 16) }
        }
    }

    /// The coverage mask as a greyscale image, for diagnosing holes the wind
    /// never reaches. Not used by the screensaver itself.
    func debugRevealImage() -> CGImage? {
        var g = [UInt8](repeating: 0, count: revealW * revealH)
        for i in 0..<g.count { g[i] = UInt8(reveal[i] >> 8) }
        return g.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress,
                                      width: revealW, height: revealH,
                                      bitsPerComponent: 8, bytesPerRow: revealW,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    /// Fraction of the mask still below a threshold, for diagnostics.
    func debugCoverageHistogram() -> [Int] {
        var bins = [Int](repeating: 0, count: 10)
        for v in reveal { bins[min(Int(v) * 10 / 65536, 9)] += 1 }
        return bins
    }

    // MARK: - Deposition

    /// Additive, anti-aliased point into the glow layer. Consecutive calls a
    /// fraction of a pixel apart lay down a continuous line.
    @inline(__always)
    func addLight(x: Float, y: Float, intensity: Float) {
        if x < 0 || y < 0 || x >= Float(width - 1) || y >= Float(height - 1) { return }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let base = y0 * width + x0

        glow.withUnsafeMutableBufferPointer { g in
            lineColor.withUnsafeBufferPointer { lc in
                @inline(__always) func put(_ p: Int, _ w: Float) {
                    let a = w * intensity
                    if a <= 0.002 { return }
                    let o = p * 4
                    let ar = Int(Float(lc[o]) * a)
                    let ag = Int(Float(lc[o + 1]) * a)
                    let ab = Int(Float(lc[o + 2]) * a)
                    g[o] = UInt8(min(Int(g[o]) + ar, 255))
                    g[o + 1] = UInt8(min(Int(g[o + 1]) + ag, 255))
                    g[o + 2] = UInt8(min(Int(g[o + 2]) + ab, 255))
                }
                put(base, (1 - fx) * (1 - fy))
                put(base + 1, fx * (1 - fy))
                put(base + width, (1 - fx) * fy)
                put(base + width + 1, fx * fy)
            }
        }
    }

    /// Widen the reveal relative to the line. The lit stroke stays hairline
    /// sharp while the photograph behind it fills in on a softer brush, so the
    /// image assembles smoothly instead of in visible scratches.
    @inline(__always)
    func addReveal(x: Float, y: Float, amount: Float) {
        if x < -64 || y < -64 || x > Float(width + 64) || y > Float(height + 64) { return }
        let cx = Int(x * 0.5), cy = Int(y * 0.5)
        let gain = min(max(amount, 0), 1)
        reveal.withUnsafeMutableBufferPointer { r in
            for dy in -2...2 {
                let row = min(max(cy + dy, 0), revealH - 1) * revealW
                for dx in -2...2 {
                    let d2 = dx * dx + dy * dy
                    if d2 > 4 { continue }
                    let w = Canvas.brush[d2]
                    let i = row + min(max(cx + dx, 0), revealW - 1)
                    let current = Float(r[i])
                    r[i] = UInt16(min(current + (65535 - current) * gain * w, 65535))
                }
            }
        }
    }

    /// Falloff by squared distance for the reveal brush, indexed by dx²+dy².
    private static let brush: [Float] = [1.0, 0.72, 0.52, 0, 0.30]

    // MARK: - Frame

    /// Fade the trails, build the bloom from what is left, and flatten the three
    /// layers into a displayable frame.
    func present(fade: Float, bloomAmount: Float, vignetteAmount: Float) -> CGImage? {
        fadeGlow(fade)
        buildBloom()
        return composite(bloomAmount: bloomAmount, vignetteAmount: vignetteAmount)
    }

    private func fadeGlow(_ keep: Float) {
        let k = UInt32(min(max(keep, 0), 1) * 256)
        let w = width, h = height
        glow.withUnsafeMutableBufferPointer { g in
            let bands = min(h, max(1, ProcessInfo.processInfo.activeProcessorCount))
            let rowsPer = (h + bands - 1) / bands
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let y0 = band * rowsPer, y1 = min(h, y0 + rowsPer)
                if y0 >= y1 { return }
                for i in stride(from: y0 * w * 4, to: y1 * w * 4, by: 1) {
                    let v = UInt32(g[i])
                    if v == 0 { continue }
                    // The -1 guarantees the tail actually reaches zero; a pure
                    // multiply leaves a permanent smear of 1s behind every line.
                    let faded = (v &* k) >> 8
                    g[i] = UInt8(faded > 0 ? faded &- 1 : 0)
                }
            }
        }
    }

    private func buildBloom() {
        let bw = bloomW, bh = bloomH, w = width
        let h = height
        glow.withUnsafeBufferPointer { g in
            bloom.withUnsafeMutableBufferPointer { b in
                let bands = min(bh, max(1, ProcessInfo.processInfo.activeProcessorCount))
                let rowsPer = (bh + bands - 1) / bands
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let y0 = band * rowsPer, y1 = min(bh, y0 + rowsPer)
                    if y0 >= y1 { return }
                    for by in y0..<y1 {
                        for bx in 0..<bw {
                            // Four of the sixteen source pixels, not all of them:
                            // two blur passes follow, so the extra reads buy
                            // nothing visible and this pass is memory-bound.
                            var r: Float = 0, gg: Float = 0, bb: Float = 0
                            for dy in stride(from: 0, to: 4, by: 2) {
                                let sy = by * 4 + dy
                                if sy >= h { break }
                                for dx in stride(from: 0, to: 4, by: 2) {
                                    let sx = bx * 4 + dx
                                    if sx >= w { break }
                                    let o = (sy * w + sx) * 4
                                    r += Float(g[o]); gg += Float(g[o + 1]); bb += Float(g[o + 2])
                                }
                            }
                            let o = (by * bw + bx) * 3
                            b[o] = r * 0.25; b[o + 1] = gg * 0.25; b[o + 2] = bb * 0.25
                        }
                    }
                }
            }
        }
        blurBloom(radius: 2)
        blurBloom(radius: 4)
    }

    private func blurBloom(radius: Int) {
        let bw = bloomW, bh = bloomH
        bloom.withUnsafeMutableBufferPointer { src in
            bloomScratch.withUnsafeMutableBufferPointer { dst in
                let inv = 1 / Float(radius * 2 + 1)
                for y in 0..<bh {
                    for c in 0..<3 {
                        var acc: Float = 0
                        for k in -radius...radius {
                            acc += src[(y * bw + min(max(k, 0), bw - 1)) * 3 + c]
                        }
                        for x in 0..<bw {
                            dst[(y * bw + x) * 3 + c] = acc * inv
                            let out = min(max(x - radius, 0), bw - 1)
                            let inn = min(max(x + radius + 1, 0), bw - 1)
                            acc += src[(y * bw + inn) * 3 + c] - src[(y * bw + out) * 3 + c]
                        }
                    }
                }
                for x in 0..<bw {
                    for c in 0..<3 {
                        var acc: Float = 0
                        for k in -radius...radius {
                            acc += dst[(min(max(k, 0), bh - 1) * bw + x) * 3 + c]
                        }
                        for y in 0..<bh {
                            src[(y * bw + x) * 3 + c] = acc * inv
                            let out = min(max(y - radius, 0), bh - 1)
                            let inn = min(max(y + radius + 1, 0), bh - 1)
                            acc += dst[(inn * bw + x) * 3 + c] - dst[(out * bw + x) * 3 + c]
                        }
                    }
                }
            }
        }
    }

    private func composite(bloomAmount: Float, vignetteAmount: Float) -> CGImage? {
        let out = outputs[nextOutput]
        nextOutput = (nextOutput + 1) % outputs.count

        let w = width, h = height
        let rw = revealW, rh = revealH
        let bw = bloomW, bh = bloomH
        let stride = bytesPerRow
        let halfH = Float(h) * 0.5
        let invR2 = 1 / (Float(w) * 0.5 * Float(w) * 0.5 + halfH * halfH)

        target.withUnsafeBufferPointer { tgt in
        glow.withUnsafeBufferPointer { gl in
        reveal.withUnsafeBufferPointer { rev in
        bloom.withUnsafeBufferPointer { bl in
        xRev0.withUnsafeBufferPointer { xr0 in
        xRev1.withUnsafeBufferPointer { xr1 in
        xRevF.withUnsafeBufferPointer { xrf in
        xBloom0.withUnsafeBufferPointer { xb0 in
        xBloom1.withUnsafeBufferPointer { xb1 in
        xBloomF.withUnsafeBufferPointer { xbf in
        xVignette.withUnsafeBufferPointer { xvg in
            let bands = min(h, max(1, ProcessInfo.processInfo.activeProcessorCount))
            let rowsPer = (h + bands - 1) / bands
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let y0 = band * rowsPer, y1 = min(h, y0 + rowsPer)
                if y0 >= y1 { return }

                for y in y0..<y1 {
                    let ry = Float(y) * 0.5
                    let ry0 = min(Int(ry), rh - 1)
                    let ry1 = min(ry0 + 1, rh - 1)
                    let ryf = ry - Float(ry0)
                    let revRow0 = ry0 * rw, revRow1 = ry1 * rw

                    let byv = Float(y) * 0.25
                    let by0 = min(Int(byv), bh - 1)
                    let by1 = min(by0 + 1, bh - 1)
                    let byf = byv - Float(by0)
                    let bloomRow0 = by0 * bw, bloomRow1 = by1 * bw

                    let dyv = Float(y) - halfH
                    let yq = dyv * dyv * invR2

                    let row = out.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    var o = y * w * 4

                    for x in 0..<w {
                        let i0 = Int(xr0[x]), i1 = Int(xr1[x])
                        let fx = xrf[x]
                        let r00 = Float(rev[revRow0 + i0]), r10 = Float(rev[revRow0 + i1])
                        let r01 = Float(rev[revRow1 + i0]), r11 = Float(rev[revRow1 + i1])
                        let top = r00 + (r10 - r00) * fx
                        let bot = r01 + (r11 - r01) * fx
                        let cover = (top + (bot - top) * ryf) * (1.0 / 65535)

                        let j0 = Int(xb0[x]) * 3, j1 = Int(xb1[x]) * 3
                        let gx = xbf[x]
                        let p00 = bloomRow0 * 3, p01 = bloomRow1 * 3

                        let q = xvg[x] + yq
                        let vig = 1 - vignetteAmount * q * q
                        let bloomScale = bloomAmount * vig

                        var rgb = (Float(0), Float(0), Float(0))
                        for c in 0..<3 {
                            let a = bl[p00 + j0 + c], b = bl[p00 + j1 + c]
                            let cc = bl[p01 + j0 + c], d = bl[p01 + j1 + c]
                            let t = a + (b - a) * gx
                            let u = cc + (d - cc) * gx
                            let value = (t + (u - t) * byf) * bloomScale
                                + (Float(tgt[o + c]) * cover + Float(gl[o + c])) * vig
                            switch c {
                            case 0: rgb.0 = value
                            case 1: rgb.1 = value
                            default: rgb.2 = value
                            }
                        }

                        let p = x * 4
                        row[p] = UInt8(min(max(rgb.2, 0), 255))
                        row[p + 1] = UInt8(min(max(rgb.1, 0), 255))
                        row[p + 2] = UInt8(min(max(rgb.0, 0), 255))
                        row[p + 3] = 255
                        o += 4
                    }
                }
            }
        }}}}}}}}}}}

        guard let provider = CGDataProvider(dataInfo: nil, data: out,
                                            size: byteCount, releaseData: { _, _, _ in })
        else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue:
                            CGImageAlphaInfo.noneSkipFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
