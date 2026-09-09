# IBM Plex fonts

Unmodified WOFF2 files from [IBM's Plex repository](https://github.com/IBM/plex),
retrieved 2026-09-09. Copyright IBM Corp.; distributed under the accompanying
[SIL Open Font License](LICENSE.txt).

- `packages/plex-sans/fonts/complete/woff2/IBMPlexSans-Regular.woff2`
- `packages/plex-sans/fonts/complete/woff2/IBMPlexSans-Medium.woff2`
- `packages/plex-sans/fonts/complete/woff2/IBMPlexSans-SemiBold.woff2`
- `packages/plex-mono/fonts/complete/woff2/IBMPlexMono-Regular.woff2`

The app embeds these files at compile time and serves only these allowlisted
names under `/assets/fonts/`. `public/theme.css` declares the shared font faces;
no runtime font CDN is used. Scripts and glyphs outside these fonts' coverage
use the device's system font fallback, preserving the original source text.
