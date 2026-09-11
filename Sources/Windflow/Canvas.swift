import AppKit
import CoreGraphics
import Foundation

/// The drawing surface.
///
/// The photograph is never composited. It exists only as `source` — a small
/// pyramid of it — which the tracers *sample* to decide what colour to load onto
/// the brush. What you look at is `paint`, an accumulation of coloured strokes
/// that happens to converge on the picture.
///
/// Paint also has thickness. Every dab raises `height`, so the surface carries
/// the ridge of each stroke, and the frame is lit by raking a directional light
/// across that relief. This is the difference between a painting and a filtered
/// photograph: the brightness on screen is a property *of the paint* rather than
/// a glow laid over the top of it, and the brushwork is legible because it casts
/// its own light and shade.
///
/// `source` covers a region larger than the visible frame, so tracers fly in
/// from off-screen instead of dying against a border.
final class Canvas {

    let width: Int
    let height: Int

    /// Fraction of the frame added beyond each edge for tracers to fly in from.
    static let overscan: Float = 0.11

    let marginX: Float
    let marginY: Float

    // MARK: Source

    /// The photograph, graded and pyramided. Built off the render thread and
    /// adopted by reference.
    private var src: SourceImage!

    // MARK: Painting layers

    private var paint: [UInt16]  // RGBX, 16-bit so low-opacity dabs register
    private var relief: [UInt16]  // paint thickness
    private var grain: [UInt8]  // static canvas weave
    private var glow: [UInt8]  // RGBX, additive, faded each frame

    // MARK: Bookkeeping

    private let coverW: Int
    private let coverH: Int
    private var coverage: [UInt16]
    /// Centres of the least-painted cells. Random sampling finds broad thin
    /// areas but almost never lands inside a hole a few cells across, and those
    /// are what survive to the end because they sit on the sinks and centres of
    /// the flow where no streamline goes.
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
        sourceScaleX = Float(self.width) / (Float(self.width) + 2 * marginX)
        sourceScaleY = Float(self.height) / (Float(self.height) + 2 * marginY)

        paint = [UInt16](repeating: 0, count: n * 4)
        relief = [UInt16](repeating: 0, count: n)
        glow = [UInt8](repeating: 0, count: n * 4)

        // Canvas weave. Almost invisible on its own; under a raking light it is
        // the difference between paint on a surface and paint in a vacuum.
        grain = [UInt8](repeating: 0, count: n)
        for y in 0..<self.height {
            for x in 0..<self.width {
                let fine = Noise.value2(Float(x) * 0.9, Float(y) * 0.9, 0x5EED)
                let weave = (sin(Float(x) * 1.7) + sin(Float(y) * 1.9)) * 0.11 + 0.5
                grain[y * self.width + x] = UInt8(
                    min(max(fine * 0.62 + weave * 0.38, 0), 1) * 255)
            }
        }

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

    /// Adopt a prepared photograph. The arrays are immutable, so this is a
    /// reference assignment rather than a copy of several megabytes.
    func adopt(_ image: SourceImage) {
        src = image
    }

    var detailX: [Float] { src?.detailX ?? [] }
    var detailY: [Float] { src?.detailY ?? [] }

    /// Cell dimensions of the coverage grid, needed by whoever prepares the
    /// source so its detail map lines up with it.
    var coverageSize: (Int, Int) { (coverW, coverH) }

    func reset() {
        for i in 0..<paint.count { paint[i] = 0 }
        for i in 0..<relief.count { relief[i] = 0 }
        for i in 0..<glow.count { glow[i] = 0 }
        for i in 0..<coverage.count { coverage[i] = 0 }
        holeX.removeAll(keepingCapacity: true)
        holeY.removeAll(keepingCapacity: true)
    }

    // MARK: - Sampling

    /// Bilinear colour lookup from one level of the pyramid, in tracer
    /// coordinates, which span the overscanned region.
    @inline(__always)
    func sourceColor(atX x: Float, y: Float, level: Int) -> (Float, Float, Float) {
        let sx = (x + marginX) * sourceScaleX
        let sy = (y + marginY) * sourceScaleY
        switch level {
        case 2:
            return sample(
                src.level2, w: src.mid2W, h: src.mid2H,
                x: sx * 0.25, y: sy * 0.25)
        case 1:
            return sample(
                src.level1, w: src.mid1W, h: src.mid1H,
                x: sx * 0.5, y: sy * 0.5)
        default: return sample(src.level0, w: width, h: height, x: sx, y: sy)
        }
    }

    @inline(__always)
    private func sample(
        _ buf: [UInt8], w: Int, h: Int, x: Float, y: Float
    )
        -> (Float, Float, Float)
    {
        let cx = min(max(x, 0), Float(w - 1) - 0.001)
        let cy = min(max(y, 0), Float(h - 1) - 0.001)
        let x0 = Int(cx), y0 = Int(cy)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let i00 = (y0 * w + x0) * 4, i10 = i00 + 4
        let i01 = i00 + w * 4, i11 = i01 + 4
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy, w11 = fx * fy
        @inline(__always) func channel(_ c: Int) -> Float {
            (Float(buf[i00 + c]) * w00 + Float(buf[i10 + c]) * w10
                + Float(buf[i01 + c]) * w01 + Float(buf[i11 + c]) * w11) * (1.0 / 255)
        }
        return (channel(0), channel(1), channel(2))
    }

    /// Field coordinate back to a tracer coordinate, for spawning on something
    /// the field found — a region boundary, say.
    @inline(__always)
    func canvasPoint(fieldX: Float, fieldY: Float, cols: Int, rows: Int) -> (Float, Float) {
        (
            fieldX * Float(width) / (Float(cols) * sourceScaleX) - marginX,
            fieldY * Float(height) / (Float(rows) * sourceScaleY) - marginY
        )
    }

    @inline(__always)
    func fieldCoordinate(x: Float, y: Float, cols: Int, rows: Int) -> (Float, Float) {
        (
            (x + marginX) * sourceScaleX * Float(cols) / Float(width),
            (y + marginY) * sourceScaleY * Float(rows) / Float(height)
        )
    }

    // MARK: - Painting

    /// One dab of a stroke: colour blended toward, thickness added.
    ///
    /// Blending rather than adding is what lets overlapping strokes behave like
    /// paint instead of blowing out, and is why the accumulation converges on
    /// the picture rather than past it.
    @inline(__always)
    func paintDab(
        x: Float, y: Float, r: Float, g: Float, b: Float,
        alpha: Float, thickness: Float
    ) {
        if x < 0 || y < 0 || x >= Float(width - 1) || y >= Float(height - 1) { return }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let base = y0 * width + x0
        let cr = min(max(r, 0), 1) * 65535
        let cg = min(max(g, 0), 1) * 65535
        let cb = min(max(b, 0), 1) * 65535

        paint.withUnsafeMutableBufferPointer { p in
            relief.withUnsafeMutableBufferPointer { hgt in
                @inline(__always) func put(_ idx: Int, _ w: Float) {
                    let a = w * alpha
                    if a <= 0.0015 { return }
                    let o = idx * 4
                    p[o] = UInt16(Float(p[o]) + (cr - Float(p[o])) * a)
                    p[o + 1] = UInt16(Float(p[o + 1]) + (cg - Float(p[o + 1])) * a)
                    p[o + 2] = UInt16(Float(p[o + 2]) + (cb - Float(p[o + 2])) * a)
                    let add = w * thickness * 65535
                    hgt[idx] = UInt16(min(Float(hgt[idx]) + add, 65535))
                }
                put(base, (1 - fx) * (1 - fy))
                put(base + 1, fx * (1 - fy))
                put(base + width, (1 - fx) * fy)
                put(base + width + 1, fx * fy)
            }
        }
    }

    @inline(__always)
    func addGlow(x: Float, y: Float, r: Float, g: Float, b: Float, intensity: Float) {
        if x < 0 || y < 0 || x >= Float(width - 1) || y >= Float(height - 1) { return }
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let base = (y0 * width + x0) * 4
        // Capped near the stroke's own colour: uncapped, every place several
        // strokes share a path clips to white and reads as a hard drawn line.
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

    @inline(__always)
    func coverageAt(x: Float, y: Float) -> Float {
        let cx = min(max(Int(x) / 8, 0), coverW - 1)
        let cy = min(max(Int(y) / 8, 0), coverH - 1)
        return Float(coverage[cy * coverW + cx]) / 65535
    }

    func meanCoverage() -> Float {
        var sum: Float = 0
        for v in coverage { sum += Float(v) }
        return sum / Float(coverage.count) / 65535
    }

    /// Recompute how far the painting has got, cell by cell, by comparing the
    /// paint against the photograph it is converging on. Counting where the
    /// brush has *been* marks a cell finished after a handful of dabs, while the
    /// paint underneath needs an order of magnitude more.
    func refreshCoverage() {
        coverage.withUnsafeMutableBufferPointer { cov in
            paint.withUnsafeBufferPointer { pt in
                src.level0.withUnsafeBufferPointer { s0 in
                    for cy in 0..<coverH {
                        for cx in 0..<coverW {
                            var ratio: Float = 0
                            var taken = 0
                            for (ox, oy) in [(2, 2), (6, 2), (2, 6), (6, 6)] {
                                let x = cx * 8 + ox, y = cy * 8 + oy
                                if x >= width || y >= height { continue }
                                let o = (y * width + x) * 4
                                let pl =
                                    (0.2126 * Float(pt[o]) + 0.7152 * Float(pt[o + 1])
                                        + 0.0722 * Float(pt[o + 2])) * (1.0 / 65535)
                                let sx = min(
                                    Int((Float(x) + marginX) * sourceScaleX), width - 1)
                                let sy = min(
                                    Int((Float(y) + marginY) * sourceScaleY), height - 1)
                                let so = (sy * width + sx) * 4
                                let sl =
                                    (0.2126 * Float(s0[so]) + 0.7152 * Float(s0[so + 1])
                                        + 0.0722 * Float(s0[so + 2])) * (1.0 / 255)
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
        rebuildHoles()
    }

    private func rebuildHoles() {
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

    func present(
        fade: Float, reliefKeep: Float, bloomAmount: Float,
        vignetteAmount: Float, lighting: Float
    ) -> CGImage? {
        decayLayers(glowKeep: fade, reliefKeep: reliefKeep)
        buildBloom()
        return composite(
            bloomAmount: bloomAmount, vignetteAmount: vignetteAmount,
            lighting: lighting)
    }

    /// Glow and relief both decay here rather than inside the composite, so the
    /// composite sees a consistent relief field. Decaying it in place while
    /// neighbouring rows are read for the surface gradient would put a seam at
    /// every thread boundary.
    private func decayLayers(glowKeep: Float, reliefKeep: Float) {
        let gk = UInt32(min(max(glowKeep, 0), 1) * 256)
        let rk = UInt32(min(max(reliefKeep, 0), 1) * 65536)
        let w = width, h = height
        glow.withUnsafeMutableBufferPointer { g in
            relief.withUnsafeMutableBufferPointer { r in
                let bands = min(h, max(1, ProcessInfo.processInfo.activeProcessorCount))
                let rowsPer = (h + bands - 1) / bands
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let y0 = band * rowsPer, y1 = min(h, y0 + rowsPer)
                    if y0 >= y1 { return }
                    for i in (y0 * w * 4)..<(y1 * w * 4) {
                        let v = UInt32(g[i])
                        if v == 0 { continue }
                        // The -1 guarantees the tail reaches zero; a pure
                        // multiply leaves a permanent smear of 1s behind.
                        let faded = (v &* gk) >> 8
                        g[i] = UInt8(faded > 0 ? faded &- 1 : 0)
                    }
                    for i in (y0 * w)..<(y1 * w) {
                        r[i] = UInt16((UInt32(r[i]) &* rk) >> 16)
                    }
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
                                    r += Float(g[o]); gg += Float(g[o + 1]);
                                    bb += Float(g[o + 2])
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

    /// Separable box blur over the bloom buffer.
    ///
    /// The two passes are separate methods with explicit signatures rather than
    /// index arithmetic inlined into nested closures. Written that way, the
    /// expression is large enough that some Swift toolchains give up type-checking
    /// it — it compiles locally and fails on CI, which is the worst way to find out.
    private func blurBloom(radius: Int) {
        let bw = bloomW
        let bh = bloomH
        let inv = 1 / Float(radius * 2 + 1)
        bloom.withUnsafeMutableBufferPointer { src in
            bloomScratch.withUnsafeMutableBufferPointer { dst in
                Canvas.blurRows(src: src, dst: dst, bw: bw, bh: bh, radius: radius, inv: inv)
                Canvas.blurColumns(src: dst, dst: src, bw: bw, bh: bh, radius: radius, inv: inv)
            }
        }
    }

    private static func blurRows(
        src: UnsafeMutableBufferPointer<Float>, dst: UnsafeMutableBufferPointer<Float>,
        bw: Int, bh: Int, radius: Int, inv: Float
    ) {
        for y in 0..<bh {
            let row = y * bw
            for c in 0..<3 {
                var acc: Float = 0
                for k in -radius...radius {
                    let x = min(max(k, 0), bw - 1)
                    acc += src[(row + x) * 3 + c]
                }
                for x in 0..<bw {
                    dst[(row + x) * 3 + c] = acc * inv
                    let incoming = min(x + radius + 1, bw - 1)
                    let outgoing = max(x - radius, 0)
                    acc += src[(row + incoming) * 3 + c]
                    acc -= src[(row + outgoing) * 3 + c]
                }
            }
        }
    }

    private static func blurColumns(
        src: UnsafeMutableBufferPointer<Float>, dst: UnsafeMutableBufferPointer<Float>,
        bw: Int, bh: Int, radius: Int, inv: Float
    ) {
        for x in 0..<bw {
            for c in 0..<3 {
                var acc: Float = 0
                for k in -radius...radius {
                    let y = min(max(k, 0), bh - 1)
                    acc += src[(y * bw + x) * 3 + c]
                }
                for y in 0..<bh {
                    dst[(y * bw + x) * 3 + c] = acc * inv
                    let incoming = min(y + radius + 1, bh - 1)
                    let outgoing = max(y - radius, 0)
                    acc += src[(incoming * bw + x) * 3 + c]
                    acc -= src[(outgoing * bw + x) * 3 + c]
                }
            }
        }
    }

    private func composite(
        bloomAmount: Float, vignetteAmount: Float,
        lighting: Float
    ) -> CGImage? {
        let out = outputs[nextOutput]
        nextOutput = (nextOutput + 1) % outputs.count

        let w = width, h = height
        let bw = bloomW, bh = bloomH
        let stride = bytesPerRow
        let halfH = Float(h) * 0.5, halfW = Float(w) * 0.5
        let invR2 = 1 / (halfW * halfW + halfH * halfH)

        // A raking light from the upper left, the way a painting is usually hung
        // and lit. Relief is in 0...1; the multiplier converts a height step into
        // a surface slope steep enough to read.
        let relief2normal: Float = 17 * lighting
        let lx: Float = -0.46, ly: Float = -0.58, lz: Float = 0.67
        // Half-vector for a viewer straight on.
        let hx = lx, hy = ly, hz = lz + 1
        let hlen = (hx * hx + hy * hy + hz * hz).squareRoot()
        let hnx = hx / hlen, hny = hy / hlen, hnz = hz / hlen

        paint.withUnsafeBufferPointer { pt in
            glow.withUnsafeBufferPointer { gl in
                relief.withUnsafeBufferPointer { rf in
                    grain.withUnsafeBufferPointer { gr in
                        bloom.withUnsafeBufferPointer { bl in
                            xBloom0.withUnsafeBufferPointer { xb0 in
                                xBloom1.withUnsafeBufferPointer { xb1 in
                                    xBloomF.withUnsafeBufferPointer { xbf in
                                        xVignette.withUnsafeBufferPointer { xvg in
                                            let bands = min(
                                                h,
                                                max(
                                                    1,
                                                    ProcessInfo.processInfo.activeProcessorCount
                                                ))
                                            let rowsPer = (h + bands - 1) / bands
                                            DispatchQueue.concurrentPerform(iterations: bands) {
                                                band in
                                                let y0 = band * rowsPer,
                                                    y1 = min(h, y0 + rowsPer)
                                                if y0 >= y1 { return }

                                                for y in y0..<y1 {
                                                    let byv = Float(y) * 0.25
                                                    let by0 = min(Int(byv), bh - 1)
                                                    let by1 = min(by0 + 1, bh - 1)
                                                    let byf = byv - Float(by0)
                                                    let bloomRow0 = by0 * bw * 3,
                                                        bloomRow1 = by1 * bw * 3

                                                    let dyv = Float(y) - halfH
                                                    let yq = dyv * dyv * invR2

                                                    let rowUp = max(y - 1, 0) * w
                                                    let rowDown = min(y + 1, h - 1) * w
                                                    let rowHere = y * w

                                                    let row = out.advanced(by: y * stride)
                                                        .assumingMemoryBound(to: UInt8.self)

                                                    for x in 0..<w {
                                                        let i = rowHere + x
                                                        let o = i * 4
                                                        let xl = max(x - 1, 0),
                                                            xr = min(x + 1, w - 1)

                                                        // Surface of the paint: its own thickness plus the weave
                                                        // of the canvas showing through where it is thin.
                                                        let scale: Float = 1.0 / 65535
                                                        let gScale: Float = 1.0 / 255 * 0.16
                                                        let hL =
                                                            Float(rf[rowHere + xl]) * scale
                                                            + Float(gr[rowHere + xl]) * gScale
                                                        let hR =
                                                            Float(rf[rowHere + xr]) * scale
                                                            + Float(gr[rowHere + xr]) * gScale
                                                        let hU =
                                                            Float(rf[rowUp + x]) * scale
                                                            + Float(gr[rowUp + x]) * gScale
                                                        let hD =
                                                            Float(rf[rowDown + x]) * scale
                                                            + Float(gr[rowDown + x]) * gScale

                                                        var nx = -(hR - hL) * relief2normal
                                                        var ny = -(hD - hU) * relief2normal
                                                        var nz: Float = 1
                                                        let nlen = (nx * nx + ny * ny + 1)
                                                            .squareRoot()
                                                        nx /= nlen; ny /= nlen; nz /= nlen

                                                        let diffuse = max(
                                                            nx * lx + ny * ly + nz * lz, 0)
                                                        var spec = max(
                                                            nx * hnx + ny * hny + nz * hnz, 0)
                                                        spec = spec * spec; spec = spec * spec
                                                        // Raise to the sixteenth by repeated squaring.
                                                        spec = spec * spec; spec = spec * spec
                                                        let thickness = min(
                                                            Float(rf[i]) * scale * 3.2, 1)
                                                        let specular =
                                                            spec * 78 * thickness * lighting

                                                        // Ambient plus diffuse, normalised so an unlit flat area
                                                        // keeps the photograph's own value.
                                                        let shade = 0.80 + 0.34 * diffuse

                                                        let j0 = Int(xb0[x]) * 3,
                                                            j1 = Int(xb1[x]) * 3
                                                        let gx = xbf[x]
                                                        let q = xvg[x] + yq
                                                        let vig = 1 - vignetteAmount * q * q
                                                        let bloomScale = bloomAmount * vig

                                                        var chan = (
                                                            Float(0), Float(0), Float(0)
                                                        )
                                                        for c in 0..<3 {
                                                            let a = bl[bloomRow0 + j0 + c],
                                                                b = bl[bloomRow0 + j1 + c]
                                                            let cc = bl[bloomRow1 + j0 + c],
                                                                d = bl[bloomRow1 + j1 + c]
                                                            let t = a + (b - a) * gx
                                                            let u = cc + (d - cc) * gx
                                                            let value =
                                                                (t + (u - t) * byf) * bloomScale
                                                                + (Float(pt[o + c])
                                                                    * (1.0 / 257) * shade
                                                                    + Float(gl[o + c])
                                                                    + specular) * vig
                                                            switch c {
                                                            case 0: chan.0 = value
                                                            case 1: chan.1 = value
                                                            default: chan.2 = value
                                                            }
                                                        }

                                                        let p = x * 4
                                                        row[p] = UInt8(min(max(chan.2, 0), 255))
                                                        row[p + 1] = UInt8(
                                                            min(max(chan.1, 0), 255))
                                                        row[p + 2] = UInt8(
                                                            min(max(chan.0, 0), 255))
                                                        row[p + 3] = 255
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard
            let provider = CGDataProvider(
                dataInfo: nil, data: out,
                size: byteCount, releaseData: { _, _, _ in })
        else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue:
                    CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Accumulated paint at a pixel, 0...1 per channel.
    func paintColor(atX x: Int, y: Int) -> (Float, Float, Float) {
        let o = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        let inv: Float = 1.0 / 65535
        return (Float(paint[o]) * inv, Float(paint[o + 1]) * inv, Float(paint[o + 2]) * inv)
    }

    /// FNV-1a over the paint buffer. Two runs of the same seed must agree.
    func debugChecksum() -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for v in paint {
            h = (h ^ UInt64(v)) &* 0x100_0000_01b3
        }
        return h
    }

    func debugCoverageImage() -> CGImage? {
        var g = [UInt8](repeating: 0, count: coverW * coverH)
        for i in 0..<g.count { g[i] = UInt8(coverage[i] >> 8) }
        return g.withUnsafeMutableBytes { buf -> CGImage? in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress,
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
