# Tools

Browser tools for the owner. No data: nothing to back up.

## Access
- **Internet:** behind the Authentik gate, bound to the owner's user, for use in a browser. Each app is its own Authentik application (slugs `plant-uml`, `it-tools`) in the embedded outpost: [services/authentik](../authentik/README.md#put-a-sign-in-page-in-front-of-an-app) steps 1–2.
- **LAN and Tailscale:** no gate and no login. PlantUML's VS Code extension sends its own requests and can't sign in to Authentik (a browser sign-in doesn't carry over), so it only works from here (from the internet it fails with "HTTP 302 Found": the redirect to sign-in): on the laptop via Tailscale, and over Remote-SSH (the server resolves `uml.<domain>` to itself). Elsewhere, render locally (`plantuml.render`: `Local`, needs Java and Graphviz).
- Keep PlantUML off the public entrypoint without the gate: diagrams can make the server fetch URLs (`!include`, `!includeurl`) and read files, which would reach internal-only pages from the internet.

| Container | Address | Does |
|---|---|---|
| `plantuml` | `https://uml.<domain>` | PlantUML server: diagrams from text, editor on the front page. Images up to 10000 px (`PLANTUML_LIMIT_SIZE`) |
| `it-tools` | `https://ittools.<domain>` | IT-Tools: encoders, converters, generators. Runs in the browser; the container only serves the page |

## Notes
- Render on the LAN: `https://uml.<domain>/png/<encoded>` or `/svg/<encoded>` (the editor shows the encoded form). VS Code: `plantuml.render` `PlantUMLServer`, `plantuml.server` `https://uml.<domain>`.
- IT-Tools has had no release since 2024.10.22; Renovate will only offer the `nightly` tag, which stays unpinned and unused.
- The old `plantuml-server` container (unpinned `jetty` tag, port 8585) is left stopped until phase 4 step 6 removes it.
