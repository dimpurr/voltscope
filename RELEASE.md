# Public release runbook

Voltscope has two public release channels:

- Official download: `https://voltscope.dimp.studio/Voltscope.dmg`
- GitHub Release: `https://github.com/dimpurr/voltscope/releases`

The two channels must contain the same version and DMG checksum. Signing
identities, notarization credentials, Sparkle private keys, and deployment
credentials stay in the maintainer's Keychain, SSH configuration, or CI secrets.

## Release states and non-negotiable gate

Keep these states distinct:

| State | Meaning | Public update channel |
| --- | --- | --- |
| Development | The next version is being implemented on `main`. | Must not be described as public or latest. |
| Candidate | A signed/notarized artifact is being tested on a maintainer Mac. | May be unavailable; this is not release evidence. |
| Published | GitHub Release, `appcast.xml`, website DMG, and Homebrew metadata are live. | Must be reachable and verified. |

The exact release invariant is: an app artifact that contains a production
`SUFeedURL` must have a published, valid appcast at that URL. A locally valid
appcast is not enough; the GitHub Release must actually contain both
`appcast.xml` and the exact DMG referenced by its enclosure. A version does not
become public, and its changelog does not become a dated release entry, until
the final network gate below passes.

## Cut and publish a release

1. Prepare the candidate. Update `CFBundleShortVersionString` and increment
   `CFBundleVersion` in `Sources/Voltscope/Resources/Info.plist`. For v0.9.0
   this is `0.9.0` / `9`. Set `SUPublicEDKey` to the public half of the
   maintainer's Sparkle EdDSA key. The private half stays in Keychain account
   `voltscope`.

   Keep the changelog entry under `Unreleased` while the candidate is being
   tested. Update `README.md` and the current spec only for changes that are
   actually ready to ship.

2. Run the tests, then build a universal2 candidate and notarized DMG with
   `./scripts/build-dmg.sh --release --universal`. The script builds both
   slices, signs the app and DMG, submits the DMG to Apple, staples the ticket,
   and validates the result.

3. Generate and statically validate the signed appcast from that exact final
   DMG:

   ```bash
   ./scripts/build-appcast.sh --dmg build/Voltscope-0.9.0-universal2.dmg \
     --version 0.9.0 --build 9 --tag v0.9.0
   ```

   This reads the EdDSA private key from Keychain, writes `build/appcast.xml`,
   and points the enclosure at the exact GitHub Release asset. Static
   validation proves the XML and signature fields, not publication.

4. Verify the app contains both `arm64` and `x86_64` slices with `lipo`, then
   verify the Developer ID signature, stapled notarization ticket, DMG, and
   checksum. The website DMG and GitHub Release asset must be the same bytes.

5. Build and deploy the website, then verify the live DMG's HTTP status and
   SHA-256 against the local artifact.

6. Create an annotated SemVer tag and push the branch and tag. Create the
   GitHub Release for that tag and attach the same DMG and `build/appcast.xml`,
   with the changelog and checksum.

7. Run the mandatory post-publication gate. It checks that the release is not
   a draft, both assets exist, the live feed is valid, the Sparkle version and
   build match the app, the enclosure points to this release's DMG, and the
   byte length agrees with GitHub:

   ```bash
   python3 scripts/verify-release.py \
     --repo dimpurr/voltscope \
     --tag v0.9.0 --version 0.9.0 --build 9 \
     --feed-url https://github.com/dimpurr/voltscope/releases/latest/download/appcast.xml \
     --dmg-name Voltscope-0.9.0-universal2.dmg
   ```

   For the v0.9.0 migration, publish the same `appcast.xml` at the legacy
   GitHub Pages path `https://dimpurr.github.io/voltscope/appcast.xml` and
   verify that URL separately if supporting existing 0.8.1 clients. Do not
   call the release complete if either required feed is missing.

8. Only after the gate passes, move the changelog entry to a dated `0.9.0`
   section and update any public “latest” copy.

9. Update the Homebrew tap cask to the final version and checksum, run its
   audit/style checks, and open a draft PR for review.

10. Install the exact published artifact on a test Mac and verify the in-app
    update path. Candidate QA before publication is useful, but it cannot
    replace this step.

Never claim notarization unless `notarytool` accepted the artifact and the
ticket was stapled and validated. Never store release secrets in this repository.
