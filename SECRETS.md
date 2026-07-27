# SECRETS — where they live (never the values)

This file documents **where** each distribution secret is stored, so the release
lane (`scripts/release.sh`, phase A2) can find them. Per decision **5A**, nothing
secret is ever committed to this repo — this file records *locations only*, never
a certificate, password, key, or token. If you ever find a secret value written
here, that is a bug: remove it and rotate the credential.

The one non-secret in the mix is the Apple Developer **Team ID** (`L25247V6JG`),
which is public and lives in version control at
`AtelierRefs/Config/Release.xcconfig` and `AtelierRefs/Config/ExportOptions.plist`.

## Checklist — what the release machine must have provisioned

- [ ] **Developer ID Application certificate** — login Keychain.
  - Certificate + private key installed in the **login** keychain of the release
    user (downloaded from the Apple Developer portal, or exported from the Mac
    that created it as a `.p12` and imported — the `.p12` and its password are
    secrets and must NOT be committed).
  - Verify: `security find-identity -v -p codesigning` lists
    `Developer ID Application: … (L25247V6JG)`.
  - Used by: `xcodebuild -exportArchive` with `AtelierRefs/Config/ExportOptions.plist`
    (`signingCertificate = Developer ID Application`, `signingStyle = manual`).

- [ ] **Notarization credentials** — a Keychain profile named **`AtelierRefs-notary`**.
  - Create once with:
    `xcrun notarytool store-credentials AtelierRefs-notary`
    then supply the Apple ID / App-Store-Connect API key when prompted. The
    profile is stored by `notarytool` in the login Keychain; the App-Store-Connect
    API key (`.p8`), key ID, issuer ID, or app-specific password are secrets and
    must NOT be committed.
  - Verify: `xcrun notarytool history --keychain-profile AtelierRefs-notary`
    returns without an auth error.
  - Used by: `xcrun notarytool submit --keychain-profile AtelierRefs-notary --wait`
    in `scripts/release.sh` (phase A2).

- [ ] **Sparkle EdDSA private key** — login Keychain (phase **A3**, integrated).
  - Sparkle 2 is now an SPM dependency; its command-line tools are unpacked with
    the SPM artifacts under the project's DerivedData:
    `~/Library/Developer/Xcode/DerivedData/AtelierRefs-<hash>/SourcePackages/artifacts/sparkle/Sparkle/bin`
    (release.sh / verify-release.sh auto-discover this as `SPARKLE_BIN_DIR`).
  - Generate the keypair ONCE on the release machine:
    `"$SPARKLE_BIN_DIR/generate_keys"` — this stores the **private** EdDSA
    (ed25519) key in the **login Keychain** (a `Private key for signing Sparkle
    updates` item) and prints the **public** key.
  - Paste the printed public key into the app's Info.plist `SUPublicEDKey`
    (`AtelierRefs/Info.plist`), replacing the `REPLACE_WITH_PUBLIC_ED_KEY_FROM_generate_keys`
    placeholder. The public key is non-secret; the private key must NEVER be
    committed or exported into the repo.
  - The private key signs appcast updates via `generate_appcast` (release.sh) and
    `sign_update` (verify-release.sh); both read it from the Keychain by default.
  - Verify: `"$SPARKLE_BIN_DIR/generate_keys" -p` prints the public key,
    confirming the private key is present in the Keychain.
  - STILL BLOCKED ON A HUMAN: (1) run `generate_keys` and fill `SUPublicEDKey`;
    (2) decide the appcast/DMG hosting location and set the real `SUFeedURL` in
    Info.plist (currently a `https://REPLACE-ME.example.com/...` placeholder — see
    the 052 plan's "Open questions"). The always-on unit test only asserts the
    keys are present; `scripts/verify-release.sh` fails the *release* while either
    value is still the placeholder, by design (so pushes stay green).

## Manual staging-appcast update test (12A)

The one genuinely un-unit-testable step: confirming that Sparkle actually **finds,
downloads, and installs** an update end-to-end. The unit suite guards the config
keys; `verify-release.sh` guards the signed artifact + appcast; only a live run
proves the update *flow*. Do this once before the first public release and after
any change to the Sparkle wiring, hosting, or signing.

Procedure:

1. **Build two signed, notarized releases** with `scripts/release.sh` — a *lower*
   version (e.g. `MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=1`) and a *higher*
   one (e.g. `1.1` / `2`). Keep both DMGs and the generated `appcast.xml`.
2. **Stand up a staging feed.** Host the higher build's DMG + an `appcast.xml`
   whose `<enclosure url=…>` points at it, on any HTTPS location you control (a
   throwaway static bucket / GitHub Release works). The appcast must be the one
   `generate_appcast` produced, so it carries a real `sparkle:edSignature`.
3. **Point the app at staging.** Either temporarily set `SUFeedURL` to the staging
   appcast URL and rebuild the *lower* version, or launch it with a feed override
   (`defaults write sujenphea.AtelierRefs SUFeedURL <staging-url>`). Confirm
   `verify-release.sh <app> <dmg> <appcast>` passes on the staging artifacts first.
4. **Install + run the lower version**, then trigger **Check for Updates…** (the
   menu command under the app menu). Expect: Sparkle reports 1.1 available →
   downloads the DMG → the **sandboxed** Installer XPC service installs it (watch
   for `-spks`/`-spki` mach-lookup denials in Console if the entitlements are
   wrong) → the app relaunches as 1.1.
5. **Confirm the signature path** by tampering: serve the DMG but corrupt one byte,
   or swap in an appcast signed with a different key — Sparkle must REFUSE the
   update (proves `SUPublicEDKey` verification is live). Restore the good pair.
6. **Tear down** the staging feed and revert any `SUFeedURL`/`defaults` override.

If step 4 or 5 fails, the fault is in signing, the mach-lookup entitlements, or the
`SUPublicEDKey`/appcast pairing — none of which the automated guards can catch,
which is why this manual pass exists.

## Notes

- All three secrets live in the **login Keychain** of the release machine (the
  notary profile and Sparkle key are Keychain items; the Developer ID cert is a
  Keychain identity). Keep that keychain unlocked for the duration of a release
  run, or pass credentials explicitly to each tool.
- CI signing/notarization jobs need these same items provisioned on whichever
  runner executes the release lane (see the macOS-26 runner question in the plan's
  A4). Injecting them into CI is out of scope for phase A1.
