# AppIcon.iconset

This directory holds the source PNGs that `iconutil` compiles into
`Gargantua.app/Contents/Resources/AppIcon.icns` during `Scripts/release.sh`.

## Expected contents (Apple-standard iconset layout)

```
icon_16x16.png          icon_16x16@2x.png   (32 px)
icon_32x32.png          icon_32x32@2x.png   (64 px)
icon_128x128.png        icon_128x128@2x.png (256 px)
icon_256x256.png        icon_256x256@2x.png (512 px)
icon_512x512.png        icon_512x512@2x.png (1024 px)
```

## Placeholder behavior

If this directory is empty (or missing some sizes), `assemble-app.sh` will
synthesize a solid-color placeholder at build time and emit a loud warning:

```
warn: AppShell/AppIcon.iconset is empty; generating placeholder icon.
warn: Ship real artwork before public release.
```

## Replacing the placeholder

Drop the ten PNGs listed above into this directory and commit. `iconutil`
will pick them up automatically on the next `./Scripts/release.sh` run.
