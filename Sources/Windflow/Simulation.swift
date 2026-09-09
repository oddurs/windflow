import Foundation
import CoreGraphics

/// The moving part: a swarm of tracers advected through the flow field, each one
/// dragging a brush loaded with colour taken from the photograph.
///
/// This is painterly rendering, not a reveal. A tracer samples the picture, but
/// its colour *lags* — it takes tens of pixels of travel to catch up — so a
/// stroke carries the hue it started with across a boundary before turning into
/// the new one. That lag is what makes the result read as a painting made of
/// wind rather than as the photograph with lines drawn over it, and it is why
/// the sky ends up full of a dozen different blues instead of one.
final class Simulation {

    enum Phase { case revealing, holding, dissolving, done }

    struct Tuning {
        var density: Float = 1.0
        var speed: Float = 1.0
        var trail: Float = 1.0
        var exposure: Float = 1.0
        var swirl: Float = 0.55
        var bloom: Float = 0.9
        var inkRate: Float = 1.0
        var totalSeconds: Float = 75
        var revealTimeout: Float = 95
    }

    private struct Tracer {
        var x: Float = 0
        var y: Float = 0
        var age: Float = 0
        var life: Float = 1
        var pace: Float = 1
        /// Signed cross-flow bias. Edge-tangent fields are full of closed
        /// contours, and a tracer following one exactly orbits it forever —
        /// burning a bright ring into the frame and leaving the rest of the
        /// picture untouched. A persistent drift turns each orbit into a slow
        /// spiral, so the swarm sweeps the whole plane.
        var drift: Float = 0
        /// Half-width of the brush in pixels.
        var brush: Float = 0.6
        /// Per-stroke tone, so overlapping strokes leave visible variation
        /// instead of averaging into a smooth photograph.
        var tone: Float = 1
        /// The colour currently on the brush.
        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        var loaded = false
        /// Position sampled a moment ago, to notice a tracer stalled in a sink.
        var checkX: Float = 0
        var checkY: Float = 0
        var checkClock: Float = 0
    }

    let field: FlowField
    let canvas: Canvas
    var tuning: Tuning

    private(set) var phase: Phase = .revealing
    private(set) var elapsed: Float = 0

    private let seed: UInt32
    private let baseSpeed: Float
    private var tracers: [Tracer]
    private var rng: UInt64
    private var phaseClock: Float = 0
    private var progress: Float = 0
    private var holdDuration: Float = 10
    private var frame = 0

    init(field: FlowField, canvas: Canvas, tuning: Tuning, seed: UInt32, preview: Bool) {
        self.field = field
        self.canvas = canvas
        self.tuning = tuning
        self.seed = seed
        self.rng = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1
        baseSpeed = Float(canvas.width) * 0.055 * tuning.speed

        let wanted = Float(canvas.width * canvas.height) / 520 * tuning.density
            * (preview ? 0.4 : 1.0)
        let count = min(max(Int(wanted), 900), 60000)
        tracers = [Tracer](repeating: Tracer(), count: count)
        for i in 0..<count {
            tracers[i] = spawn(biasToUncovered: false)
            tracers[i].age = nextFloat() * tracers[i].life
        }
    }

    @inline(__always)
    private func nextFloat() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    /// New tracers start at the worst-covered of several candidates. Accepting
    /// the first uncovered one still leaves the flow's shadow zones — the places
    /// no streamline enters — permanently blank.
    private func spawn(biasToUncovered: Bool) -> Tracer {
        var t = Tracer()
        // Candidates come from the overscanned region, so lines blow in over the
        // edges instead of the frame having an unpainted border.
        @inline(__always) func candidate() -> (Float, Float) {
            (nextFloat() * (Float(canvas.width) + canvas.marginX * 2) - canvas.marginX,
             nextFloat() * (Float(canvas.height) + canvas.marginY * 2) - canvas.marginY)
        }
        var (x, y) = candidate()
        if biasToUncovered {
            let roll = nextFloat()
            if roll < 0.45 && !canvas.holeX.isEmpty {
                // Straight into a known hole, jittered within its cell so the
                // tracers that land there do not all trace one streamline.
                let k = min(Int(nextFloat() * Float(canvas.holeX.count)),
                            canvas.holeX.count - 1)
                x = canvas.holeX[k] + (nextFloat() - 0.5) * 9
                y = canvas.holeY[k] + (nextFloat() - 0.5) * 9
            } else if roll < 0.80 {
                var worst = canvas.coverageAt(x: x, y: y)
                for _ in 0..<3 {
                    let (cx, cy) = candidate()
                    let cover = canvas.coverageAt(x: cx, y: cy)
                    if cover < worst { worst = cover; x = cx; y = cy }
                }
            }
        }
        t.x = x; t.y = y
        t.checkX = x; t.checkY = y
        t.life = 5.0 + nextFloat() * 9.0
        t.pace = 0.6 + nextFloat() * 0.8
        t.drift = (nextFloat() - 0.5) * 2
        // A spread of brush sizes: a few broad strokes carrying the large forms,
        // many fine ones carrying the detail.
        let bw = nextFloat()
        t.brush = 0.15 + bw * bw * 1.7
        t.tone = 0.90 + nextFloat() * 0.20
        t.loaded = false
        return t
    }

    // MARK: - Step

    func step(dt rawDt: Float) {
        let dt = min(max(rawDt, 1.0 / 240.0), 1.0 / 20.0)
        elapsed += dt
        phaseClock += dt
        frame &+= 1

        advance(dt: dt)

        if phase == .dissolving { canvas.fadePaint(exp(-dt / 2.4)) }
        // Coverage is measured off the paint, so it also serves as the progress
        // signal for the phase changes.
        if frame % 15 == 0 {
            canvas.refreshCoverage()
            progress = canvas.meanCoverage()
        }

        switch phase {
        case .revealing:
            if progress > 0.93 || phaseClock > tuning.revealTimeout {
                phase = .holding
                holdDuration = max(6, tuning.totalSeconds - elapsed)
                phaseClock = 0
            }
        case .holding:
            if phaseClock > holdDuration { phase = .dissolving; phaseClock = 0 }
        case .dissolving:
            if progress < 0.03 { phase = .done }
        case .done:
            break
        }
    }

    private func advance(dt: Float) {
        let time = elapsed
        let swirl = tuning.swirl
        let painting = phase != .dissolving && phase != .done
        let cols = field.cols, rows = field.rows

        // The picture arrives slowly at first — for the opening seconds there is
        // nothing on screen but moving light — then decisively, so it is
        // actually finished before the hold begins.
        let closing = 1 + 2.6 * powf(min(elapsed / max(tuning.revealTimeout, 1), 1), 2)
        let dabAlpha = 0.075 * tuning.inkRate * closing
        // Brightness is divided by trail length: a longer-lived streak
        // accumulates more passes over the same pixel, so without this the trail
        // slider doubles as an exposure slider.
        let glowPerStep = 0.055 * tuning.exposure / max(0.35, tuning.trail)
        let glowScale = 1 - 0.62 * progress
        let crossSpeed = baseSpeed * 0.20
        let stallDistanceSquared = powf(baseSpeed * 0.6 * 0.34, 2)
        // Distance over which the brush picks up the colour it is passing over.
        // Long at the start — strokes drag their hue across boundaries and the
        // frame is abstract — tightening as the picture builds until the paint
        // tracks the photograph closely. A fixed lag has to pick one or the
        // other; ramping it gives the whole arc.
        let resolve = min(elapsed / max(tuning.revealTimeout * 0.75, 1), 1)
        let pickupPerPixel = 1.0 / (27 - 23 * resolve * resolve)

        for i in 0..<tracers.count {
            var p = tracers[i]
            p.age += dt

            if p.age >= p.life
                || p.x < -canvas.marginX - 4 || p.y < -canvas.marginY - 4
                || p.x > Float(canvas.width) + canvas.marginX + 4
                || p.y > Float(canvas.height) + canvas.marginY + 4 {
                tracers[i] = spawn(biasToUncovered: true)
                continue
            }

            p.checkClock += dt
            if p.checkClock > 0.6 {
                let moved = (p.x - p.checkX) * (p.x - p.checkX)
                    + (p.y - p.checkY) * (p.y - p.checkY)
                if moved < stallDistanceSquared {
                    tracers[i] = spawn(biasToUncovered: true)
                    continue
                }
                p.checkClock = 0; p.checkX = p.x; p.checkY = p.y
            }

            // Fade each stroke in and out so lines arrive and leave instead of
            // popping on and off.
            let u = p.age / p.life
            let envelope = smoothstep(0, 0.10, u) * (1 - smoothstep(0.74, 1, u))

            let (fx0, fy0) = canvas.fieldCoordinate(x: p.x, y: p.y, cols: cols, rows: rows)
            let (_, _, coh0) = field.flow(atX: fx0, y: fy0, time: time, swirl: swirl, seed: seed)
            let travel = baseSpeed * p.pace * (0.45 + 1.2 * coh0) * dt
            let steps = min(max(Int(travel / 0.5) + 1, 1), 14)
            let sub = dt / Float(steps)

            for _ in 0..<steps {
                let (sx, sy) = canvas.fieldCoordinate(x: p.x, y: p.y, cols: cols, rows: rows)
                let (dx, dy, c) = field.flow(atX: sx, y: sy, time: time, swirl: swirl, seed: seed)
                let v = baseSpeed * p.pace * (0.45 + 1.2 * c)

                // Midpoint step: visibly smoother through tight curvature.
                let mx = p.x + dx * v * sub * 0.5
                let my = p.y + dy * v * sub * 0.5
                let (mfx, mfy) = canvas.fieldCoordinate(x: mx, y: my, cols: cols, rows: rows)
                let (ex, ey, _) = field.flow(atX: mfx, y: mfy, time: time, swirl: swirl, seed: seed)

                let cross = p.drift * crossSpeed * sub * (1 - 0.45 * c)
                let stepX = ex * v * sub - ey * cross
                let stepY = ey * v * sub + ex * cross
                p.x += stepX
                p.y += stepY

                let distance = (stepX * stepX + stepY * stepY).squareRoot()

                // Load the brush from the picture, slowly.
                let (tr, tg, tb) = canvas.sourceColor(atX: p.x, y: p.y)
                if p.loaded {
                    let k = min(distance * pickupPerPixel, 1)
                    p.r += (tr - p.r) * k
                    p.g += (tg - p.g) * k
                    p.b += (tb - p.b) * k
                } else {
                    p.r = tr; p.g = tg; p.b = tb
                    p.loaded = true
                }

                let sr = p.r * p.tone, sg = p.g * p.tone, sb = p.b * p.tone

                if painting {
                    // Three dabs across the flow give the stroke a width without
                    // needing a real brush footprint. The field steers strokes
                    // *along* edges, so a wide brush sits astride one — narrow it
                    // where the structure is strong, and let the outer dabs take
                    // most of their colour from where they actually land. Without
                    // both, every boulder bleeds its dark across the water it
                    // borders.
                    let nx = -ey, ny = ex
                    let hw = p.brush * (1 - 0.62 * c)
                    let a = dabAlpha * envelope
                    canvas.paintDab(x: p.x, y: p.y, r: sr, g: sg, b: sb, alpha: a)
                    if hw > 0.35 {
                        for side in [hw, -hw] {
                            let ox = p.x + nx * side, oy = p.y + ny * side
                            let (lr, lg, lb) = canvas.sourceColor(atX: ox, y: oy)
                            canvas.paintDab(x: ox, y: oy,
                                            r: lr * 0.62 + sr * 0.38,
                                            g: lg * 0.62 + sg * 0.38,
                                            b: lb * 0.62 + sb * 0.38,
                                            alpha: a * 0.6)
                        }
                    }
                }

                // The live head, in the stroke's own hue lifted toward its bright
                // version — never toward white, or every stroke on screen ends up
                // the same colour.
                // The head light carries the opening, when the frame is dark and
                // the wind is the whole picture. Once the painting has arrived it
                // steps back — otherwise it is exactly the "colour laid on top"
                // that the photograph is not supposed to have.
                let m = max(sr, max(sg, sb))
                let lift: Float = m > 0.02 ? min(0.75 / m, 1.9) : 1
                canvas.addGlow(x: p.x, y: p.y,
                               r: sr * lift, g: sg * lift, b: sb * lift,
                               intensity: glowPerStep * envelope * glowScale)
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
    static func make(image: CGImage, canvas: Canvas,
                     settings: SimulationSettings, preview: Bool) -> Simulation {
        let seed = UInt32.random(in: 1...UInt32.max)
        canvas.setImage(image, saturation: settings.saturation)
        canvas.reset()

        // The flow field is deliberately coarse — it is a smooth field, and
        // resolving it finer only gives the tracers noise to jitter against. It
        // shares the canvas's aspect ratio, so it covers exactly the same
        // overscanned region as the colour source.
        let cols = max(64, canvas.width / 3)
        let rows = max(36, canvas.height / 3)
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
