import Foundation

/// Splits the photograph into painted regions.
///
/// A painter does not drag one stroke from the water up into the sunlit silt;
/// they work a passage at a time, and the meeting of two passages is what makes
/// an edge read. Without this, a broad brush has no idea where a shape ends and
/// smears its colour across the whole frame — which is exactly what a filter
/// does and a painting does not.
///
/// The method is SLIC: k-means in a joint colour-and-position space, with each
/// pixel only compared against the handful of centres near it. Low compactness
/// lets a region stretch along a river channel instead of staying a tidy blob,
/// so the regions come out shaped like the things in the picture.
struct Segmentation {

    let cols: Int
    let rows: Int
    let count: Int
    /// Region index per cell.
    let labels: [Int32]
    /// Mean colour of each region — the local palette a stroke is pulled toward.
    let meanR: [Float]
    let meanG: [Float]
    let meanB: [Float]
    /// Cells where the region changes. Strokes aimed here describe the shapes.
    let boundary: [Int32]

    init(r: [Float], g: [Float], b: [Float], cols: Int, rows: Int,
         targetRegions: Int, compactness: Float) {
        self.cols = cols
        self.rows = rows
        let n = cols * rows

        // Seed centres on a regular grid; the spacing sets the scale of a region.
        let spacing = max(4, Int((Float(n) / Float(max(targetRegions, 2))).squareRoot()))
        var cx = [Float](), cy = [Float](), cr = [Float](), cg = [Float](), cb = [Float]()
        var gy = spacing / 2
        while gy < rows {
            var gx = spacing / 2
            while gx < cols {
                let i = gy * cols + gx
                cx.append(Float(gx)); cy.append(Float(gy))
                cr.append(r[i]); cg.append(g[i]); cb.append(b[i])
                gx += spacing
            }
            gy += spacing
        }
        let k = max(1, cx.count)
        count = k

        var assign = [Int32](repeating: -1, count: n)
        // Colour and position have to be commensurate. Channels here are 0...1,
        // so a squared colour distance tops out near 3 while a squared position
        // distance across the search window reaches 4 — leave it there and the
        // position term wins every comparison and the regions come out as a
        // rigid grid of squares. `compactness` scales colour up until it leads.
        let colourWeight = compactness * compactness
        let invSpacing = 1 / Float(spacing)
        let search = spacing * 2

        var sumR = [Float](repeating: 0, count: k)
        var sumG = [Float](repeating: 0, count: k)
        var sumB = [Float](repeating: 0, count: k)
        var sumX = [Float](repeating: 0, count: k)
        var sumY = [Float](repeating: 0, count: k)
        var tally = [Float](repeating: 0, count: k)

        for _ in 0..<10 {
            var best = [Float](repeating: .greatestFiniteMagnitude, count: n)
            for c in 0..<k {
                let x0 = max(Int(cx[c]) - search, 0), x1 = min(Int(cx[c]) + search, cols - 1)
                let y0 = max(Int(cy[c]) - search, 0), y1 = min(Int(cy[c]) + search, rows - 1)
                let ccr = cr[c], ccg = cg[c], ccb = cb[c], ccx = cx[c], ccy = cy[c]
                for y in y0...y1 {
                    let row = y * cols
                    let dy = (Float(y) - ccy) * invSpacing
                    let dy2 = dy * dy
                    for x in x0...x1 {
                        let i = row + x
                        let dr = r[i] - ccr, dg = g[i] - ccg, db = b[i] - ccb
                        let dx = (Float(x) - ccx) * invSpacing
                        let d = (dr * dr + dg * dg + db * db) * colourWeight
                            + dx * dx + dy2
                        if d < best[i] { best[i] = d; assign[i] = Int32(c) }
                    }
                }
            }

            for c in 0..<k {
                sumR[c] = 0; sumG[c] = 0; sumB[c] = 0
                sumX[c] = 0; sumY[c] = 0; tally[c] = 0
            }
            for y in 0..<rows {
                let row = y * cols
                for x in 0..<cols {
                    let i = row + x
                    let c = Int(assign[i])
                    if c < 0 { continue }
                    sumR[c] += r[i]; sumG[c] += g[i]; sumB[c] += b[i]
                    sumX[c] += Float(x); sumY[c] += Float(y); tally[c] += 1
                }
            }
            for c in 0..<k where tally[c] > 0 {
                let inv = 1 / tally[c]
                cr[c] = sumR[c] * inv; cg[c] = sumG[c] * inv; cb[c] = sumB[c] * inv
                cx[c] = sumX[c] * inv; cy[c] = sumY[c] * inv
            }
        }

        // Any cell no centre reached keeps its nearest neighbour's region.
        for i in 0..<n where assign[i] < 0 { assign[i] = i > 0 ? assign[i - 1] : 0 }

        labels = assign
        meanR = cr; meanG = cg; meanB = cb

        var edges = [Int32]()
        for y in 1..<(rows - 1) {
            let row = y * cols
            for x in 1..<(cols - 1) {
                let i = row + x
                let l = assign[i]
                if assign[i - 1] != l || assign[i + 1] != l
                    || assign[i - cols] != l || assign[i + cols] != l {
                    edges.append(Int32(i))
                }
            }
        }
        boundary = edges
    }
}
