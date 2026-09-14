# Public release runbook

Voltscope has two public release channels:

- Official download: `https://voltscope.dimp.studio/Voltscope.dmg`
- GitHub Release: `https://github.com/dimpurr/voltscope/releases`

The two channels must contain the same version and DMG checksum. Signing
identities, notarization credentials, Sparkle private keys, and deployment
credentials stay in the maintainer's Keychain, SSH configuration, or CI secrets.

## Cut a release

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Sources/Voltscope/Resources/Info.plist`. For v0.9.0 this is `0.9.0` / `9`.
   Set `SUPublicEDKey` to the public half of the maintainer's Sparkle EdDSA
   key. The private half stays in Keychain account `voltscope`.
2. Update the top `CHANGELOG.md` entry, `README.md`, and any current spec that
   changed.
3. Run the tests, then build a universal2 app and notarized DMG with
   `./scripts/build-dmg.sh --release --universal`. The script builds both
   slices, signs the app and DMG, submits the DMG to Apple, staples the ticket,
   and validates the result.
4. Generate and statically validate the signed appcast from that exact final
   DMG:

   ```bash
   ./scripts/build-appcast.sh --dmg build/Voltscope-0.9.0-universal2.dmg \
     --version 0.9.0 --build 9 --tag v0.9.0
   ```

   This reads the EdDSA private key from Keychain, writes `build/appcast.xml`,
   and points the enclosure at the exact GitHub Release asset. Add `--network`
   only after the asset is public to verify reachability and length.
5. Verify the app contains both `arm64` and `x86_64` slices with `lipo`, then
   verify the Developer ID signature, stapled notarization ticket, DMG, and
   checksum. The website DMG and GitHub Release asset must be the same bytes.
6. Build and deploy the website, then verify the live DMG's HTTP status and
   SHA-256 against the local artifact.
7. Create an annotated SemVer tag and push the branch and tag.
8. Create a GitHub Release for that tag and attach the same DMG and
   `build/appcast.xml`, with the changelog and checksum.
9. Re-run the appcast verifier with `--network`. For the v0.9.0 migration,
   publish the same `appcast.xml` at the legacy GitHub Pages path
   `https://dimpurr.github.io/voltscope/appcast.xml`, then verify both the
   legacy URL and the new GitHub Release feed. This keeps installed v0.8.1
   builds updateable while v0.9.0 moves future checks to GitHub Releases.
10. Update the Homebrew tap cask to the final version and checksum, run its
   audit/style checks, and open a draft PR for review.
11. Install the exact artifact on a test Mac when the release requires local QA.

Never claim notarization unless `notarytool` accepted the artifact and the
ticket was stapled and validated. Never store release secrets in this repository.
