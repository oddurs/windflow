---
name: release
description: Build, package and install the Windflow screensaver bundle. Use when cutting a release, producing a .saver to distribute, or installing a local build for real testing in System Settings.
disable-model-invocation: true
---

# Release a build

## Verify first

```sh
scripts/task check
```

Then render frames and look at them — the suite proves the code is correct, not
that the output is beautiful. See the `render-frames` skill.

## Build and install locally

```sh
scripts/build.sh      # universal arm64 + x86_64, ad-hoc signed
scripts/install.sh    # copies to ~/Library/Screen Savers and restarts the host
```

Then **System Settings → Screen Saver → Other → Windflow**. If a change does not
appear, quit System Settings completely and reopen it; the module list is cached
harder than the restart in `install.sh` handles.

## Package for distribution

```sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    build/Windflow.saver/Contents/Info.plist)
ditto -c -k --keepParent build/Windflow.saver "build/Windflow-$VERSION.saver.zip"
```

Use `ditto`, not `zip`: it preserves the bundle's resource forks and the ad-hoc
signature. Verify what you are about to ship:

```sh
codesign --verify --verbose build/Windflow.saver
```

An ad-hoc signature is enough for a build the owner installs. Anything downloaded
from the internet will be quarantined and needs a Developer ID signature and
notarisation — which this project does not currently set up.

## Bump the version

`CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
Tag the release commit `v<version>`.
