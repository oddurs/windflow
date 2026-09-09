import Foundation
import AppKit
import CoreGraphics

/// The drawing surface.
///
/// The photograph is never composited. It exists only as `source`, which the
/// tracers *sample* to decide what colour to paint with — the picture you end up
/// looking at is an accumulation of coloured strokes that happens to converge on
/// it. That is the whole idea: no layer of the real image is ever shown, so what
/// reads as the photograph is entirely made of wind.
///
/// `source` covers a region **larger** than the visible frame. Tracers live in
/// that larger space and are only drawn where they cross the frame, so lines
/// enter and leave from off-screen instead of dying against a border. The
/// visible canvas is therefore a slight crop into the photograph.
final class Canvas {

    let width: Int
    let height: Int

    /// Fraction of the frame added beyond each edge for tracers to fly in from.
    static let overscan: Float = 0.11

    let marginX: Float
    let marginY: Float

    /// Graded photograph over the overscanned region, RGBX.
    private var source: [UInt8]
    /// Accumulated paint over the visible frame, RGBX at 16 bits so that a
    /// stroke laid down at low opacity still moves the value.
    private var paint: [UInt16]
    /// Additive light at the stroke heads, faded every frame.
    private var glow: [UInt8]

    /// Bookkeeping only — where the wind has been. Never composited; it exists
    /// so new tracers can be aimed at the parts of the frame still untouched,
    /// and so the reveal knows when it is finished.
    private let coverW: Int
    private let coverH: Int
    private var coverage: [UInt16]
    /// Centres of the least-painted cells, refreshed alongside the coverage.
    /// Sampling random candidates and keeping the worst finds broad thin areas
    /// but almost never lands inside a hole a few cells across — and the holes
    /// are precisely what is left at the end, because they sit on the sinks and
    /// centres of the flow where no streamline goes.
    private(set) var holeX: [Float] = []
    private(set) var holeY: [Float] = []

    private let bloomW: Int
    private let bloomH: Int
    private var bloom: [Float]
    private var bloomScratch: [Float]

    private let sourceScaleX: Float
    private let sourceScaleY: Float

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

        marginX = Float(self.width) * Canvas.overscan
        marginY = Float(self.height) * Canvas.overscan
        // A tracer coordinate runs from -margin to size+margin; `source` is
        // stored at frame resolution but represents that whole span.
        sourceScaleX = Float(self.width) / (Float(self.width) + 2 * marginX)
        sourceScaleY = Float(self.height) / (Float(self.height) + 2 * marginY)

        source = [UInt8](repeating: 0, count: n * 4)
        paint = [UInt16](repeating: 0, count: n * 4)
        glow = [UInt8](repeating: 0, count: n * 4)

        coverW = max(8, self.width / 8)
        coverH = max(8, self.height / 8)
        coverage = [UInt16](repeating: 0, count: coverW * coverH)

        bloomW = max(4, self.width / 4)
        bloomH = max(4, self.height / 4)
        bloom = [Float](repeating: 0, count: bloomW * bloomH * 3)
        bloomScratch = [Float](repeating: 0, count: bloomW * bloomH * 3)

        var b0 = [Int32](), b1 = [Int32](), bf = [Float](), vx = [Float]()
        let halfW = Float(self.width) * 0.5, halfH = Float(self.height) * 0.5
        let invR2 = 1 / (halfW * halfW + halfH * halfH)
        for x in 0..<self.width {
            let bx = Float(x) * 0.25
            let j0 = min(Int(bx), bloomW - 1)
            b0.append(Int32(j0)); b1.append(Int32(min(j0 + 1, bloomW - 1)))
            bf.append(bx - Float(j0))
            let dx = Float(x) - halfW
            vx.append(dx * dx * invR2)
        }
        xBloom0 = b0; xBloom1 = b1; xBloomF = bf; xVignette = vx

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

    /// Aspect-fill the photograph across the overscanned region and grade it.
    /// Saturation is pushed hard here: this is the palette every stroke draws
    /// from, and a flat original yields flat wind.
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
            // photograph — which is the one thing this must not look like. All
            // that is left is a whisper of contrast and a floor to keep pure
            // black from becoming a hole no stroke can ever show up in.
            @inline(__always) func curve(_ v: Float) -> Float {
                let c = min(max(v, 0), 1)
                let s = c * c * (3 - 2 * c)
                return 0.022 + 0.978 * min(max(c * 0.88 + s * 0.12, 0), 1)
            }

            source[i] = UInt8(min(curve(r), 1) * 255)
            source[i + 1] = UInt8(min(curve(g), 1) * 255)
            source[i + 2] = UInt8(min(curve(b), 1) * 255)
            source[i + 3] = 255
        }
    }

    func reset() {
        for i in 0..<paint.count { paint[i] = 0 }
        for i in 0..<glow.count { glow[i] = 0 }
        for i in 0..<coverage.count { coverage[i] = 0 }
    }

    // MARK: - Sampling

    /// Bilinear colour lookup in tracer coordinates, which span the overscanned
    /// region from `-margin` to `size + margin`.
    @inline(__always)
    func sourceColor(atX x: Float, y: Float) -> (Float, Float, Float) {
        let sx = (x + marginX) * sourceScaleX
        let sy = (y + marginY) * sourceScaleY
        let cx = min(max(sx, 0), Float(width - 1) - 0.001)
        let cy = min(max(sy, 0), Float(height - 1) - 0.001)
        let x0 = Int(cx), y0 = Int(cy)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let i00 = (y0 * width + x0) * 4
        let i10 = i00 + 4
        let i01 = i00 + width * 4
        let i11 = i01 + 4
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy, w11 = fx * fy
        @inline(__always) func channel(_ c: Int) -> Float {
            (Float(source[i00 + c]) * w00 + Float(source[i10 + c]) * w10
             + Float(source[i01 + c]) * w01 + Float(source[i11 + c]) * w11) * (1.0 / 255)
        }
        return (channel(0), channel(1), channel(2))
    }

    /// Field coordinate for a tracer position, in units of the flow grid.
    @inline(__always)
    func fieldCoordinate(x: Float, y: Float, cols: Int, rows: Int) -> (Float, Float) {
        ((x + marginX) * sourceScaleX * Float(cols) / Float(width),
         (y + marginY) * sourceScaleY * Float(rows) / Float(height))
    }

    // MARK: - Painting

    /// Lay one dab of a stroke. `alpha` blends toward the stroke's colour rather
    /// than adding to it, so overlapping strokes behave like paint instead of
    /// blowing out to white, and the accumulated field converges on the picture.
    @inline(__always)
    func paintDab(x: Float, y: Float, r: Float, g: Float, b: Float, alpha: Float) {
        if x < 0 || y < 0 || x >= Float(width - 1) || y >= Float(height - 1) { return }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let base = (y0 * width + x0) * 4
        let cr = min(max(r, 0), 1) * 65535
        let cg = min(max(g, 0), 1) * 65535
        let cb = min(max(b, 0), 1) * 65535

        paint.withUnsafeMutableBufferPointer { p in
            @inline(__always) func put(_ o: Int, _ w: Float) {
                let a = w * alpha
                if a <= 0.0015 { return }
                p[o] = UInt16(Float(p[o]) + (cr - Float(p[o])) * a)
                p[o + 1] = UInt16(Float(p[o + 1]) + (cg - Float(p[o + 1])) * a)
                p[o + 2] = UInt16(Float(p[o + 2]) + (cb - Float(p[o + 2])) * a)
            }
            put(base, (1 - fx) * (1 - fy))
            put(base + 4, fx * (1 - fy))
            put(base + width * 4, (1 - fx) * fy)
            put(base + width * 4 + 4, fx * fy)
        }
    }

    /// Additive light at the head of a stroke, in the stroke's own colour.
    @inline(__always)
    func addGlow(x: Float, y: Float, r: Float, g: Float, b: Float, intensity: Float) {
        if x < 0 || y < 0 || x >= Float(width - 1) || y >= Float(height - 1) { return }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let base = (y0 * width + x0) * 4

        // Additive, but capped per channel at a little over the stroke's own
        // colour. Uncapped addition means every place several strokes share a
        // path — a strong edge in the photograph, which is exactly where they
        // gather — clips to white and reads as a hard drawn line.
        let capR = min(r * 255 * 1.28, 255)
        let capG = min(g * 255 * 1.28, 255)
        let capB = min(b * 255 * 1.28, 255)
        glow.withUnsafeMutableBufferPointer { gl in
            @inline(__always) func put(_ o: Int, _ w: Float) {
                let a = w * intensity
                if a <= 0.002 { return }
                gl[o] = UInt8(min(Float(gl[o]) + r * 255 * a, capR))
                gl[o + 1] = UInt8(min(Float(gl[o + 1]) + g * 255 * a, capG))
                gl[o + 2] = UInt8(min(Float(gl[o + 2]) + b * 255 * a, capB))
            }
            put(base, (1 - fx) * (1 - fy))
            put(base + 4, fx * (1 - fy))
            put(base + width * 4, (1 - fx) * fy)
            put(base + width * 4 + 4, fx * fy)
        }
    }

    /// Recompute how far the painting has actually got, cell by cell, by
    /// comparing the paint against the photograph it is converging on.
    ///
    /// This replaced a counter incremented wherever the brush touched. That
    /// version marked a cell finished after a handful of dabs, while the paint
    /// underneath needed an order of magnitude more to converge — so new tracers
    /// stopped being aimed at regions that still looked black, and the frame
    /// kept permanent unpainted wedges in the low-traffic parts of the flow.
    func refreshCoverage() {
        coverage.withUnsafeMutableBufferPointer { cov in
            paint.withUnsafeBufferPointer { pt in
                source.withUnsafeBufferPointer { src in
                    for cy in 0..<coverH {
                        for cx in 0..<coverW {
                            var ratio: Float = 0
                            var taken = 0
                            for (ox, oy) in [(2, 2), (6, 2), (2, 6), (6, 6)] {
                                let x = cx * 8 + ox, y = cy * 8 + oy
                                if x >= width || y >= height { continue }
                                let o = (y * width + x) * 4
                                let pl = (0.2126 * Float(pt[o]) + 0.7152 * Float(pt[o + 1])
                                          + 0.0722 * Float(pt[o + 2])) * (1.0 / 65535)
                                let sx = min(Int((Float(x) + marginX) * sourceScaleX), width - 1)
                                let sy = min(Int((Float(y) + marginY) * sourceScaleY), height - 1)
                                let so = (sy * width + sx) * 4
                                let sl = (0.2126 * Float(src[so]) + 0.7152 * Float(src[so + 1])
                                          + 0.0722 * Float(src[so + 2])) * (1.0 / 255)
                                ratio += min(pl / max(sl, 0.02), 1)
                                taken += 1
                            }
                            if taken > 0 {
                                cov[cy * coverW + cx] =
                                    UInt16(min(max(ratio / Float(taken), 0), 1) * 65535)
                            }
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    func coverageAt(x: Float, y: Float) -> Float {
        let cx = min(max(Int(x) / 8, 0), coverW - 1)
        let cy = min(max(Int(y) / 8, 0), coverH - 1)
        return Float(coverage[cy * coverW + cx]) / 65535
    }

    /// Rebuild the list of under-painted cells. Kept to a bounded size by
    /// tightening the threshold rather than by truncating, so the list stays
    /// spread over the frame instead of clustering in whichever region was
    /// scanned first.
    private func rebuildHoles() {
        holeX.removeAll(keepingCapacity: true)
        holeY.removeAll(keepingCapacity: true)
        var threshold: Float = 0.62
        for _ in 0..<3 {
            holeX.removeAll(keepingCapacity: true)
            holeY.removeAll(keepingCapacity: true)
            let cut = UInt16(threshold * 65535)
            for cy in 0..<coverH {
                for cx in 0..<coverW where coverage[cy * coverW + cx] < cut {
                    holeX.append(Float(cx * 8 + 4))
                    holeY.append(Float(cy * 8 + 4))
                }
            }
            if holeX.count <= 900 { break }
            threshold *= 0.6
        }
    }

    func meanCoverage() -> Float {
        var sum: Float = 0
        for v in coverage { sum += Float(v) }
        return sum / Float(coverage.count) / 65535
    }

    /// Fade the painting back toward black; the wind takes the picture away.
    func fadePaint(_ keep: Float) {
        let k = UInt32(min(max(keep, 0), 1) * 65536)
        paint.withUnsafeMutableBufferPointer { p in
            for i in 0..<p.count { p[i] = UInt16((UInt32(p[i]) &* k) >> 16) }
        }
        coverage.withUnsafeMutableBufferPointer { c in
            for i in 0..<c.count { c[i] = UInt16((UInt32(c[i]) &* k) >> 16) }
        }
    }

    // MARK: - Frame

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
                for i in (y0 * w * 4)..<(y1 * w * 4) {
                    let v = UInt32(g[i])
                    if v == 0 { continue }
                    // The -1 guarantees the tail reaches zero; a pure multiply
                    // leaves a permanent smear of 1s behind every line.
                    let faded = (v &* k) >> 8
                    g[i] = UInt8(faded > 0 ? faded &- 1 : 0)
                }
            }
        }
    }

    private func buildBloom() {
        let bw = bloomW, bh = bloomH, w = width, h = height
        glow.withUnsafeBufferPointer { g in
            bloom.withUnsafeMutableBufferPointer { b in
                let bands = min(bh, max(1, ProcessInfo.processInfo.activeProcessorCount))
                let rowsPer = (bh + bands - 1) / bands
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let y0 = band * rowsPer, y1 = min(bh, y0 + rowsPer)
                    if y0 >= y1 { return }
                    for by in y0..<y1 {
                        for bx in 0..<bw {
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
        let bw = bloomW, bh = bloomH
        let stride = bytesPerRow
        let halfH = Float(h) * 0.5
        let halfW = Float(w) * 0.5
        let invR2 = 1 / (halfW * halfW + halfH * halfH)

        paint.withUnsafeBufferPointer { pt in
        glow.withUnsafeBufferPointer { gl in
        bloom.withUnsafeBufferPointer { bl in
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
                    let byv = Float(y) * 0.25
                    let by0 = min(Int(byv), bh - 1)
                    let by1 = min(by0 + 1, bh - 1)
                    let byf = byv - Float(by0)
                    let bloomRow0 = by0 * bw * 3, bloomRow1 = by1 * bw * 3

                    let dyv = Float(y) - halfH
                    let yq = dyv * dyv * invR2

                    let row = out.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    var o = y * w * 4

                    for x in 0..<w {
                        let j0 = Int(xb0[x]) * 3, j1 = Int(xb1[x]) * 3
                        let gx = xbf[x]
                        let q = xvg[x] + yq
                        let vig = 1 - vignetteAmount * q * q
                        let bloomScale = bloomAmount * vig

                        var chan = (Float(0), Float(0), Float(0))
                        for c in 0..<3 {
                            let a = bl[bloomRow0 + j0 + c], b = bl[bloomRow0 + j1 + c]
                            let cc = bl[bloomRow1 + j0 + c], d = bl[bloomRow1 + j1 + c]
                            let t = a + (b - a) * gx
                            let u = cc + (d - cc) * gx
                            let value = (t + (u - t) * byf) * bloomScale
                                + (Float(pt[o + c]) * (1.0 / 257) + Float(gl[o + c])) * vig
                            switch c {
                            case 0: chan.0 = value
                            case 1: chan.1 = value
                            default: chan.2 = value
                            }
                        }

                        let p = x * 4
                        row[p] = UInt8(min(max(chan.2, 0), 255))
                        row[p + 1] = UInt8(min(max(chan.1, 0), 255))
                        row[p + 2] = UInt8(min(max(chan.0, 0), 255))
                        row[p + 3] = 255
                        o += 4
                    }
                }
            }
        }}}}}}}

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

    /// Coverage bookkeeping as a greyscale image, for diagnosing parts of the
    /// frame the wind never reaches. Not used by the screensaver itself.
    func debugCoverageImage() -> CGImage? {
        var g = [UInt8](repeating: 0, count: coverW * coverH)
        for i in 0..<g.count { g[i] = UInt8(coverage[i] >> 8) }
        return g.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress,
                                      width: coverW, height: coverH,
                                      bitsPerComponent: 8, bytesPerRow: coverW,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    func debugCoverageHistogram() -> [Int] {
        var bins = [Int](repeating: 0, count: 10)
        for v in coverage { bins[min(Int(v) * 10 / 65536, 9)] += 1 }
        return bins
    }
}
