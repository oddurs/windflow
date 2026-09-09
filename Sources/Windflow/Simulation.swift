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
        var bloom: Float = 0.30
        var relief: Float = 1.0
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
        /// Which level of the source pyramid this brush reads. A broad brush
        /// samples a blurred level so it lays in a mass of colour rather than
        /// chasing detail it is too big to describe.
        var level: Int32 = 0
        /// Opacity multiplier: a fine brush is more decisive than a broad one.
        var force: Float = 1
        /// Broken colour — a push along the warm/cool axis, unique to this
        /// stroke. Adjacent strokes then mix optically instead of averaging,
        /// which is the difference between a shimmer and a flat wash.
        var warm: Float = 0
        /// Phase of the bristle pattern across the brush.
        var bristlePhase: Float = 0
        /// The passage this stroke belongs to. A stroke that wanders out of it
        /// tapers away rather than carrying its colour into the next one.
        var home: Int32 = -1
        /// A few strokes are allowed across the boundary anyway. Without them
        /// the regions read as cut-out shapes; with them the edges breathe.
        var crosses = false
        /// Distance travelled outside the home passage. A stroke is allowed a
        /// little overlap before it is retired.
        var strayed: Float = 0
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

        let wanted = Float(canvas.width * canvas.height) / 900 * tuning.density
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

        // Coarse-to-fine. Early on the painting is nearly all broad brushes
        // laying in masses; as it fills, the mix shifts to fine brushes that
        // sharpen what the broad ones only approximated. Painting everything at
        // one scale from the start is what makes a render look like a filter.
        let pick = nextFloat()
        let coarseP = 0.44 * powf(1 - progress, 3) + 0.02
        let midP = 0.34 * (1 - progress) + 0.16
        if pick < coarseP {
            t.level = 2
            t.brush = 2.0 + nextFloat() * 1.9
            t.life = 9 + nextFloat() * 9
            t.force = 0.50
        } else if pick < coarseP + midP {
            t.level = 1
            t.brush = 0.9 + nextFloat() * 1.1
            t.life = 5 + nextFloat() * 6
            t.force = 0.82
        } else {
            t.level = 0
            t.brush = 0.25 + nextFloat() * 0.7
            t.life = 2.5 + nextFloat() * 3.5
            t.force = 1.30
        }
        // Candidates come from the overscanned region, so lines blow in over the
        // edges instead of the frame having an unpainted border.
        @inline(__always) func candidate() -> (Float, Float) {
            (nextFloat() * (Float(canvas.width) + canvas.marginX * 2) - canvas.marginX,
             nextFloat() * (Float(canvas.height) + canvas.marginY * 2) - canvas.marginY)
        }
        var (x, y) = candidate()
        var onBoundary = false
        if biasToUncovered {
            let roll = nextFloat()
            // A fine brush is only worth spending where there is fine structure
            // to describe. Scattering them evenly leaves the detailed regions
            // mushy and wastes the work on an even sky.
            if t.level == 0 && roll < 0.50 && !canvas.detailX.isEmpty {
                let k = min(Int(nextFloat() * Float(canvas.detailX.count)),
                            canvas.detailX.count - 1)
                x = canvas.detailX[k] + (nextFloat() - 0.5) * 9
                y = canvas.detailY[k] + (nextFloat() - 0.5) * 9
            } else if roll < 0.72 && !canvas.holeX.isEmpty {
                // Straight into a known hole, jittered within its cell so the
                // tracers that land there do not all trace one streamline.
                let k = min(Int(nextFloat() * Float(canvas.holeX.count)),
                            canvas.holeX.count - 1)
                x = canvas.holeX[k] + (nextFloat() - 0.5) * 9
                y = canvas.holeY[k] + (nextFloat() - 0.5) * 9
            } else if roll < 0.84 && !field.regions.boundary.isEmpty {
                // On a seam between passages. These are the strokes that state
                // where one shape stops and the next begins.
                let e = field.regions.boundary[
                    min(Int(nextFloat() * Float(field.regions.boundary.count)),
                        field.regions.boundary.count - 1)]
                let fx = Float(Int(e) % field.cols), fy = Float(Int(e) / field.cols)
                let (bx, by) = canvas.canvasPoint(fieldX: fx, fieldY: fy,
                                                  cols: field.cols, rows: field.rows)
                x = bx + (nextFloat() - 0.5) * 6
                y = by + (nextFloat() - 0.5) * 6
                onBoundary = true
            } else if roll < 0.92 {
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
        let (hfx, hfy) = canvas.fieldCoordinate(x: x, y: y, cols: field.cols, rows: field.rows)
        t.home = field.label(atX: hfx, y: hfy)
        t.crosses = onBoundary || nextFloat() < 0.15
        t.strayed = 0
        t.pace = 0.6 + nextFloat() * 0.8
        t.drift = (nextFloat() - 0.5) * 2
        t.tone = 0.92 + nextFloat() * 0.16
        t.warm = (nextFloat() - 0.5) * 0.13
        t.bristlePhase = nextFloat() * 6.2831853
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
        let glowPerStep = 0.042 * tuning.exposure / max(0.35, tuning.trail)
        let glowScale = 1 - 0.78 * progress
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

            // Strokes marked as crossing run much further over a seam; they are
            // the overlap that keeps the shapes from reading as cut-outs.
            if p.strayed > (p.crosses ? 34 : 7) {
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

                // A stroke keeps its full load right up to the seam and a little
                // way over it, then stops. The separation between passages comes
                // from where strokes *end* and from the change of direction and
                // palette across the join — never from withholding paint, which
                // only draws a dark line around every shape.
                let (lfx, lfy) = canvas.fieldCoordinate(x: p.x, y: p.y,
                                                        cols: cols, rows: rows)
                if field.label(atX: lfx, y: lfy) != p.home {
                    p.strayed += distance
                } else {
                    p.strayed = max(p.strayed - distance * 2, 0)
                }

                // Load the brush from the picture, slowly, and from the level
                // of the pyramid that matches its width.
                let level = Int(p.level)
                let (tr, tg, tb) = canvas.sourceColor(atX: p.x, y: p.y, level: level)
                if p.loaded {
                    let k = min(distance * pickupPerPixel, 1)
                    p.r += (tr - p.r) * k
                    p.g += (tg - p.g) * k
                    p.b += (tb - p.b) * k
                } else {
                    p.r = tr; p.g = tg; p.b = tb
                    p.loaded = true
                }

                // Draw the colour a little toward the passage's own mean. A
                // painter mixes from a limited palette for one passage, and it is
                // that shared bias, more than the boundary itself, that makes two
                // adjacent areas read as separate things.
                let (mr, mg, mb) = field.regionColor(p.home)
                let pull = 0.09 * min(distance * 0.08, 1)
                p.r += (mr - p.r) * pull
                p.g += (mg - p.g) * pull
                p.b += (mb - p.b) * pull

                // Broken colour: push this stroke along the warm/cool axis and
                // hold its luminance, so neighbouring strokes mix in the eye
                // rather than averaging into a flat wash.
                let warm = p.warm
                var sr = p.r * (1 + warm)
                var sg = p.g * (1 + warm * 0.12)
                var sb = p.b * (1 - warm)
                let before = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
                let after = 0.2126 * sr + 0.7152 * sg + 0.0722 * sb
                let hold = after > 0.001 ? before / after : 1
                sr *= hold * p.tone; sg *= hold * p.tone; sb *= hold * p.tone

                if painting {
                    // Lay the stroke as a row of bristles across the flow. The
                    // field steers strokes *along* edges, so a wide brush sits
                    // astride one: narrow it where the structure is strong, and
                    // let the outer bristles take most of their colour from where
                    // they actually land. Without both, every dark form bleeds
                    // across whatever it borders.
                    let nx = -ey, ny = ex
                    let hw = p.brush * (1 - 0.62 * c)
                    let a = dabAlpha * envelope * p.force
                    let bristles = min(max(Int(hw * 1.9) + 1, 1), 6)
                    let span = bristles > 1 ? 2 / Float(bristles - 1) : 0

                    for bi in 0..<bristles {
                        let t: Float = bristles > 1 ? Float(bi) * span - 1 : 0
                        let off = t * hw
                        let ox = p.x + nx * off, oy = p.y + ny * off

                        // Bristles are not identical: each carries slightly more
                        // or less paint. This is most of what makes a stroke read
                        // as a brush mark rather than a smooth ribbon.
                        let uneven = 1 + 0.22 * sin(p.bristlePhase + Float(bi) * 2.39)
                        let profile = (1 - 0.3 * abs(t)) * uneven

                        var br = sr, bg = sg, bb = sb
                        if abs(t) > 0.01 {
                            let mixLocal = 0.62 * abs(t)
                            let (lr, lg, lb) = canvas.sourceColor(atX: ox, y: oy, level: level)
                            br += (lr - br) * mixLocal
                            bg += (lg - bg) * mixLocal
                            bb += (lb - bb) * mixLocal
                        }

                        canvas.paintDab(x: ox, y: oy, r: br, g: bg, b: bb,
                                        alpha: a * profile,
                                        thickness: a * profile * 0.34)
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

    /// Paint thickness settles far more slowly than the light on the stroke
    /// heads. Letting it decay at all — rather than accumulating forever — keeps
    /// the surface from filling in flat, and means the relief always shows the
    /// most recent brushwork, so the light on the finished picture keeps moving.
    func reliefFactor(dt: Float) -> Float {
        exp(-dt / 16.0)
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
    var relief: Float
    var regions: Float
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
        relief = Float(prefs.relief)
        regions = Float(prefs.regions)
        secondsPerImage = Float(prefs.secondsPerImage)
    }
}

/// Everything one photograph needs before it can be painted. Built entirely off
/// the render thread — grading, the pyramid, the structure tensor and the
/// segmentation together cost a few hundred milliseconds, which is a visible
/// freeze if it happens where the frames are drawn.
struct PreparedImage {
    let source: SourceImage
    let field: FlowField
    let seed: UInt32
    let canvasWidth: Int
    let canvasHeight: Int

    static func prepare(image: CGImage, canvasWidth: Int, canvasHeight: Int,
                        coverW: Int, coverH: Int,
                        settings: SimulationSettings) -> PreparedImage {
        let seed = UInt32.random(in: 1...UInt32.max)
        let source = SourceImage(image: image, width: canvasWidth, height: canvasHeight,
                                 saturation: settings.saturation,
                                 coverW: coverW, coverH: coverH)
        // The field is deliberately coarser than the canvas: it is a smooth
        // field, and resolving it finer only gives the tracers noise to jitter
        // against. It shares the canvas aspect, so it covers exactly the same
        // overscanned region as the colour source.
        let cols = max(64, canvasWidth / 3)
        let rows = max(36, canvasHeight / 3)
        let field = FlowField(image: image, cols: cols, rows: rows, aspect: 1,
                              seed: seed, drift: settings.drift,
                              regionCount: max(6, Int(settings.regions)))
        return PreparedImage(source: source, field: field, seed: seed,
                             canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }
}

extension Simulation {
    /// Hand a prepared photograph to the canvas and start painting it. This part
    /// touches shared state, so it belongs on the render thread — but it is only
    /// a couple of reference assignments and a buffer clear.
    static func begin(_ prepared: PreparedImage, canvas: Canvas,
                      settings: SimulationSettings, preview: Bool) -> Simulation {
        canvas.adopt(prepared.source)
        canvas.reset()
        var tuning = Tuning()
        tuning.density = settings.density
        tuning.speed = settings.speed
        tuning.trail = settings.trail
        tuning.exposure = settings.exposure
        tuning.swirl = settings.swirl
        tuning.bloom = settings.bloom
        tuning.relief = settings.relief
        tuning.totalSeconds = settings.secondsPerImage
        tuning.revealTimeout = max(20, settings.secondsPerImage * 0.85)
        return Simulation(field: prepared.field, canvas: canvas, tuning: tuning,
                          seed: prepared.seed, preview: preview)
    }
}
