import CoreGraphics
import Foundation

/// A stand-in braided-river delta, generated from domain-warped ridged noise, so
/// the screensaver has something to draw before any photographs are added.
/// It is not trying to pass for a photograph — it is trying to give the flow
/// field the kind of long coherent channels it is designed to trace.
enum ProceduralImage {

    static func make(
        width: Int = 1600, height: Int = 900, seed: UInt32 = 20_260_909
    ) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let inv = 1.0 / Float(max(width, height))

        // Sunlit silt on one side, glacial melt on the other.
        let sandDeep: (Float, Float, Float) = (0.24, 0.13, 0.07)
        let sandLit: (Float, Float, Float) = (0.92, 0.58, 0.30)
        let waterDeep: (Float, Float, Float) = (0.05, 0.14, 0.24)
        let waterPale: (Float, Float, Float) = (0.66, 0.84, 0.93)

        for y in 0..<height {
            for x in 0..<width {
                let fx = Float(x) * inv * 5.0
                let fy = Float(y) * inv * 5.0

                // Domain warp twice: this is what turns straight noise ridges
                // into meandering, braiding channels.
                let w1x = Noise.fbm2(fx * 0.8, fy * 0.8, octaves: 4, seed: seed)
                let w1y = Noise.fbm2(fx * 0.8 + 5.2, fy * 0.8 + 1.3, octaves: 4, seed: seed)
                let w2x = Noise.fbm2(
                    fx * 1.9 + w1x * 1.6, fy * 1.9 + w1y * 1.6,
                    octaves: 4, seed: seed &+ 91)
                let w2y = Noise.fbm2(
                    fx * 1.9 + w1x * 1.6 + 3.7, fy * 1.9 + w1y * 1.6 + 8.1,
                    octaves: 4, seed: seed &+ 91)

                // Shear along the diagonal so the whole delta has a direction of
                // travel, the way a real valley does.
                let sx = fx * 1.25 + w2x * 1.15 + fy * 0.35
                let sy = fy * 2.30 + w2y * 1.15

                let n = Noise.fbm2(sx, sy, octaves: 5, seed: seed &+ 331)
                let ridge = 1 - abs(n)

                let channel = smoothstep(0.70, 0.965, ridge)
                let braid = smoothstep(0.52, 0.86, ridge) * 0.45

                let grain =
                    Noise.fbm2(fx * 14, fy * 14, octaves: 3, seed: seed &+ 7) * 0.5 + 0.5
                let sun = smoothstep(
                    0.0, 1.0, 1 - (Float(x) * inv * 0.8 + Float(y) * inv * 0.5))

                var r = mix(sandDeep.0, sandLit.0, sun * 0.85 + grain * 0.22)
                var g = mix(sandDeep.1, sandLit.1, sun * 0.85 + grain * 0.22)
                var b = mix(sandDeep.2, sandLit.2, sun * 0.85 + grain * 0.22)

                let wr = mix(waterDeep.0, waterPale.0, channel * 0.75 + braid)
                let wg = mix(waterDeep.1, waterPale.1, channel * 0.75 + braid)
                let wb = mix(waterDeep.2, waterPale.2, channel * 0.75 + braid)

                let m = min(channel + braid * 0.7, 1)
                r = mix(r, wr, m); g = mix(g, wg, m); b = mix(b, wb, m)

                let o = (y * width + x) * 4
                pixels[o] = byte(r)
                pixels[o + 1] = byte(g)
                pixels[o + 2] = byte(b)
                pixels[o + 3] = 255
            }
        }

        return pixels.withUnsafeMutableBytes { buf -> CGImage? in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress,
                    width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    @inline(__always) private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * min(max(t, 0), 1)
    }

    @inline(__always) private static func smoothstep(
        _ a: Float, _ b: Float, _ v: Float
    ) -> Float {
        let t = min(max((v - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always) private static func byte(_ v: Float) -> UInt8 {
        UInt8(min(max(v, 0), 1) * 255)
    }
}
