# Browser dependencies

`markdown-it-15.0.1.min.js` is the unmodified UMD browser bundle from
[markdown-it 15.0.1](https://www.npmjs.com/package/markdown-it/v/15.0.1), licensed
under the included MIT license. Upstream: https://github.com/markdown-it/markdown-it.

Source tarball: `https://registry.npmjs.org/markdown-it/-/markdown-it-15.0.1.tgz`.
The tarball was checked against the registry's SHA-512 integrity value before extraction.
Bundle SHA-256: `f9f377ca892291fbe32904e77a00c6e27e8f95c14f435a54c8cb6859b3d97692`.

The app serves this file locally; there is no runtime CDN dependency.
`chat-markdown.js` consumes parser tokens and creates DOM elements with a tag
allowlist. It does not insert rendered HTML. Raw HTML is text, URLs are validated,
and images are presented as links without automatically fetching remote content.
