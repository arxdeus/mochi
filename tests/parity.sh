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
    agent.task.structured_output)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            --test task_policy structured_happy_path_returns_validated_json -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            --test task_policy invalid_then_valid_recovers_within_one_prompt -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            --test task_policy no_summary_nudges_then_recovers -- --exact >/dev/null
        run_mojo_test tests/runtime_test.mojo
        ;;
    ui.command.catalog)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::slash_shows_builtins_plus_extras -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::filter_by_substring::compact_substring -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::confirm_parses_args::btw_multi_word -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::confirm_parses_args::fuzzy-match-2 -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::confirm_parses_args::case_insensitive -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::slash_noncommand_sends_as_prompt -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::sync_respects_nargs -- --nocapture >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::sync_filters_on_first_word_only -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::navigation_wraps -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::sync_clamps_selected -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.command.request_modes)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            types::tests::thinking_parse -- --nocapture >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::thinking_toggle_cycles_off_adaptive -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::fast_toggle_on_off_on_opus -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::workflow_toggle_flows_into_agent_input -- --exact >/dev/null
        run_mojo_test tests/provider_contract_test.mojo
        run_mojo_test tests/runtime_test.mojo
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
    ui.picker.filter_navigation)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::list_picker::tests::search_filters_progressively -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::list_picker::tests::fuzzy_search_with_nucleo_matcher -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::list_picker::tests::navigation_wraps_around -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::list_picker::tests::page_down_advances_and_clamps -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::list_picker::tests::enter_on_empty_results_consumed -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.mouse.selection)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            selection::tests::selection_start_doc_row -- --nocapture >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::mouse_drag_updates_selection -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::mouse_drag_clamps_to_area -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::mouse_up_clears_edge_scroll -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::empty_click_clears_selection -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            selection::tests::zone_at_overlay_wins_over_messages -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.overlay.modal_gating)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::overlay_zone_click_gating -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::help_modal_consumes_keys_and_esc_closes -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::ctrl_c_closes_overlay_instead_of_quitting -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.search.escape_restore)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::search_escape_restores_scroll::restores_scroll_position -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::search_escape_restores_scroll::restores_auto_scroll -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.search.navigation)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::navigation_wraps_around -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::enter_selects_current_match -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::enter_on_no_matches_closes -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    ui.search.display)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::matching_finds_correct_segments -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::matches_sorted_by_score_descending -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::display_line_picks_matched_line::match_on_middle_line -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::search_role_prefix_matches::maki_prefix -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::search_modal::tests::search_role_prefix_matches::you_prefix -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    mcp.oauth.discovery_pkce)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            mcp::oauth::discovery::tests::server_origin_extracts_origin -- --nocapture >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            mcp::oauth::discovery::tests::resource_metadata_url_candidates -- --nocapture >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            mcp::oauth::pkce::tests::rfc7636_verifier_length_and_uniqueness -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            auth::tests::mcp_auth_round_trip -- --exact >/dev/null
        run_mojo_test tests/mcp_test.mojo
        run_mojo_test tests/storage_test.mojo
        ;;
    ops.version.newer)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            version::tests::is_newer_cases::_garbage_latest_expects -- --exact >/dev/null
        run_mojo_test tests/ops_test.mojo
        ;;
    all)
        mismatches=0
        failed=""
        behaviors="permissions.deny_precedence permissions.session_generalization storage.session.v2.truncated_tail storage.session.latest_cwd provider.openai.chat.streaming provider.anthropic.messages.streaming provider.google.generate.streaming provider.model.catalog_metadata agent.task.structured_output ui.command.catalog ui.command.request_modes ui.input.history ui.input.word_aware_paste ui.picker.filter_navigation ui.mouse.selection ui.overlay.modal_gating ui.search.escape_restore ui.search.navigation ui.search.display mcp.oauth.discovery_pkce ops.version.newer"
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
