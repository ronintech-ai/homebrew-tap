# Ronintech Homebrew tap

```bash
brew tap ronintech-ai/homebrew-tap
brew trust ronintech-ai/tap
brew install boyd
boyd github
boyd onboard
```

Homebrew names this tap `ronintech-ai/tap` (from the `homebrew-tap` repo name).

If `/opt/homebrew/bin/boyd` already points at a dev symlink: `brew link --overwrite boyd`.

CLI scripts are vendored under `boyd-cli/<version>/` from tagged [boyd-infra](https://github.com/ronintech-ai/boyd-infra) releases (`packaging/VERSION`).
