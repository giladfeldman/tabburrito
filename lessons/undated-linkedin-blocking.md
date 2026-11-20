## LinkedIn Blocking

- LinkedIn blocking in Firefox Lite uses the isolated profile/uBlock-oriented approach.
- Blocking should default to LinkedIn only unless a user explicitly enables it elsewhere.
- LinkedIn periodically ships an obfuscated-class feed redesign (hashed names like `._297bc8a0`, posts wrapped in `div[componentkey][role="listitem"]`). NEVER anchor the blocker on those hashed class names — they change. Anchor only on stable semantic attributes: `componentkey*="FeedType"` (one per post), `[role="listitem"]`, and legacy `urn:li:activity` ids.
- The blocker must be blast-radius-bounded so a single bad match can never blank the whole feed: resolve each marker to the *nearest single post* (never climb to a multi-post ancestor; refuse a candidate wrapping ≥2 posts), and apply a circuit breaker that stops hiding once >60% of loaded posts are gone. A 2026-06-18 regression hid the entire feed because the fallback climb resolved markers to a container spanning the whole stream.
- WebView2 cannot run full uBlock Origin (Chromium MV2 deprecation) — only uBO Lite (MV3), and extension loading isn't wired through wry/Tauri. "Real uBlock with max filters" belongs in the Firefox Lite variant, not WebView2.
