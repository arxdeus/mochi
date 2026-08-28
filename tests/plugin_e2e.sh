#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_base=${TMPDIR:-/tmp}
dir=$(mktemp -d "$tmp_base/mochi-plugin-e2e.XXXXXX")
cleanup() {
    [ ! -d "$dir" ] || chmod -R u+rwX "$dir" 2>/dev/null || true
    rm -rf "$dir"
}
trap cleanup EXIT INT TERM

cc -std=c11 -O2 -c "$root/src/mochi/cancellation.c" \
    -o "$dir/cancellation.o"
mojo build -I "$root/src" -Xlinker "$dir/cancellation.o" \
    "$root/examples/hello_plugin.mojo" -o "$dir/hello-plugin"
mojo build -I "$root/src" -Xlinker "$dir/cancellation.o" \
    "$root/tests/plugin_sdk_e2e.mojo" -o "$dir/sdk-e2e"
mojo build -I "$root/src" -Xlinker "$dir/cancellation.o" \
    "$root/tests/plugin_source_e2e.mojo" -o "$dir/source-e2e"

"$dir/sdk-e2e" "$dir/hello-plugin"
"$dir/source-e2e" "$root/examples/hello_plugin.mojo" \
    "$dir/cache" "$(command -v mojo)" "$root/src"
