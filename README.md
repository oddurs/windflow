# Windflow

A macOS screensaver that draws your aerial photographs out of moving wind.

The photograph is never drawn. It exists only as a palette that the wind
*samples*. The screen starts black; coloured streaks appear and begin flowing
along the structure of the image — the braids of a glacial river, the ridges of a
dune field, the shear in a cloud deck — and the picture assembles out of their
accumulated paint until it is fully present. Then it dissolves back into the wind
and the next photograph begins.

What you end up looking at is a painting made of weather that happens to converge
on the photograph. There is no layer of the real image anywhere in the frame.

## Install

```sh
scripts/build.sh     # builds a universal Windflow.saver + a preview harness
scripts/install.sh   # copies it to ~/Library/Screen Savers and restarts the host
```

Then **System Settings → Screen Saver → Other → Windflow**, and **Options…** to
add your photographs.

## Adding photographs

Use **Options… → Add Photos…** in System Settings. Files are *copied* into
`~/Library/Application Support/Windflow/Images` rather than referenced where they
sit — `legacyScreenSaver`, the sandboxed process that hosts a `.saver` on modern
macOS, cannot read arbitrary paths later even if you granted access at the time
you picked them. Copying sidesteps that entirely.

With no photographs added, a procedurally generated braided delta is used so the
screensaver is never blank.

## How it works

**The flow field.** The direction the wind travels is the *edge tangent* of the
photograph: the minor eigenvector of its smoothed structure tensor. For an aerial
river that means the vectors run **along** the channels rather than across them,
so the streaks trace the water instead of cutting over it. Anisotropy of the
tensor says how much real structure is present; where the photo is featureless —
open sand, sky, snow — the tangent is meaningless, so it fades over to a
divergence-free curl-noise field and the streaks open out into free weather.
The tangent is a director rather than a vector, so it is flipped to agree with
the global wind before use, which is what stops neighbouring streaks running into
each other.

**The tracers.** A few thousand particles are advected through that field with a
midpoint step. Each carries a small persistent *cross-flow* bias: edge-tangent
fields are full of closed contours, and a tracer following one exactly would orbit
it forever, burning a bright ring into the frame while leaving the rest of the
picture untouched. The drift turns every orbit into a slow spiral, so the swarm
sweeps the plane. Tracers that stall in a sink of the field are detected and
recycled, and new ones start at the worst-covered point of several candidates so
the flow's shadow zones still fill in.

**The paint.** Each tracer carries a brush loaded with colour taken from the
picture — but the colour *lags*, taking around a dozen pixels of travel to catch
up. A stroke therefore carries the hue it started with a little way across a
boundary before turning into the new one. That lag is the whole trick: it is why
the result reads as brushwork rather than as the photograph with lines drawn over
it, and why a plain blue sky comes out as a dozen different blues. Dabs blend
toward the stroke colour rather than adding to it, so overlapping strokes behave
like paint instead of blowing out to white, and the accumulated field converges on
the picture. Per-stroke brush width and tone vary, which is what leaves visible
texture at convergence instead of a smooth photograph.

A separate additive layer holds the live light at each stroke's head, faded every
frame and capped per channel a little above the stroke's own colour — uncapped,
every place where several strokes share a path (a strong edge, which is exactly
where they gather) clips to white and reads as a hard drawn line.

**The edges.** The colour source and the flow field both cover a region 11%
larger than the frame in each direction, and tracers live in that larger space.
Lines blow in and out from off-screen rather than dying against a border, and the
visible frame is a slight crop into the photograph.

## Development

`scripts/build.sh` also produces two tools that make iterating bearable, since
the normal screensaver loop means reinstalling and logging out:

```sh
build/windflow-preview                                   # windowed harness
build/windflow-dump out/ photo.jpg 1600 900 4,20,45,75   # headless PNG frames
```

In the preview harness: <kbd>space</kbd> next photograph, <kbd>f</kbd> full
screen, <kbd>c</kbd> configuration sheet, <kbd>r</kbd> restart, <kbd>q</kbd> quit.
`WINDFLOW_MASK=1` on the dumper also writes the coverage grid and a histogram,
which is how you diagnose a photo the wind fails to cover.

Built with `swiftc` directly — no Xcode project. Only the Command Line Tools are
required. The renderer is entirely CPU-side, which avoids the Metal toolchain
(not shipped with CLT) and the long-standing flakiness of `CAMetalLayer` inside
`legacyScreenSaver`; a frame costs around 4 ms at the capped render resolution.

## Settings

| | |
|---|---|
| Streams | how many lines are in the air at once |
| Wind speed | how fast they travel |
| Trail length | how long a streak stays lit behind the head |
| Wander | turbulence layered over the photo's own structure |
| Freedom | 0 traces the photo exactly, 1 lets open wind take over |
| Colour depth | saturation of the recovered image |
| Exposure | line brightness |
| Bloom | halo around the brightest lines |
| Time per image | reveal plus the hold before it dissolves |
