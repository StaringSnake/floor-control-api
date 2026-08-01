# Bundled Swagger UI assets

These generated browser assets are from Swagger UI **5.11.10**, downloaded from
the source archive at:

`https://github.com/swagger-api/swagger-ui/archive/refs/tags/v5.11.10.tar.gz`

Archive SHA-256:

`a0da626eb6b6f2c8cd27d3367d0d067debd15fbfa231e9dc135bdc10815a1893`

Bundled file SHA-256:

- `swagger-ui-5.11.10-bundle.js`: `aebc65e339eb03b5f6fdc1cda2e4ac63282efa8aa3749a4482326894e065b152`
- `swagger-ui-5.11.10-standalone-preset.js`: `2f63f1a71ce7a6c7bd7b93000090138c11f6a95448adb0dd966f57e2dd5f0655`
- `swagger-ui-5.11.10.css`: `5ae746788ad6c2f19bb8c7638d63b5744e3efebaacb3bcabccdc928dbec6c4df`
- `Swagger-UI-LICENSE.txt`: `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`

The JavaScript and CSS files are the release `dist/` files. `Swagger-UI-LICENSE.txt`
is the corresponding upstream license notice and must remain with the assets.
The versioned filenames are intentional so a future asset update can coexist
with cached pages during rollout. To update, download the tagged source archive,
verify its checksum and license, replace the three versioned files and references
in `index.html`, record the new archive and file checksums here, and run the
Swagger endpoint tests plus the offline URL check. Do not replace these assets
with CDN URLs.
