import Foundation
import AppKit

// Headless frame dumper. Runs the simulation at a fixed timestep and writes PNGs
// at chosen moments, so the look can be checked without installing anything.
//
//   windflow-dump <out-dir> [image.jpg|-] [width] [height] [times,comma,separated]

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "./frames")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let imagePath: String? = args.count > 2 && args[2] != "-" ? args[2] : nil
let width = args.count > 3 ? Int(args[3])! : 1600
let height = args.count > 4 ? Int(args[4])! : 900
let captureAt: [Double] = args.count > 5
    ? args[5].split(separator: ",").compactMap { Double($0) }
    : [0.4, 1.2, 3.0, 7.0, 15.0, 32.0, 60.0]

let image: CGImage = {
    if let imagePath, let img = ImageLibrary.load(URL(fileURLWithPath: imagePath), maxPixel: 2560) {
        return img
    }
    return ProceduralImage.make()!
}()

let canvas = Canvas(width: width, height: height)
let settings = SimulationSettings(prefs: Preferences.shared)
let sim = Simulation.make(image: image, canvas: canvas, settings: settings, preview: false)
print("canvas \(width)x\(height)  field \(sim.field.cols)x\(sim.field.rows)")

let dt: Float = 1.0 / 60.0
var captureIndex = 0
var t: Double = 0
var frame = 0
let end = (captureAt.max() ?? 1) + 0.1

var stepTotal: Double = 0
var presentTotal: Double = 0

while t <= end {
    let s0 = CFAbsoluteTimeGetCurrent()
    sim.step(dt: dt)
    let s1 = CFAbsoluteTimeGetCurrent()
    let cg = canvas.present(fade: sim.fadeFactor(dt: dt),
                            bloomAmount: sim.tuning.bloom,
                            vignetteAmount: 0.30)
    let s2 = CFAbsoluteTimeGetCurrent()
    stepTotal += s1 - s0
    presentTotal += s2 - s1

    if captureIndex < captureAt.count && t >= captureAt[captureIndex] {
        if let cg, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            let name = String(format: "t%05.1fs.png", captureAt[captureIndex])
            try? png.write(to: outDir.appendingPathComponent(name))
            print("wrote \(name)  phase=\(sim.phase)")
        }
        if ProcessInfo.processInfo.environment["WINDFLOW_MASK"] != nil {
            if let mask = canvas.debugCoverageImage(),
               let png = NSBitmapImageRep(cgImage: mask).representation(using: .png, properties: [:]) {
                let name = String(format: "mask-t%05.1fs.png", captureAt[captureIndex])
                try? png.write(to: outDir.appendingPathComponent(name))
            }
            let bins = canvas.debugCoverageHistogram()
            let total = bins.reduce(0, +)
            print("  coverage deciles: " + bins.map { String(format: "%.1f%%", Double($0) * 100 / Double(total)) }.joined(separator: " "))
        }
        captureIndex += 1
    }

    t += Double(dt)
    frame += 1
}

print(String(format: "sim %.2f ms/frame, present %.2f ms/frame over %d frames",
             stepTotal / Double(frame) * 1000,
             presentTotal / Double(frame) * 1000, frame))
