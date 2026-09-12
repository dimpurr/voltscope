# Contributing to Voltscope

Small, focused pull requests are welcome. Before changing a user-visible
behavior, read the owning document in `docs/INDEX.md` and describe the problem,
the chosen behavior, and the validation in the pull request.

For code changes, run:

```bash
git diff --check
swift test
```

For UI changes, also build the app and inspect Live, 1H, 24H, and 7D at wide
and narrow window sizes. Keep the shared History layout and the single toolbar
time selector intact unless the change explicitly updates the UI specification.

Please do not include credentials, private user data, or screenshots containing
personal information in issues or pull requests.
