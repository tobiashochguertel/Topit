# Fork notes — Topit Fork (`com.tobiashochgurtel.TopitFork`)

Upstream: <https://github.com/lihaoyun6/Topit> (AGPL-3.0). This fork stays AGPL-3.0; the
`LICENSE` file is unmodified and every addition in this repository is licensed under the same
terms as upstream.

## Why the identity change

Stock Topit and this fork must not share:

| Thing | Stock | Fork |
| --- | --- | --- |
| Bundle identifier | `com.lihaoyun6.Topit` | `com.tobiashochgurtel.TopitFork` |
| App / process name | `Topit` | `Topit Fork` |
| `UserDefaults` domain (all `@AppStorage` keys) | `com.lihaoyun6.Topit` | `com.tobiashochgurtel.TopitFork` |
| Sparkle appcast | upstream feed + key | none (updater inert) |

Sharing any of these means both apps fight over the same preferences and accessibility /
screen-recording grants, which makes side-by-side comparison impossible.

## Changes made on `chore/fork-identity`

- `Topit.xcodeproj/project.pbxproj`: `PRODUCT_BUNDLE_IDENTIFIER` → `com.tobiashochgurtel.TopitFork`,
  `PRODUCT_NAME` → `Topit Fork` (Debug + Release).
- `Topit/Info.plist`: `SUFeedURL` and `SUPublicEDKey` removed.
  Upstream's appcast is signed with upstream's Sparkle key, so leaving it in place would let
  Sparkle replace this fork with stock Topit on the next update check.
- `Topit/Supports/Sparkle.swift`: the `SPUStandardUpdaterController` now starts only when a
  `SUFeedURL` is present in the bundle. Sparkle stays compiled in and the "Check for Updates…"
  item shows up *disabled*; re-enabling it is an Info.plist change, not a code change.
- `Topit/ViewModel/WindowHighlighter.swift`: window filtering compared `kCGWindowOwnerName`
  against the hard-coded string `"Topit"`. It now compares against `Bundle.main.appName`, which
  follows the renamed product.
- `Topit/Supports/SCManager.swift`: `excludedApps` now also excludes `Bundle.main.bundleIdentifier`
  (upstream's own id is still excluded too, so the fork never tries to pin stock Topit either).

## Re-enabling Sparkle for the fork

```bash
# Sparkle 2 ships this helper in its release artifacts
./generate_keys                       # prints SUPublicEDKey + private key (keep the private key!)
```

Add both keys to `Topit/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>…generated public key…</string>
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/tobiashochgurtel/Topit/main/appcast.xml</string>
```

The updater starts automatically on the next launch once `SUFeedURL` exists.
