---
name: render-frames
description: Render Windflow frames headlessly to PNG and inspect them, to judge or debug how a photograph looks. Use whenever changing the flow field, the segmentation, the brushes, the colour handling or the lighting — anything whose effect is visual rather than logical.
---

# Render frames and look at them

Every aesthetic bug in this project was invisible in the code and obvious in a
PNG. Do not reason about how a change will look; render it.

## Render

```sh
scripts/task build
build/windflow-dump out/ ~/path/photo.jpg 1600 900 5,20,45,72
```

The trailing list is seconds into the cycle. A full cycle is 75 s by default:
roughly 0–10 s is bare wind on black, the picture assembles through the middle,
and it holds before dissolving. Sample at least one early, one middle and one
late frame — a change that improves the finish often ruins the opening.

Then **read the PNGs**. The run also prints per-frame simulation and compositing
cost; both together must stay under about 10 ms at 1600×900.

## Compare two builds

```sh
WINDFLOW_SEED=99 build/windflow-dump before/ photo.jpg 1600 900 30
# make the change, rebuild
WINDFLOW_SEED=99 build/windflow-dump after/  photo.jpg 1600 900 30
```

A fixed seed makes the two runs byte-comparable, so anything that differs is the
change and not the dice.

## Diagnose a photograph that will not fill in

```sh
WINDFLOW_MASK=1 build/windflow-dump out/ photo.jpg 1600 900 20,70
```

This also writes the coverage grid as greyscale and prints a decile histogram.
Dark patches in the mask are places no streamline enters — sinks and centres of
the flow field. The bottom decile should be well under 1% by the end of a cycle.
If it is not, the spawn aiming in `Simulation.spawn` is the thing to look at, not
the brushes.

## Read the result

- **Uniform hair everywhere** — the brush scales have collapsed to one. Check the
  coarse/fine mix in `spawn`.
- **Dark outlines around shapes** — strokes are being starved at region seams.
  Separation must come from strokes *ending*, never from withholding paint.
- **Colour that looks laid over the image** — something between the source and the
  frame is editorialising: saturation, the tone curve, bloom, or the vignette.
- **Black wedges** — coverage holes; see the mask above.
