# Windflow

A macOS screensaver that draws your aerial photographs out of moving wind.

Every lit pixel on screen got there because a line of light moved through it.
Nothing is ever blitted from the source image. The screen starts black; streaks
appear and begin flowing along the structure of the photograph — the braids of a
glacial river, the ridges of a dune field, the shear in a cloud deck — and the
picture slowly accumulates in their wake until it is fully present. Then it
dissolves back into the wind and the next photograph begins.

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

**The layers.** Three, composited every frame:

| layer | resolution | behaviour |
|---|---|---|
| `target` | full | the graded photograph, only ever seen through `reveal` |
| `reveal` | half | coverage that grows where a line passed; permanent |
| `glow` | full | additive light from the lines, faded every frame |

The fade on `glow` is what turns a moving point into a streak. `reveal` is
deposited on a wider brush than the light, so the stroke stays hairline sharp
while the picture behind it fills in smoothly, and it is gently blurred late in
the cycle so the finish is not combed. Bloom is built from `glow` at quarter
resolution and added back.

**Colour.** Lines are drawn in the photograph's own hue held at a high, even
value — sampling the image directly would make them invisible over exactly the
dark regions where the interesting structure lives. The scale is applied to all
three channels at once, so hue and saturation are untouched and only brightness
is raised.

## Development

`scripts/build.sh` also produces two tools that make iterating bearable, since
the normal screensaver loop means reinstalling and logging out:

```sh
build/windflow-preview                                   # windowed harness
build/windflow-dump out/ photo.jpg 1600 900 4,20,45,75   # headless PNG frames
```

In the preview harness: <kbd>space</kbd> next photograph, <kbd>f</kbd> full
screen, <kbd>c</kbd> configuration sheet, <kbd>r</kbd> restart, <kbd>q</kbd> quit.
`WINDFLOW_MASK=1` on the dumper also writes the coverage mask and a coverage
histogram, which is how you diagnose a photo the wind fails to cover.

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
