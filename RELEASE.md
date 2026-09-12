# Public release runbook

Voltscope has two public release channels:

- Official download: `https://voltscope.dimp.studio/Voltscope.dmg`
- GitHub Release: `https://github.com/dimpurr/voltscope/releases`

The two channels must contain the same version and DMG checksum. Signing
identities, notarization credentials, Sparkle private keys, and deployment
credentials stay in the maintainer's Keychain, SSH configuration, or CI secrets.

## Cut a release

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Sources/Voltscope/Resources/Info.plist`.
2. Update the top `CHANGELOG.md` entry, `README.md`, and any current spec that
   changed.
3. Run the tests, then build a universal2 app and notarized DMG with
   `./scripts/build-dmg.sh --release --universal`. The script builds both
   slices, signs the app and DMG, submits the DMG to Apple, staples the ticket,
   and validates the result.
4. Verify the app contains both `arm64` and `x86_64` slices with `lipo`, then
   verify the Developer ID signature, stapled notarization ticket, DMG, and
   checksum. The website DMG and GitHub Release asset must be the same bytes.
5. Build and deploy the website, then verify the live DMG's HTTP status and
   SHA-256 against the local artifact.
6. Create an annotated SemVer tag and push the branch and tag.
7. Create a GitHub Release for that tag and attach the same DMG, with the
   changelog and checksum.
8. Update the Homebrew tap cask to the final version and checksum, run its
   audit/style checks, and open a draft PR for review.
9. Install the exact artifact on a test Mac when the release requires local QA.

Never claim notarization unless `notarytool` accepted the artifact and the
ticket was stapled and validated. Never store release secrets in this repository.
