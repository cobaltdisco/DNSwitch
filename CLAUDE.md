# DNSwitch

To release DNSwitch, run `/dnswitch-release-qa`. On GO it continues on its own:
`packaging/release.sh` (notarize) → release notes → `packaging/publish.sh`
(push, tag, GitHub Release). On NO-GO nothing is released.

`packaging/release.sh` enforces the QA gate: it does not build, and it only
notarizes the release candidate that a GO QA report for the current commit
tested. `packaging/publish.sh` only uploads the zip release.sh made for HEAD.
