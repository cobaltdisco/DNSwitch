#!/bin/bash
# Regenerate THIRD-PARTY-LICENSES from the modules ACTUALLY linked into the engine.
#
# Not the go.mod require list and not `go list -m all`: both over-report (test-only
# and pruned-away modules) and the resulting file would claim we ship code we don't.
# `go version -m <binary>` reports what the linker really put in, so this stays
# honest — and shrinks by itself when a dependency is dropped.
#
# Run after changing dependencies, and commit the result.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/THIRD-PARTY-LICENSES"
TMPBIN="$(mktemp -t dnswitch-lic)"
trap 'rm -f "$TMPBIN"' EXIT

export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$PATH"
cd "$REPO/engine"

echo "building engine to enumerate linked modules…"
go build -o "$TMPBIN" .

mods="$(go version -m "$TMPBIN" | awk '$1=="dep"{print $2}')"
[ -n "$mods" ] || { echo "error: no linked modules reported" >&2; exit 1; }

{
	cat <<'HEADER'
Third-party licenses
====================

DNSwitch statically links the Go modules below into its engine daemon
(DNSwitch.app/Contents/MacOS/dnswitch-engine). All are used unmodified, as Go
module dependencies. Each license is reproduced in full, as those licenses
require for binary redistribution.

Regenerate with packaging/gen-third-party-licenses.sh (enumerates what the
linker actually embedded, not what go.mod merely mentions).

HEADER

	# Index first, so the list is readable without scrolling 2000 lines.
	echo "Components"
	echo "----------"
	echo
	while IFS='|' read -r path ver dir; do
		printf '  %-42s %s\n' "$path" "$ver"
	done < <(go list -m -f '{{.Path}}|{{.Version}}|{{.Dir}}' $mods)
	echo

	while IFS='|' read -r path ver dir; do
		lic=""
		for cand in LICENSE LICENSE.txt LICENSE.md LICENCE COPYING; do
			if [ -f "$dir/$cand" ]; then lic="$dir/$cand"; break; fi
		done
		echo "================================================================================"
		echo
		echo "$path"
		echo "Version: $ver"
		echo "https://$path"
		echo
		if [ -z "$lic" ]; then
			# Loud on purpose: an unlicensed dependency is a publication blocker,
			# not something to paper over with a blank section.
			echo "*** NO LICENSE FILE FOUND IN THIS MODULE — RESOLVE BEFORE DISTRIBUTING ***"
			echo
			echo "warning: no license file for $path" >&2
		else
			cat "$lic"
		fi
		echo
	done < <(go list -m -f '{{.Path}}|{{.Version}}|{{.Dir}}' $mods)
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines, $(echo "$mods" | wc -l | tr -d ' ') components)"
