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

# The Go standard library and runtime are NOT a module, so `go version -m` is
# structurally blind to them — yet ~180 stdlib packages and the entire runtime are
# linked into this binary, making it the single largest third-party component
# here. Go's own license is BSD-3-Clause, carrying the same binary-redistribution
# notice obligation as every module above. Handled separately for that reason.
#
# GOROOT/LICENSE on a stock toolchain; Homebrew points GOROOT at .../libexec and
# keeps the license one level up at the Cellar root.
goversion="$(go version | awk '{print $3}')"
GOROOT="$(go env GOROOT)"
GO_LICENSE=""
GO_PATENTS=""
for cand in "$GOROOT/LICENSE" "$GOROOT/../LICENSE"; do
	if [ -f "$cand" ]; then GO_LICENSE="$cand"; break; fi
done
for cand in "$GOROOT/PATENTS" "$GOROOT/../PATENTS"; do
	if [ -f "$cand" ]; then GO_PATENTS="$cand"; break; fi
done
[ -n "$GO_LICENSE" ] || { echo "error: cannot find the Go LICENSE under $GOROOT" >&2; exit 1; }

{
	cat <<'HEADER'
Third-party licenses
====================

DNSwitch statically links the components below into its engine daemon
(DNSwitch.app/Contents/MacOS/dnswitch-engine): Go module dependencies, all used
unmodified, plus the Go standard library and runtime. Each license is reproduced
in full, as those licenses require for binary redistribution. Where a component
also ships an additional patent grant (PATENTS), that is included too.

Regenerate with packaging/gen-third-party-licenses.sh (enumerates what the
linker actually embedded, not what go.mod merely mentions).

The DNSwitch app itself links nothing third-party: it has no Contents/Frameworks
and declares no package dependencies, and its Swift runtime is provided by macOS.

HEADER

	# Index first, so the list is readable without scrolling 2000 lines.
	echo "Components"
	echo "----------"
	echo
	while IFS='|' read -r path ver dir; do
		printf '  %-42s %s\n' "$path" "$ver"
	done < <(go list -m -f '{{.Path}}|{{.Version}}|{{.Dir}}' $mods)
	printf '  %-42s %s\n' "The Go standard library and runtime" "$goversion"
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
		# Not required by BSD-3-Clause, but these are additional patent grants in
		# the redistributor's favour — free to carry, and the modules ship them
		# right alongside the license precisely so they travel together.
		if [ -f "$dir/PATENTS" ]; then
			echo
			echo "--- Additional IP grant ($path/PATENTS) ---"
			echo
			cat "$dir/PATENTS"
		fi
		echo
	done < <(go list -m -f '{{.Path}}|{{.Version}}|{{.Dir}}' $mods)

	echo "================================================================================"
	echo
	echo "The Go Programming Language (standard library and runtime)"
	echo "Version: $goversion"
	echo "https://go.dev"
	echo
	echo "Statically linked into the engine daemon by the Go toolchain."
	echo
	cat "$GO_LICENSE"
	if [ -n "$GO_PATENTS" ]; then
		echo
		echo "--- Additional IP grant (Go PATENTS) ---"
		echo
		cat "$GO_PATENTS"
	fi
	echo
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines, $(( $(echo "$mods" | wc -l) + 1 )) components)"
