import Foundation
import CoreGraphics

/// Everything the simulation needs to know about one photograph, resampled onto
/// the character grid.
///
/// The flow direction is the *edge tangent* of the image: the minor eigenvector
/// of the smoothed structure tensor. For an aerial river that means the vectors
/// run **along** the braided channels rather than across them, so the streaks
/// trace the water instead of cutting over it. Where the photo is featureless
/// (open sand, sky, snow) the tangent is meaningless, so we fade over to a
/// divergence-free curl field — the open meteorological swirl.
final class FlowField {

    let cols: Int
    let rows: Int

    /// Perceptual luminance of the photograph, 0...1. Colour lives on the
    /// canvas at full resolution; the field keeps a coarse copy only to divide
    /// the picture into regions.
    private(set) var luma: [Float]
    private var red: [Float]
    private var green: [Float]
    private var blue: [Float]

    /// The picture divided into painted passages. Strokes belong to one, and
    /// each has its own prevailing direction, so different shapes in the frame
    /// carry visibly different line patterns.
    private(set) var regions: Segmentation!
    /// Oriented unit flow direction per cell, in **screen-proportional** space:
    /// a character cell is roughly twice as tall as it is wide, so a vector that
    /// is unit-length in grid indices is not unit-length on the display. Every
    /// angle, gradient and speed below is corrected by `aspect` so the wind is
    /// isotropic on screen rather than in the index grid.
    private(set) var dirX: [Float]
    private(set) var dirY: [Float]
    /// How much the flow is being driven by real image structure, 0...1.
    /// Doubles as "this cell is a channel" — used to speed up and brighten flow.
    private(set) var coherence: [Float]

    /// Cell height divided by cell width, typically about 1.8.
    let aspect: Float

    init(image: CGImage, cols: Int, rows: Int, aspect: Float,
         seed: UInt32, drift: Float, regionCount: Int) {
        self.cols = max(cols, 2)
        self.rows = max(rows, 2)
        self.aspect = max(aspect, 0.05)
        let n = self.cols * self.rows

        luma = [Float](repeating: 0, count: n)
        red = [Float](repeating: 0, count: n)
        green = [Float](repeating: 0, count: n)
        blue = [Float](repeating: 0, count: n)
        dirX = [Float](repeating: 1, count: n)
        dirY = [Float](repeating: 0, count: n)
        coherence = [Float](repeating: 0, count: n)

        sample(image: image)
        regions = Segmentation(r: red, g: green, b: blue,
                               cols: self.cols, rows: self.rows,
                               targetRegions: regionCount, compactness: 4.6)
        buildFlow(seed: seed, drift: drift)
    }

    // MARK: - Resampling

    /// Aspect-fill the photo onto the grid, cropping the overhang.
    private func sample(image: CGImage) {
        var raw = [UInt8](repeating: 0, count: cols * rows * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        raw.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress,
                                      width: cols, height: rows,
                                      bitsPerComponent: 8, bytesPerRow: cols * 4,
                                      space: space, bitmapInfo: info) else { return }
            ctx.interpolationQuality = .high
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: cols, height: rows))

            // Aspect-fill against the grid's true on-screen shape, then squash
            // vertically into index space; the tall cells stretch it back out.
            let a = CGFloat(aspect)
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = max(CGFloat(cols) / iw, CGFloat(rows) * a / ih)
            let dw = iw * scale
            let dh = ih * scale / a
            ctx.draw(image, in: CGRect(x: (CGFloat(cols) - dw) / 2,
                                       y: (CGFloat(rows) - dh) / 2,
                                       width: dw, height: dh))
        }

        // A bitmap context's memory row 0 is the top of the drawn image, which
        // is already the grid's row 0 — no flip.
        let inv: Float = 1.0 / 255.0
        for y in 0..<rows {
            let src = y * cols * 4
            let dst = y * cols
            for x in 0..<cols {
                let o = src + x * 4
                let r = Float(raw[o]) * inv
                let g = Float(raw[o + 1]) * inv
                let b = Float(raw[o + 2]) * inv
                red[dst + x] = r; green[dst + x] = g; blue[dst + x] = b
                luma[dst + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
    }

    // MARK: - Flow

    private func buildFlow(seed: UInt32, drift: Float) {
        let n = cols * rows

        var smooth = luma
        boxBlur(&smooth, radius: max(2, cols / 240), passes: 2)

        var gx = [Float](repeating: 0, count: n)
        var gy = [Float](repeating: 0, count: n)
        sobel(smooth, gx: &gx, gy: &gy)
        // A one-row step spans `aspect` times more screen than a one-column step,
        // so the vertical derivative has to be scaled before the tensor is built
        // or every tangent comes out biased toward the horizontal.
        let invAspect = 1 / aspect
        for i in 0..<n { gy[i] *= invAspect }

        // Structure tensor, then smooth it. The smoothing radius sets how far a
        // streak will agree with its neighbours — too small and the field is
        // noisy, too large and it stops following the finer braids.
        var tE = [Float](repeating: 0, count: n)
        var tF = [Float](repeating: 0, count: n)
        var tG = [Float](repeating: 0, count: n)
        for i in 0..<n {
            tE[i] = gx[i] * gx[i]
            tF[i] = gx[i] * gy[i]
            tG[i] = gy[i] * gy[i]
        }
        let tensorRadius = max(3, cols / 45)
        boxBlur(&tE, radius: tensorRadius, passes: 3)
        boxBlur(&tF, radius: tensorRadius, passes: 3)
        boxBlur(&tG, radius: tensorRadius, passes: 3)

        // Normalise edge energy against a high percentile so the field behaves
        // the same for a soft dawn photo and a high-contrast one.
        var energy = [Float](repeating: 0, count: n)
        for i in 0..<n { energy[i] = (tE[i] + tG[i]).squareRoot() }
        let reference = percentile(energy, 0.90)
        let energyScale = reference > 1e-6 ? 1 / reference : 0

        // Each region's prevailing direction: the dominant orientation of its
        // own structure, from its own summed tensor. A stroke crossing an even
        // passage then still travels the way that passage runs.
        let regionCount = regions.count
        var accE = [Float](repeating: 0, count: regionCount)
        var accF = [Float](repeating: 0, count: regionCount)
        var accG = [Float](repeating: 0, count: regionCount)
        for i in 0..<n {
            let l = Int(regions.labels[i])
            accE[l] += tE[i]; accF[l] += tF[i]; accG[l] += tG[i]
        }
        var regionX = [Float](repeating: 1, count: regionCount)
        var regionY = [Float](repeating: 0, count: regionCount)
        var regionSwirl = [Float](repeating: 1, count: regionCount)
        for l in 0..<regionCount {
            let e = accE[l], f = accF[l], g = accG[l]
            let d = ((e - g) * (e - g) + 4 * f * f).squareRoot()
            var tx = -(g - e + d), ty = 2 * f
            let len = (tx * tx + ty * ty).squareRoot()
            if len < 1e-9 { tx = 1; ty = 0 } else { tx /= len; ty /= len }
            // Break the director's sign per region so neighbouring passages do
            // not all sweep the same way.
            if Noise.hash(Int32(l), 11, 3, seed) < 0.5 { tx = -tx; ty = -ty }
            regionX[l] = tx; regionY[l] = ty
            regionSwirl[l] = 0.65 + Noise.hash(Int32(l), 29, 7, seed) * 0.9
        }

        // A slowly turning wind, seeded per region, used both to orient the
        // (sign-ambiguous) tangents and to fill in the featureless areas.
        let windScale: Float = 1.05 / Float(cols)

        for y in 0..<rows {
            for x in 0..<cols {
                let i = y * cols + x
                let e = tE[i], f = tF[i], g = tG[i]
                let d = ((e - g) * (e - g) + 4 * f * f).squareRoot()
                let sum = e + g

                // Minor eigenvector = perpendicular to the gradient = along the edge.
                var tx = -(g - e + d)
                var ty = 2 * f
                let tlen = (tx * tx + ty * ty).squareRoot()
                if tlen < 1e-9 { tx = 1; ty = 0 } else { tx /= tlen; ty /= tlen }

                let anisotropy = sum > 1e-9 ? (d / sum) * (d / sum) : 0
                let strength = smoothstep(0.05, 0.45, energy[i] * energyScale)
                let coh = min(max(anisotropy * strength, 0), 1)

                let label = Int(regions.labels[i])
                let (cxw, cyw) = Noise.curl(Float(x), Float(y) * aspect,
                                            scale: windScale * regionSwirl[label],
                                            seed: seed &+ UInt32(label) &* 7919)
                // Half the region's own prevailing direction, half its own
                // turbulence: enough shared direction to read as one passage,
                // enough turbulence not to look combed.
                var wx = cxw + (regionX[label] - cxw) * 0.5
                var wy = cyw + (regionY[label] - cyw) * 0.5
                let wlen = (wx * wx + wy * wy).squareRoot()
                if wlen < 1e-9 { wx = 1; wy = 0 } else { wx /= wlen; wy /= wlen }

                // The tangent is a director, not a vector: flip it to agree with
                // the wind so neighbouring streaks travel the same way.
                if tx * wx + ty * wy < 0 { tx = -tx; ty = -ty }

                let follow = min(max(coh * (1 - drift * 0.55), 0), 1)
                var fx = wx + (tx - wx) * follow
                var fy = wy + (ty - wy) * follow
                let flen = (fx * fx + fy * fy).squareRoot()
                if flen < 1e-9 { fx = wx; fy = wy } else { fx /= flen; fy /= flen }

                dirX[i] = fx
                dirY[i] = fy
                coherence[i] = coh
            }
        }

        // Smoothing the vector field itself removes the last of the singularities
        // where two braids meet, so streaks glide instead of stuttering.
        boxBlur(&dirX, radius: 1, passes: 1)
        boxBlur(&dirY, radius: 1, passes: 1)
        for i in 0..<n {
            let l = (dirX[i] * dirX[i] + dirY[i] * dirY[i]).squareRoot()
            if l < 1e-9 { dirX[i] = 1; dirY[i] = 0 } else { dirX[i] /= l; dirY[i] /= l }
        }
        boxBlur(&coherence, radius: 2, passes: 1)
    }

    /// Region index at a field coordinate.
    @inline(__always)
    func label(atX x: Float, y: Float) -> Int32 {
        let cx = min(max(Int(x), 0), cols - 1)
        let cy = min(max(Int(y), 0), rows - 1)
        return regions.labels[cy * cols + cx]
    }

    /// Mean colour of a region — the local palette a stroke is drawn toward.
    @inline(__always)
    func regionColor(_ label: Int32) -> (Float, Float, Float) {
        let l = min(max(Int(label), 0), regions.count - 1)
        return (regions.meanR[l], regions.meanG[l], regions.meanB[l])
    }

    // MARK: - Sampling helpers

    /// Bilinear flow lookup, with a slow breathing perturbation so the field is
    /// never quite static.
    @inline(__always)
    func flow(atX x: Float, y: Float, time: Float, swirl: Float, seed: UInt32) -> (Float, Float, Float) {
        let cx = min(max(x, 0), Float(cols - 1) - 0.001)
        let cy = min(max(y, 0), Float(rows - 1) - 0.001)
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, cols - 1), y1 = min(y0 + 1, rows - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)

        let i00 = y0 * cols + x0, i10 = y0 * cols + x1
        let i01 = y1 * cols + x0, i11 = y1 * cols + x1
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy, w11 = fx * fy

        var vx = dirX[i00] * w00 + dirX[i10] * w10 + dirX[i01] * w01 + dirX[i11] * w11
        var vy = dirY[i00] * w00 + dirY[i10] * w10 + dirY[i01] * w01 + dirY[i11] * w11
        let coh = coherence[i00] * w00 + coherence[i10] * w10
            + coherence[i01] * w01 + coherence[i11] * w11

        if swirl > 0 {
            let a = (Noise.value3(cx * 0.035, cy * aspect * 0.035, time * 0.09, seed &+ 7717) - 0.5)
                * swirl * (1.15 - coh)
            let s = sin(a), c = cos(a)
            let rx = vx * c - vy * s
            let ry = vx * s + vy * c
            vx = rx; vy = ry
        }

        let l = (vx * vx + vy * vy).squareRoot()
        if l < 1e-9 { return (1, 0, coh) }
        return (vx / l, vy / l, coh)
    }

    // MARK: - Signal utilities

    @inline(__always)
    private func smoothstep(_ a: Float, _ b: Float, _ v: Float) -> Float {
        if b <= a { return v >= b ? 1 : 0 }
        let t = min(max((v - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func sobel(_ src: [Float], gx: inout [Float], gy: inout [Float]) {
        for y in 0..<rows {
            let ym = y > 0 ? y - 1 : 0
            let yp = y < rows - 1 ? y + 1 : rows - 1
            for x in 0..<cols {
                let xm = x > 0 ? x - 1 : 0
                let xp = x < cols - 1 ? x + 1 : cols - 1
                let a = src[ym * cols + xm], b = src[ym * cols + x], c = src[ym * cols + xp]
                let d = src[y * cols + xm], f = src[y * cols + xp]
                let g = src[yp * cols + xm], h = src[yp * cols + x], i = src[yp * cols + xp]
                gx[y * cols + x] = (c + 2 * f + i) - (a + 2 * d + g)
                gy[y * cols + x] = (g + 2 * h + i) - (a + 2 * b + c)
            }
        }
    }

    /// Separable box blur; three passes approximate a Gaussian closely enough and
    /// cost a fraction of one.
    private func boxBlur(_ data: inout [Float], radius: Int, passes: Int) {
        guard radius > 0, passes > 0 else { return }
        let vertical = max(1, Int((Float(radius) / aspect).rounded()))
        var scratch = [Float](repeating: 0, count: data.count)
        for _ in 0..<passes {
            blurRows(&data, into: &scratch, radius: radius)
            blurCols(&scratch, into: &data, radius: vertical)
        }
    }

    private func blurRows(_ src: inout [Float], into dst: inout [Float], radius: Int) {
        let inv = 1 / Float(radius * 2 + 1)
        for y in 0..<rows {
            let base = y * cols
            var acc: Float = 0
            for k in -radius...radius { acc += src[base + min(max(k, 0), cols - 1)] }
            for x in 0..<cols {
                dst[base + x] = acc * inv
                let out = min(max(x - radius, 0), cols - 1)
                let inn = min(max(x + radius + 1, 0), cols - 1)
                acc += src[base + inn] - src[base + out]
            }
        }
    }

    private func blurCols(_ src: inout [Float], into dst: inout [Float], radius: Int) {
        let inv = 1 / Float(radius * 2 + 1)
        for x in 0..<cols {
            var acc: Float = 0
            for k in -radius...radius { acc += src[min(max(k, 0), rows - 1) * cols + x] }
            for y in 0..<rows {
                dst[y * cols + x] = acc * inv
                let out = min(max(y - radius, 0), rows - 1)
                let inn = min(max(y + radius + 1, 0), rows - 1)
                acc += src[inn * cols + x] - src[out * cols + x]
            }
        }
    }

    private func percentile(_ values: [Float], _ p: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let stride = max(1, values.count / 4096)
        var sample = [Float]()
        sample.reserveCapacity(values.count / stride + 1)
        var i = 0
        while i < values.count { sample.append(values[i]); i += stride }
        sample.sort()
        let idx = min(sample.count - 1, max(0, Int(Float(sample.count - 1) * p)))
        return sample[idx]
    }
}
