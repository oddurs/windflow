# Windflow

A macOS screensaver that paints a photograph out of moving wind. Read `README.md`
for how it works; this file is the part you cannot infer from the code.

## Commands

```sh
scripts/setup                  # once after cloning: wires the git hooks
scripts/task check             # fmt:check, lint, test, build — the gate
scripts/task test              # tests alone
build/windflow-preview         # windowed harness: space next, c config, f fullscreen, q quit
build/windflow-dump out/ photo.jpg 1600 900 5,20,72   # headless PNGs at those seconds
scripts/install.sh             # copy the built .saver to ~/Library/Screen Savers
```

`WINDFLOW_SEED=99` fixes every random choice, so two renders are byte-identical.
`WINDFLOW_MASK=1` also writes the coverage grid and a histogram — that is how you
diagnose a photograph the wind fails to cover.

## Build

There is no Xcode project and no SwiftPM manifest. A `.saver` is a bundle with a
principal class, which neither produces, so `scripts/build.sh` drives `swiftc`
directly and assembles the bundle by hand. Three products come out of one set of
sources: the screensaver, the preview harness, and the frame dumper.

- **The bundle must be ad-hoc signed.** Unsigned, macOS refuses to load it at all.
- **Do not reach for Metal.** The Command Line Tools no longer ship a `metal`
  compiler, and `CAMetalLayer` inside `legacyScreenSaver` has a long history of
  drawing nothing. The renderer is CPU-side and comfortably inside frame budget.

## Traps

- **The screensaver host is sandboxed.** `legacyScreenSaver` cannot read a path the
  user picked earlier, so photographs are *copied* into
  `~/Library/Application Support/Windflow/Images`, never referenced in place.
- **Iterate through `build/windflow-preview`, not System Settings.** System Settings
  caches the module aggressively; `scripts/install.sh` restarts the host for that
  reason, and it still sometimes needs a full quit.
- **Nothing may run on the render thread that takes more than a frame.** Preparing a
  photograph costs a few hundred milliseconds and happens on the loader queue; the
  canvas adopts the result by reference.
- **Verify the look by rendering frames, not by reasoning.** `windflow-dump` exists
  because every aesthetic bug in this project's history was invisible in the code
  and obvious in a PNG.

## Workflow

- Never commit to `main`. It advances only through a merged pull request.
- One unit of work, one worktree, one branch, one PR: `scripts/agent start fix/the-thing`.
- `scripts/task check` must pass before a PR. The hooks enforce it; never `--no-verify`.
- Conventional Commits, subject ≤ 72 chars, imperative, no trailing period.
- No AI or assistant attribution in commits, PRs, comments, or docs.
