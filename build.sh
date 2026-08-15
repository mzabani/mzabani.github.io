#!/usr/bin/env bash
# Compiles bundle.typ into every page the site serves (index.html + posts/*.html)
# in a single Typst invocation, using the experimental HTML + bundle export
# targets. Requires typst >= 0.15.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

typst compile --features html,bundle -f bundle --pretty --root "$(pwd)" bundle.typ ./generated/
