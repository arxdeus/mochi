#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
upstream="$root/.slim/clonedeps/repos/tontinton__maki"
expected=4296034c0ec1a6cbf0b2474585011006c225df98

[ "$(git -C "$upstream" rev-parse HEAD)" = "$expected" ] || {
    echo "pinned upstream revision mismatch" >&2
    exit 1
}

run_mojo_test() {
    test_file=$1
    obj="${TMPDIR:-/tmp}/mochi-parity-cancellation-$$.o"
    bin="${TMPDIR:-/tmp}/mochi-parity-test-$$"
    trap 'rm -f "$obj" "$bin"' EXIT INT TERM
    cc -std=c11 -O2 -c "$root/src/mochi/cancellation.c" -o "$obj"
    ext=so
    [ "$(uname -s)" = Darwin ] && ext=dylib
    mojo build -I "$root/src" -Xlinker "$obj" \
        -D CURL_LIB_PATH="$CONDA_PREFIX/lib/libcurl.$ext" \
        -D CURL_WRAPPER_LIB_PATH="$CONDA_PREFIX/lib/libcurl_wrapper.$ext" \
        "$root/$test_file" -o "$bin"
    "$bin" >/dev/null
    rm -f "$obj" "$bin"
    trap - EXIT INT TERM
}

case "${1:-all}" in
    permissions.deny_precedence)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            permissions::tests::yolo_mode_allows_but_deny_still_blocks -- --exact >/dev/null
        run_mojo_test tests/permissions_test.mojo
        ;;
    storage.session.v2.truncated_tail)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            sessions::tests::crash_recovery_truncated_line -- --exact >/dev/null
        run_mojo_test tests/session_test.mojo
        ;;
    provider.openai.chat.streaming)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::openai_compat::tests::parse_sse_text_and_usage -- --exact >/dev/null
        run_mojo_test tests/provider_test.mojo
        ;;
    all)
        mismatches=0
        failed=""
        for behavior in permissions.deny_precedence storage.session.v2.truncated_tail provider.openai.chat.streaming; do
            if ! sh "$0" "$behavior"; then
                mismatches=$((mismatches + 1))
                if [ -n "$failed" ]; then
                    failed="$failed,"
                fi
                failed="$failed\"$behavior\""
            fi
        done
        if [ "$mismatches" -eq 0 ]; then
            printf '%s\n' '{"status":"parity","behaviors":3,"mismatches":0,"failed":[]}'
        else
            printf '{"status":"mismatch","behaviors":3,"mismatches":%s,"failed":[%s]}\n' "$mismatches" "$failed"
            exit 1
        fi
        ;;
    *)
        echo "unknown parity behavior: $1" >&2
        exit 2
        ;;
esac
