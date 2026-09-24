# Ronintech Homebrew tap

```bash
brew tap ronintech-ai/homebrew-tap
brew trust ronintech-ai/tap
brew install boyd
boyd github
boyd onboard
```

Homebrew names this tap `ronintech-ai/tap` (from the `homebrew-tap` repo name). First install on a machine may require `brew trust ronintech-ai/tap`.

CLI scripts are vendored under `boyd-cli/<version>/` from [boyd-infra](https://github.com/ronintech-ai/boyd-infra) tags (`packaging/VERSION`).
