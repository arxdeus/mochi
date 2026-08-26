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
    permissions.session_generalization)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            permissions::tests::allow_decision_generalizes -- --exact >/dev/null
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
    provider.anthropic.messages.streaming)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::anthropic::tests::parse_sse_text_and_usage -- --exact >/dev/null
        run_mojo_test tests/provider_test.mojo
        ;;
    provider.google.generate.streaming)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::google::tests::parse_sse_plain_text -- --exact >/dev/null
        run_mojo_test tests/provider_test.mojo
        ;;
    storage.session.latest_cwd)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            sessions::tests::latest_returns_most_recent_for_cwd -- --exact >/dev/null
        run_mojo_test tests/session_test.mojo
        ;;
    provider.model.catalog_metadata)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::openai::tests::gpt_5_6_models_have_expected_tier_and_short_context_pricing::_gpt_5_6_sol_modeltier_strong_5_0_0_5_6_25_30_0_expects -- --exact >/dev/null
        run_mojo_test tests/provider_test.mojo
        ;;
    ui.input.history)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::input::tests::history -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.input.word_aware_paste)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::input::tests::paste_with_spaces_empty_line -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.search.escape_restore)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::search_escape_restores_scroll::restores_scroll_position -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::search_escape_restores_scroll::restores_auto_scroll -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ops.version.newer)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            version::tests::is_newer_cases::_garbage_latest_expects -- --exact >/dev/null
        run_mojo_test tests/ops_test.mojo
        ;;
    all)
        mismatches=0
        failed=""
        behaviors="permissions.deny_precedence permissions.session_generalization storage.session.v2.truncated_tail storage.session.latest_cwd provider.openai.chat.streaming provider.anthropic.messages.streaming provider.google.generate.streaming provider.model.catalog_metadata ui.input.history ui.input.word_aware_paste ui.search.escape_restore ops.version.newer"
        count=0
        for behavior in $behaviors; do
            count=$((count + 1))
            if ! sh "$0" "$behavior"; then
                mismatches=$((mismatches + 1))
                if [ -n "$failed" ]; then
                    failed="$failed,"
                fi
                failed="$failed\"$behavior\""
            fi
        done
        if [ "$mismatches" -eq 0 ]; then
            printf '{"status":"parity","behaviors":%s,"mismatches":0,"failed":[]}\n' "$count"
        else
            printf '{"status":"mismatch","behaviors":%s,"mismatches":%s,"failed":[%s]}\n' "$count" "$mismatches" "$failed"
            exit 1
        fi
        ;;
    *)
        echo "unknown parity behavior: $1" >&2
        exit 2
        ;;
esac
