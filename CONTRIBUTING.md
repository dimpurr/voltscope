# Contributing to Voltscope

Small, focused pull requests are welcome. Before changing a user-visible
behavior, read the owning document in `docs/INDEX.md` and describe the problem,
the chosen behavior, and the validation in the pull request.

For code changes, run:

```bash
git diff --check
swift test
```

The CI workflow runs for pull requests and pushes to `main`. Its current
validation matrix is:

| Runner | Toolchain / architecture | Checks |
|---|---|---|
| `macos-26` | Latest stable Xcode on the arm64 runner image (currently Xcode 26.6) | Build and test with Swift type-check timing warnings; Swift 5 language compatibility mode |
| `macos-14` | Swift 6.1 | Documentation consistency, checker tests, and package tests in Swift 5 language compatibility mode |
| `macos-15-intel` | Swift 6.1 on Intel | Documentation consistency, checker tests, and package tests in Swift 5 language compatibility mode |

See [the CI workflow](.github/workflows/ci.yml) for the exact commands and
runner configuration.

For UI changes, also build the app and inspect every History range listed in
`docs/UI_SPEC.md` at wide and narrow window sizes. Keep the shared History layout
and the single toolbar time selector intact unless the change explicitly updates
the UI specification.

Please do not include credentials, private user data, or screenshots containing
personal information in issues or pull requests.
