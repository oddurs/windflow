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

**The passages.** The picture is first divided into regions — SLIC, k-means in a
joint colour-and-position space, run on the coarse field. A painter does not drag
one stroke from the water up into the sunlit silt; they work a passage at a time,
and the meeting of two passages is what makes an edge read. Each region gets its
own prevailing direction, taken from its own summed structure tensor, and its own
seeded turbulence — so different shapes in the frame carry visibly different line
patterns. A stroke belongs to one passage, keeps its full load right up to the
seam and a little way over it, then stops. The separation comes from where strokes
*end*, never from withholding paint at the join; withholding it draws a dark
outline around every shape. A minority of strokes are marked as crossing and run
much further over, and that overlap is what keeps the regions from reading as
cut-outs.

**The scale.** Brushes come in three sizes, and each reads a different level of a
source pyramid: a broad brush samples a blurred level, so it lays in a mass of
colour without chasing detail it is too big to describe. The mix starts almost
entirely broad and shifts to fine as the picture fills. Fine brushes are aimed at
the cells with the most local contrast — scattering them evenly leaves the
detailed regions mushy and spends the work on an even sky.

**The paint.** Each stroke carries a brush loaded from the picture, and the colour
*lags* — long at the start, so the opening is abstract; short by the end, so the
finish is faithful. It is also drawn slightly toward its passage's mean colour,
the way a painter mixes from a limited palette for one passage, and pushed along
the warm/cool axis by a per-stroke amount at constant luminance. That is broken
colour: neighbouring strokes mix in the eye instead of averaging into a flat wash.
Dabs blend toward the stroke colour rather than adding, so overlapping strokes
behave like paint instead of blowing out. A stroke is laid as a row of bristles
across the flow, each carrying slightly more or less paint, which is most of what
makes it read as a brush mark rather than a smooth ribbon.

**The surface.** Paint has thickness. Every dab raises a height field, so the
canvas carries the ridge of each stroke over a faint weave, and the frame is lit
by raking a directional light across that relief. This is the difference between a
painting and a filtered photograph: the brightness on screen is a property *of the
paint* rather than a glow laid over the top of it. The relief decays slowly, so
the light always follows the most recent brushwork and the finished picture keeps
moving. A small additive layer still marks the live stroke heads, but it fades out
as the paint arrives.

**The edges.** The colour source and the flow field both cover a region 11% larger
than the frame in each direction, and tracers live in that larger space. Lines
blow in and out from off-screen rather than dying against a border, and the visible
frame is a slight crop into the photograph.

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
