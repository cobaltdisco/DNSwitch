# DNSwitch

Before any DNSwitch release, run `/dnswitch-release-qa` and get GO; only then run `packaging/release.sh`.

`packaging/release.sh` enforces this: it does not build, and it only notarizes
the release candidate that a GO QA report for the current commit tested.
