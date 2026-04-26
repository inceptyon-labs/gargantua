# AppIcon.iconset

This directory holds the source PNGs that `iconutil` compiles into
`Gargantua.app/Contents/Resources/AppIcon.icns` during `Scripts/release.sh`.
The current artwork is generated from `AppShell/Brand/gargantua-logo-1024.png`.

## Expected contents (Apple-standard iconset layout)

```text
icon_16x16.png          icon_16x16@2x.png   (32 px)
icon_32x32.png          icon_32x32@2x.png   (64 px)
icon_128x128.png        icon_128x128@2x.png (256 px)
icon_256x256.png        icon_256x256@2x.png (512 px)
icon_512x512.png        icon_512x512@2x.png (1024 px)
```

## Regenerating

Regenerate the ten PNGs from the source art with ImageMagick:

```sh
magick AppShell/Brand/gargantua-logo-source.png -resize 1024x1024^ -gravity center -extent 1024x1024 AppShell/Brand/gargantua-logo-1024.png
```

Then resize that 1024px master to the Apple-standard filenames above.
