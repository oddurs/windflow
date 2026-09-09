import Foundation
import CoreGraphics

/// The moving part: a swarm of tracers advected through the flow field, each one
/// drawing a line of light as it goes.
///
/// Nothing is ever blitted from the source photograph. The image arrives only
/// through `Canvas.reveal`, which grows wherever a line has passed — so the
/// picture is literally assembled out of wind.
final class Simulation {

    enum Phase { case revealing, holding, dissolving, done }

    struct Tuning {
        var density: Float = 1.0      // tracer count multiplier
        var speed: Float = 1.0        // travel multiplier
        var trail: Float = 1.0        // streak-length multiplier
        var exposure: Float = 1.0     // line brightness
        var swirl: Float = 0.55       // time-varying wander, radians
        var bloom: Float = 0.9
        var inkRate: Float = 1.0      // how fast the photograph accumulates
        /// Target on-screen lifetime for one photograph. Whatever is left after
        /// the image finishes assembling becomes the hold before it dissolves.
        var totalSeconds: Float = 75
        var revealTimeout: Float = 95
    }

    private struct Tracer {
        var x: Float = 0
        var y: Float = 0
        var age: Float = 0
        var life: Float = 1
        var pace: Float = 1
        var weight: Float = 1
        /// Position sampled a moment ago, used to notice a tracer that has
        /// stalled in a sink of the flow field. Left alone it would sit there
        /// burning a bright dot into the frame.
        var checkX: Float = 0
        var checkY: Float = 0
        var checkClock: Float = 0
        /// Signed cross-flow bias. Edge-tangent fields are full of closed
        /// contours, and a tracer that follows one exactly orbits it forever —
        /// which both burns a bright ring into the frame and leaves the rest of
        /// the picture untouched. A small persistent drift across the flow turns
        /// every orbit into a slow spiral, so the swarm sweeps the whole plane.
        var drift: Float = 0
    }

    let field: FlowField
    let canvas: Canvas
    var tuning: Tuning

    private(set) var phase: Phase = .revealing
    private(set) var elapsed: Float = 0

    private let seed: UInt32
    /// Flow-field cells per pixel; the field is coarse and smooth, the canvas is not.
    private let fieldScaleX: Float
    private let fieldScaleY: Float
    private let baseSpeed: Float

    private var tracers: [Tracer]
    private var rng: UInt64
    private var phaseClock: Float = 0
    private var meanReveal: Float = 0
    private var holdDuration: Float = 10
    private var frame = 0

    init(field: FlowField, canvas: Canvas, tuning: Tuning, seed: UInt32, preview: Bool) {
        self.field = field
        self.canvas = canvas
        self.tuning = tuning
        self.seed = seed
        self.rng = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1

        fieldScaleX = Float(field.cols) / Float(canvas.width)
        fieldScaleY = Float(field.rows) / Float(canvas.height)
        // Travel is expressed against the canvas width so the wind crosses the
        // screen in the same time at any resolution.
        baseSpeed = Float(canvas.width) * 0.055 * tuning.speed

        // Roughly one tracer per 900 pixels. Fewer, longer, brighter lines read
        // as weather; a dense swarm reads as static.
        let wanted = Float(canvas.width * canvas.height) / 900 * tuning.density
            * (preview ? 0.4 : 1.0)
        let count = min(max(Int(wanted), 700), 40000)
        tracers = [Tracer](repeating: Tracer(), count: count)
        for i in 0..<count {
            tracers[i] = spawn(biasToUnrevealed: false)
            tracers[i].age = nextFloat() * tracers[i].life
        }
    }

    // MARK: - Random

    @inline(__always)
    private func nextFloat() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    /// Rejection-sample toward parts of the frame the photograph has not reached
    /// yet, so the last few percent still fills in instead of stalling.
    private func spawn(biasToUnrevealed: Bool) -> Tracer {
        var t = Tracer()
        // Spawning a little outside the frame lets wind blow in over the edges
        // instead of leaving an unvisited border.
        let marginX = Float(canvas.width) * 0.07
        let marginY = Float(canvas.height) * 0.07
        @inline(__always) func candidate() -> (Float, Float) {
            (nextFloat() * (Float(canvas.width - 1) + marginX * 2) - marginX,
             nextFloat() * (Float(canvas.height - 1) + marginY * 2) - marginY)
        }

        var (x, y) = candidate()
        if biasToUnrevealed {
            var worst = canvas.revealFraction(atX: x, y: y)
            for _ in 0..<7 {
                let (cx, cy) = candidate()
                let cover = canvas.revealFraction(atX: cx, y: cy)
                if cover < worst { worst = cover; x = cx; y = cy }
            }
        }
        t.x = x
        t.y = y
        t.checkX = x
        t.checkY = y
        t.life = 3.5 + nextFloat() * 7.0
        t.pace = 0.65 + nextFloat() * 0.7
        t.drift = (nextFloat() - 0.5) * 2
        // A spread of weights keeps a few lines noticeably brighter than the
        // rest, which is what stops the field looking uniform.
        let r = nextFloat()
        t.weight = 0.35 + r * r * 1.5
        return t
    }

    // MARK: - Step

    func step(dt rawDt: Float) {
        let dt = min(max(rawDt, 1.0 / 240.0), 1.0 / 20.0)
        elapsed += dt
        phaseClock += dt
        frame &+= 1

        advance(dt: dt)

        if phase == .dissolving {
            canvas.decayReveal(exp(-dt / 2.2))
        }
        if frame % 12 == 0 { meanReveal = canvas.meanReveal() }
        // Once the closing ramp is under way, even out the coverage between
        // strokes; without this the finished picture keeps a combed, furry
        // texture where the lines ran.
        if (phase == .revealing || phase == .holding) && frame % 20 == 0
            && (phase == .holding || phaseClock > tuning.revealTimeout * 0.35) {
            canvas.smoothReveal()
        }

        switch phase {
        case .revealing:
            if meanReveal > 0.95 || phaseClock > tuning.revealTimeout {
                phase = .holding
                holdDuration = max(5, tuning.totalSeconds - elapsed)
                phaseClock = 0
            }
        case .holding:
            if phaseClock > holdDuration {
                phase = .dissolving
                phaseClock = 0
            }
        case .dissolving:
            if meanReveal < 0.01 { phase = .done }
        case .done:
            break
        }
    }

    private func advance(dt: Float) {
        let time = elapsed
        let swirl = tuning.swirl
        let revealing = phase != .dissolving && phase != .done
        // Brightness is divided by the trail length: a longer-lived streak
        // accumulates more passes over the same pixel, so without this the trail
        // slider doubles as an exposure slider.
        let lightPerStep = 0.22 * tuning.exposure / max(0.35, tuning.trail)
        let crossSpeed = baseSpeed * 0.20
        let stallDistanceSquared = powf(baseSpeed * 0.35 * 0.22, 2)

        // The photograph arrives slowly at first — for the opening seconds there
        // is nothing on screen but moving light — then decisively, so it is
        // actually finished before the hold begins.
        let closing = 1 + 3.0 * powf(min(phaseClock / max(tuning.revealTimeout, 1), 1), 2)
        let inkPerPixel = 0.011 * tuning.inkRate * closing

        for i in 0..<tracers.count {
            var p = tracers[i]
            p.age += dt

            if p.age >= p.life || p.x < -2 || p.y < -2
                || p.x > Float(canvas.width + 2) || p.y > Float(canvas.height + 2) {
                tracers[i] = spawn(biasToUnrevealed: true)
                continue
            }

            // Fade each tracer in and out so lines arrive and leave instead of
            // popping on and off.
            // A tracer that has barely moved in the last third of a second is
            // circling a singularity, not flowing. Recycle it.
            p.checkClock += dt
            if p.checkClock > 0.35 {
                let moved = (p.x - p.checkX) * (p.x - p.checkX)
                    + (p.y - p.checkY) * (p.y - p.checkY)
                if moved < stallDistanceSquared {
                    tracers[i] = spawn(biasToUnrevealed: true)
                    continue
                }
                p.checkClock = 0
                p.checkX = p.x
                p.checkY = p.y
            }

            let u = p.age / p.life
            let envelope = smoothstep(0, 0.12, u) * (1 - smoothstep(0.70, 1, u))
            let brightness = envelope * p.weight

            let fx = p.x * fieldScaleX, fy = p.y * fieldScaleY
            let (_, _, coh) = field.flow(atX: fx, y: fy, time: time, swirl: swirl, seed: seed)
            let speed = baseSpeed * p.pace * (0.45 + 1.2 * coh)
            let travel = speed * dt

            // Step in sub-pixel increments; anything coarser draws a dotted line
            // rather than a line.
            let steps = min(max(Int(travel / 0.55) + 1, 1), 12)
            let sub = dt / Float(steps)

            for _ in 0..<steps {
                let sx = p.x * fieldScaleX, sy = p.y * fieldScaleY
                let (dx, dy, c) = field.flow(atX: sx, y: sy, time: time, swirl: swirl, seed: seed)
                let v = baseSpeed * p.pace * (0.45 + 1.2 * c)
                // Midpoint step: visibly smoother through tight curvature.
                let mx = p.x + dx * v * sub * 0.5
                let my = p.y + dy * v * sub * 0.5
                let (ex, ey, _) = field.flow(atX: mx * fieldScaleX, y: my * fieldScaleY,
                                             time: time, swirl: swirl, seed: seed)
                // Along the flow, plus a little across it.
                let cross = p.drift * crossSpeed * sub
                p.x += ex * v * sub - ey * cross
                p.y += ey * v * sub + ex * cross

                canvas.addLight(x: p.x, y: p.y, intensity: lightPerStep * brightness)
                if revealing {
                    canvas.addReveal(x: p.x, y: p.y,
                                     amount: inkPerPixel * v * sub * envelope)
                }
            }

            tracers[i] = p
        }
    }

    /// Trail half-life in seconds, converted to a per-frame keep factor.
    func fadeFactor(dt: Float) -> Float {
        let tau = max(0.10, 0.55 * tuning.trail)
        return exp(-dt / tau)
    }

    @inline(__always)
    private func smoothstep(_ a: Float, _ b: Float, _ v: Float) -> Float {
        if b <= a { return v >= b ? 1 : 0 }
        let t = min(max((v - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// An immutable snapshot of the preferences, safe to hand to the loader queue.
struct SimulationSettings {
    var density: Float
    var speed: Float
    var trail: Float
    var exposure: Float
    var swirl: Float
    var drift: Float
    var saturation: Float
    var bloom: Float
    var secondsPerImage: Float

    init(prefs: Preferences) {
        density = Float(prefs.density)
        speed = Float(prefs.speed)
        trail = Float(prefs.trail)
        exposure = Float(prefs.exposure)
        swirl = Float(prefs.swirl)
        drift = Float(prefs.drift)
        saturation = Float(prefs.saturation)
        bloom = Float(prefs.bloom)
        secondsPerImage = Float(prefs.secondsPerImage)
    }
}

extension Simulation {
    /// Build a field and a simulation for one photograph. The canvas is reused
    /// across images; only its contents are replaced.
    static func make(image: CGImage, canvas: Canvas,
                     settings: SimulationSettings, preview: Bool) -> Simulation {
        let seed = UInt32.random(in: 1...UInt32.max)
        canvas.setImage(image, saturation: settings.saturation)
        canvas.reset()

        // The flow field is deliberately coarse: it is a smooth field, and
        // resolving it finer only adds noise for the tracers to jitter against.
        // Quartering the canvas keeps its aspect square, so its aspect-fill crop
        // matches the canvas's exactly and the wind lines up with the picture.
        let cols = max(48, canvas.width / 4)
        let rows = max(27, canvas.height / 4)
        let field = FlowField(image: image, cols: cols, rows: rows, aspect: 1,
                              seed: seed, drift: settings.drift)

        var tuning = Tuning()
        tuning.density = settings.density
        tuning.speed = settings.speed
        tuning.trail = settings.trail
        tuning.exposure = settings.exposure
        tuning.swirl = settings.swirl
        tuning.bloom = settings.bloom
        tuning.totalSeconds = settings.secondsPerImage
        tuning.revealTimeout = max(20, settings.secondsPerImage * 0.85)
        return Simulation(field: field, canvas: canvas, tuning: tuning,
                          seed: seed, preview: preview)
    }
}
