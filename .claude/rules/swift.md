---
paths:
  - "Sources/**/*.swift"
---

# Swift in this project

The renderer walks several million pixels per frame on the CPU, so the hot paths
are written against unsafe buffer pointers. That buys speed and costs the
guardrails, and every bug below has actually happened here.

## Numerics

- **Clamp before a square root.** Values that are non-negative in theory are not in
  floating point: the sliding-window box blur in `FlowField.buildFlow` drifts the
  tensor diagonal slightly below zero over a flat field, and `sqrt` of that is NaN.
  One NaN reaches every flow vector in the frame.
- **`Int(someFloat)` traps on NaN or infinity, and a bounds check does not save you** —
  every comparison against NaN is false, so the guard passes and the conversion
  crashes. Guard the value, not the range.
- Prefer `min(max(v, lo), hi)` at the point a value enters an index or a `UInt8`.

## Concurrency

- `DispatchQueue.concurrentPerform` bands must write strictly disjoint ranges.
  Reading a neighbouring band is fine; a layer that is *mutated* per frame is
  decayed in its own pass before anything reads across band edges
  (`Canvas.decayLayers`), otherwise there is a seam at every thread boundary.
- Anything that touches the canvas belongs on the render thread. Everything that
  only derives from a `CGImage` belongs on the loader queue.

## Exclusivity

While an array is checked out with `withUnsafeMutableBufferPointer`, the property
it came from is invalid. Do not call a method that reaches for it — thread the
pointer through instead, as `Simulation.spawn` does.

## Determinism

Every random choice comes from the seeded generator in `Simulation`, never from
`UInt32.random` mid-run. A fixed `PreparedImage.prepare(seed:)` must reproduce a
frame exactly; the test suite depends on it.
