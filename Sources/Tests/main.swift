import AppKit
import CoreGraphics
import Foundation

// Windflow's test suite. There is no XCTest here because there is no Xcode
// project and no SwiftPM manifest — the screensaver is a bundle built by
// swiftc — so this is a plain executable that exits non-zero on failure.

// Unbuffered: a trap in a test must not take the log with it.
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

func check(
    _ name: String, _ condition: @autoclosure () -> Bool,
    _ detail: @autoclosure () -> String = ""
) {
    checks += 1
    if condition() {
        print("  ok   \(name)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= tolerance }

func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

/// Solid-colour test image, optionally split into a left and a right half.
func makeImage(
    width: Int, height: Int,
    _ colorAt: (Int, Int) -> (Float, Float, Float)
) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = colorAt(x, y)
            let o = (y * width + x) * 4
            pixels[o] = UInt8(min(max(r, 0), 1) * 255)
            pixels[o + 1] = UInt8(min(max(g, 0), 1) * 255)
            pixels[o + 2] = UInt8(min(max(b, 0), 1) * 255)
            pixels[o + 3] = 255
        }
    }
    return pixels.withUnsafeMutableBytes { buf -> CGImage in
        let ctx = CGContext(
            data: buf.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

func defaultSettings() -> SimulationSettings { SimulationSettings(prefs: Preferences.shared) }

func run(
    image: CGImage, width: Int, height: Int, seconds: Float,
    seed: UInt32 = 1234
) -> (Canvas, Simulation) {
    let canvas = Canvas(width: width, height: height)
    let (cw, ch) = canvas.coverageSize
    let settings = defaultSettings()
    let prepared = PreparedImage.prepare(
        image: image, canvasWidth: width, canvasHeight: height,
        coverW: cw, coverH: ch, settings: settings, seed: seed)
    let sim = Simulation.begin(prepared, canvas: canvas, settings: settings, preview: false)
    let dt: Float = 1.0 / 60.0
    var t: Float = 0
    while t < seconds {
        sim.step(dt: dt)
        _ = canvas.present(
            fade: sim.fadeFactor(dt: dt), reliefKeep: sim.reliefFactor(dt: dt),
            bloomAmount: sim.tuning.bloom, vignetteAmount: 0.12,
            lighting: sim.tuning.relief)
        t += dt
    }
    return (canvas, sim)
}

// MARK: -

suite("overscan mapping") {
    let canvas = Canvas(width: 640, height: 360)
    let cols = 160, rows = 90
    // The tracer space extends past the frame; mapping into the field and back
    // has to be the identity or the wind lands somewhere other than the colour.
    var worst: Float = 0
    for (x, y) in [(0, 0), (320, 180), (639, 359), (-60, -30), (700, 400)] {
        let (fx, fy) = canvas.fieldCoordinate(
            x: Float(x), y: Float(y), cols: cols, rows: rows)
        let (bx, by) = canvas.canvasPoint(fieldX: fx, fieldY: fy, cols: cols, rows: rows)
        worst = max(worst, max(abs(bx - Float(x)), abs(by - Float(y))))
    }
    check("field/canvas round trip is the identity", worst < 0.01, "worst error \(worst)")

    // The frame must sit strictly inside the overscanned region.
    check("overscan extends past the frame", canvas.marginX > 0 && canvas.marginY > 0)
}

suite("orientation") {
    // A bright top half must paint a bright top half. Getting this wrong renders
    // every photograph upside down, and it is invisible in a symmetrical image.
    let image = makeImage(width: 400, height: 240) { _, y in
        y < 120 ? (0.95, 0.95, 0.95) : (0.06, 0.06, 0.06)
    }
    let (canvas, _) = run(image: image, width: 400, height: 240, seconds: 6)
    var top: Float = 0, bottom: Float = 0
    for y in stride(from: 10, to: 100, by: 6) {
        for x in stride(from: 20, to: 380, by: 6) {
            top += canvas.paintColor(atX: x, y: y).1
            bottom += canvas.paintColor(atX: x, y: 239 - y).1
        }
    }
    check(
        "bright half of the source paints the bright half of the frame",
        top > bottom * 2, "top \(top) bottom \(bottom)")
}

suite("segmentation") {
    let cols = 120, rows = 80
    var r = [Float](repeating: 0, count: cols * rows)
    var g = [Float](repeating: 0, count: cols * rows)
    var b = [Float](repeating: 0, count: cols * rows)
    for y in 0..<rows {
        for x in 0..<cols {
            let i = y * cols + x
            if x < cols / 2 {
                r[i] = 0.9; g[i] = 0.1; b[i] = 0.1
            } else {
                r[i] = 0.1; g[i] = 0.2; b[i] = 0.9
            }
        }
    }
    let seg = Segmentation(
        r: r, g: g, b: b, cols: cols, rows: rows, targetRegions: 12, compactness: 4.6)

    check("every cell has a region", seg.labels.allSatisfy { $0 >= 0 && Int($0) < seg.count })
    check("more than one region", seg.count > 1, "count \(seg.count)")

    let left = seg.labels[(rows / 2) * cols + cols / 10]
    let right = seg.labels[(rows / 2) * cols + (cols * 9) / 10]
    check("a colour boundary separates regions", left != right)

    let li = Int(left), ri = Int(right)
    check(
        "left region's palette is the left colour",
        seg.meanR[li] > 0.6 && seg.meanB[li] < 0.4,
        "mean \(seg.meanR[li]), \(seg.meanG[li]), \(seg.meanB[li])")
    check(
        "right region's palette is the right colour",
        seg.meanB[ri] > 0.6 && seg.meanR[ri] < 0.4,
        "mean \(seg.meanR[ri]), \(seg.meanG[ri]), \(seg.meanB[ri])")
    check("the seam is found", !seg.boundary.isEmpty)
}

suite("flow field") {
    // Horizontal bands: the gradient runs vertically, so the edge tangent — and
    // therefore the wind — must run horizontally.
    let image = makeImage(width: 480, height: 320) { _, y in
        let v: Float = (y / 16) % 2 == 0 ? 0.85 : 0.15
        return (v, v, v)
    }
    let field = FlowField(
        image: image, cols: 160, rows: 107, aspect: 1, seed: 42, drift: 0, regionCount: 8)

    var offAxis: Float = 0
    var counted = 0
    var worstLength: Float = 0
    for y in stride(from: 8, to: 99, by: 3) {
        for x in stride(from: 8, to: 152, by: 3) {
            let (dx, dy, coh) = field.flow(
                atX: Float(x), y: Float(y), time: 0, swirl: 0, seed: 42)
            worstLength = max(worstLength, abs((dx * dx + dy * dy).squareRoot() - 1))
            if coh > 0.5 {
                offAxis += abs(dy)
                counted += 1
            }
        }
    }
    check("flow vectors are unit length", worstLength < 0.001, "worst \(worstLength)")
    check("banded image produces coherent cells", counted > 100, "\(counted) cells")
    check(
        "wind runs along the bands, not across them",
        counted > 0 && offAxis / Float(counted) < 0.35,
        "mean |dy| \(counted > 0 ? offAxis / Float(counted) : -1)")
}

suite("paint") {
    let canvas = Canvas(width: 64, height: 64)
    let image = makeImage(width: 64, height: 64) { _, _ in (0.2, 0.4, 0.8) }
    let (cw, ch) = canvas.coverageSize
    canvas.adopt(
        SourceImage(
            image: image, width: 64, height: 64, saturation: 1.0, coverW: cw, coverH: ch))
    canvas.reset()

    check("paint starts empty", canvas.paintColor(atX: 32, y: 32).0 == 0)

    // Dabs blend toward the colour rather than adding to it, so repeated dabs
    // converge and never overshoot.
    for _ in 0..<200 {
        canvas.paintDab(x: 32, y: 32, r: 0.2, g: 0.4, b: 0.8, alpha: 0.2, thickness: 0.01)
    }
    let (pr, pg, pb) = canvas.paintColor(atX: 32, y: 32)
    check(
        "paint converges on the stroke colour",
        near(pr, 0.2, 0.02) && near(pg, 0.4, 0.02) && near(pb, 0.8, 0.02),
        "got \(pr), \(pg), \(pb)")
    check("paint never exceeds the stroke colour", pb <= 0.81, "blue \(pb)")

    canvas.fadePaint(0.0)
    check("dissolve clears the paint", canvas.paintColor(atX: 32, y: 32).2 < 0.01)
}

suite("coverage") {
    // The flow field has sinks and centres that no streamline enters. Tracers
    // are aimed at what is left unpainted so those do not survive as holes.
    let image = makeImage(width: 480, height: 270) { x, y in
        let v = 0.35 + 0.3 * sin(Float(x) * 0.03) * cos(Float(y) * 0.05)
        return (v, v * 0.8, 0.6)
    }
    let (canvas, sim) = run(image: image, width: 480, height: 270, seconds: 70)
    canvas.refreshCoverage()
    let mean = canvas.meanCoverage()
    check("the picture arrives", mean > 0.85, "mean coverage \(mean)")

    let histogram = canvas.debugCoverageHistogram()
    let total = histogram.reduce(0, +)
    let empty = Double(histogram[0]) / Double(total)
    check(
        "almost nothing is left unpainted", empty < 0.03,
        String(format: "%.1f%% of cells below 10%%", empty * 100))
    check("the reveal reaches a later phase", sim.phase != .revealing, "phase \(sim.phase)")
}

suite("determinism") {
    let image = makeImage(width: 240, height: 135) { x, y in
        (Float(x) / 240, Float(y) / 135, 0.5)
    }
    let a = run(image: image, width: 240, height: 135, seconds: 3, seed: 777).0.debugChecksum()
    let b = run(image: image, width: 240, height: 135, seconds: 3, seed: 777).0.debugChecksum()
    let c = run(image: image, width: 240, height: 135, seconds: 3, seed: 778).0.debugChecksum()
    check("the same seed paints the same picture", a == b, "\(a) vs \(b)")
    check("a different seed paints a different picture", a != c)
}

suite("library and defaults") {
    check(
        "common photo formats are accepted",
        ["jpg", "jpeg", "png", "heic", "tiff"].allSatisfy(
            ImageLibrary.allowedExtensions.contains))
    check("raw and video are not", !ImageLibrary.allowedExtensions.contains("mov"))

    let prefs = Preferences.shared
    check(
        "defaults are registered",
        prefs.density > 0 && prefs.speed > 0 && prefs.secondsPerImage >= 20
            && prefs.regions >= 6)

    check(
        "the procedural stand-in renders", ProceduralImage.make(width: 160, height: 90) != nil)
}

// MARK: -

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
