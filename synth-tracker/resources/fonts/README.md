# Bundled fonts (development directory)

At startup, SynthTracker registers every `.ttf` / `.otf` / `.ttc` file in this directory with CoreText at
**process scope**. Nothing is installed system-wide. Registered families resolve before installed copies of the
same family (Phase 8.5, `CoreTextRasterizer.registerBundledFonts`). In the app bundle, the same code reads
`SynthTracker.app/Contents/Resources/Fonts`.

The directory is intentionally empty until Phase 9.1. That phase vendors these files together with their
SIL OFL 1.1 license texts and a provenance note:

- `AtkinsonHyperlegibleNext-VariableFont_wght.ttf` (+ Italic): UI font, "Atkinson Hyperlegible Next"
- `FiraCode-VariableFont_wght.ttf`: monospace font, "Fira Code" v5.002

Until then, development builds use the per-user installed copies in `~/Library/Fonts`. Both fonts are
variable; the app pins the `wght` axis to 400 (Regular), because Fira Code's default instance is lighter
(measured at wght 331).
