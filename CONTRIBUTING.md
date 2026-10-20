# Contributing to Rondo

Thanks for helping! Issues and pull requests in English or Russian are both fine.

## Bugs and ideas

- **Bug**: use the *Bug report* template. Please include your macOS version, Rondo version (menu → Settings) and the file type. If a conversion fails, the error text from the toast helps a lot.
- **Idea**: use the *Feature request* template. Tell us what you're trying to do, not just the button you want.

## Development

Requirements: Xcode 16+ (Swift 5.9+), macOS 13+.

```bash
swift build                                   # debug build
./scripts/build.sh 0.0.0                      # dist/Rondo.app + DMG
.build/debug/Rondo --self-test ./samples      # runs every operation on every file in ./samples
.build/debug/Rondo --self-test ./samples --office   # also Word/Excel/PowerPoint conversions
```

Where things live:

| File | What |
|---|---|
| `Sources/Rondo/Operations.swift` | The catalog: which operations appear for which file kind and wheel |
| `Sources/Rondo/Media.swift`, `Raw.swift`, `Extras.swift` | Image, PDF, OCR, speech, RAW, icons, palette… |
| `Sources/Rondo/Tools.swift` | ffmpeg / pandoc / Office automation |
| `Sources/Rondo/RadialMenu.swift`, `Watchers.swift` | The wheel, drag detection, hotkey |
| `Sources/Rondo/Editor.swift` | Trim & crop editor |
| `Sources/Rondo/Arena.swift` | Resolume Arena REST integration |

Adding an operation is usually a few lines in `Operations.swift`: add an `Operation` (or use the `single(...)` helper) to the right `convert` / `tools` / `actions` list, and the self-test picks it up.

## Pull requests

- Keep each PR focused on one thing.
- Run `--self-test` on a few real files before submitting.
- Never overwrite the user's original files; write results through `Paths.out(...)`.
- New strings go through `L("Русский", "English")`.
