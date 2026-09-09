import Foundation

// Small, allocation-free value-noise kit. Deterministic for a given seed so an
// image always regenerates the same wind.
enum Noise {

    @inline(__always)
    static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> Float {
        var h: UInt32 = seed &* 0x9E37_79B9
        h ^= UInt32(bitPattern: x) &* 0x85EB_CA6B
        h = (h << 13) | (h >> 19)
        h ^= UInt32(bitPattern: y) &* 0xC2B2_AE35
        h = (h << 17) | (h >> 15)
        h ^= UInt32(bitPattern: z) &* 0x27D4_EB2F
        h ^= h >> 15
        h = h &* 0x2545_F491
        h ^= h >> 13
        return Float(h & 0x00FF_FFFF) / Float(0x0100_0000)
    }

    @inline(__always)
    static func fade(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    @inline(__always)
    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    /// 2D value noise in 0...1.
    @inline(__always)
    static func value2(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        let xi = x.rounded(.down), yi = y.rounded(.down)
        let xf = fade(x - xi), yf = fade(y - yi)
        let ix = Int32(xi), iy = Int32(yi)
        let a = hash(ix, iy, 0, seed)
        let b = hash(ix &+ 1, iy, 0, seed)
        let c = hash(ix, iy &+ 1, 0, seed)
        let d = hash(ix &+ 1, iy &+ 1, 0, seed)
        return lerp(lerp(a, b, xf), lerp(c, d, xf), yf)
    }

    /// 3D value noise in 0...1. The third axis is used as slow time.
    @inline(__always)
    static func value3(_ x: Float, _ y: Float, _ z: Float, _ seed: UInt32) -> Float {
        let xi = x.rounded(.down), yi = y.rounded(.down), zi = z.rounded(.down)
        let xf = fade(x - xi), yf = fade(y - yi), zf = fade(z - zi)
        let ix = Int32(xi), iy = Int32(yi), iz = Int32(zi)
        @inline(__always) func plane(_ k: Int32) -> Float {
            let a = hash(ix, iy, k, seed)
            let b = hash(ix &+ 1, iy, k, seed)
            let c = hash(ix, iy &+ 1, k, seed)
            let d = hash(ix &+ 1, iy &+ 1, k, seed)
            return lerp(lerp(a, b, xf), lerp(c, d, xf), yf)
        }
        return lerp(plane(iz), plane(iz &+ 1), zf)
    }

    /// Fractal value noise in roughly -1...1.
    static func fbm2(_ x: Float, _ y: Float, octaves: Int, seed: UInt32) -> Float {
        var sum: Float = 0, amp: Float = 1, norm: Float = 0
        var fx = x, fy = y
        for o in 0..<octaves {
            sum += amp * (value2(fx, fy, seed &+ UInt32(o &* 977)) * 2 - 1)
            norm += amp
            amp *= 0.5
            fx *= 2.03; fy *= 2.03
        }
        return sum / max(norm, 1e-6)
    }

    /// Divergence-free 2D field: the curl of an fBm potential. This is what gives
    /// the open, meteorological swirl in areas where the photo has no structure.
    static func curl(_ x: Float, _ y: Float, scale: Float, seed: UInt32) -> (Float, Float) {
        let e: Float = 0.75
        let sx = x * scale, sy = y * scale
        // Three octaves, not four: the fourth only adds detail at a scale where
        // the streaks read as fur rather than as weather.
        let n1 = fbm2(sx, sy + e * scale, octaves: 3, seed: seed)
        let n2 = fbm2(sx, sy - e * scale, octaves: 3, seed: seed)
        let n3 = fbm2(sx + e * scale, sy, octaves: 3, seed: seed)
        let n4 = fbm2(sx - e * scale, sy, octaves: 3, seed: seed)
        let dx = (n1 - n2)
        let dy = -(n3 - n4)
        let len = (dx * dx + dy * dy).squareRoot()
        if len < 1e-6 { return (1, 0) }
        return (dx / len, dy / len)
    }
}
