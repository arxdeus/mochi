#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
default_upstream="$root/.slim/clonedeps/repos/tontinton__maki"
upstream=${MAKI_UPSTREAM:-$default_upstream}
expected=f6847451b96dc9722c9ad4ba088e6af1e27b5c6a

print_oracle_setup() {
    requested_behavior=${1:-all}
    cat >&2 <<EOF
This harness requires a read-only Maki oracle at exactly:
  $expected

The configured path is:
  $upstream

Create a separate checkout (choose a new, empty destination) and retry:
  git clone --no-checkout https://github.com/tontinton/maki.git /path/to/maki-$expected
  git -C /path/to/maki-$expected checkout --detach $expected
  MAKI_UPSTREAM=/path/to/maki-$expected pixi run parity $requested_behavior

The harness never clones, fetches, checks out, resets, or otherwise modifies
the configured Maki checkout.
EOF
}

if ! actual=$(git -C "$upstream" rev-parse --verify HEAD 2>/dev/null); then
    echo "Maki oracle is absent or is not a Git checkout." >&2
    print_oracle_setup "${1:-all}"
    exit 1
fi

if [ "$actual" != "$expected" ]; then
    echo "Maki oracle revision mismatch: expected $expected, found $actual." >&2
    echo "Existing checkout left untouched." >&2
    print_oracle_setup "${1:-all}"
    exit 1
fi

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

run_plugin_e2e() {
    sh "$root/tests/plugin_e2e.sh"
}

case "${1:-all}" in
    config.layered.merge)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-config \
            tests::merge_overlay_wins_field_by_field -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-config \
            tests::permissions_merge_global_and_project -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-config \
            tests::merge_plugins_overlay_wins_per_key -- --exact >/dev/null
        run_mojo_test tests/config_test.mojo
        ;;
    storage.workspace.stores)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            input_history::tests::rejects_consecutive_duplicates -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            input_history::tests::truncates_to_max_entries -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            plans::tests::new_plan_path_under_plans_dir -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            theme::tests::theme_persistence_round_trip -- --exact >/dev/null
        run_mojo_test tests/workspace_test.mojo
        ;;
    ops.logging.telemetry)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-otel \
            pipeline::tests::shutdown_flushes_pending_events -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-otel \
            pipeline::tests::events_split_at_the_batch_size -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-otel \
            settings::tests::defaults_match_the_spec -- --exact >/dev/null
        run_mojo_test tests/ops_test.mojo
        ;;
    acp.v1.session.lifecycle)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-acp \
            server::tests::only_the_outstanding_request_id_is_answered -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-acp \
            server::tests::cancel_drops_the_outstanding_permission_request -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-acp \
            server::tests::load_history_round_trips_stored_messages -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-acp \
            translate::tests::replay_full_conversation_in_order -- --exact >/dev/null
        run_mojo_test tests/acp_test.mojo
        ;;
    agent.system_prompt.instructions)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            agent::instructions::tests::load_instructions_merges_project_and_local -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            agent::instructions::tests::load_instructions_includes_global_from_home -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            agent::instructions::tests::load_instructions_includes_parent_directory_instructions -- --exact >/dev/null
        run_mojo_test tests/prompt_test.mojo
        run_mojo_test tests/runtime_test.mojo
        ;;
    agent.provider_error.result)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::exit_on_done_flag_triggers_exit::error_exits_error -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            agent::streaming::tests::a_reported_api_error_leaves_the_provider_body_behind -- --exact >/dev/null
        run_mojo_test tests/runtime_test.mojo
        ;;
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
    provider.openai.contract_adapter)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::openai_compat::tests::convert_messages_structure -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::openai_compat::tests::convert_tools_structure -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::openai_compat::tests::parse_sse_multiple_parallel_tool_calls -- --exact >/dev/null
        run_mojo_test tests/provider_test.mojo
        run_mojo_test tests/provider_contract_test.mojo
        ;;
    provider.openai.chat.streaming)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            providers::openai_compat::tests::parse_sse_text_and_usage -- --exact >/dev/null
        run_mojo_test tests/provider_test.mojo
        ;;
    provider.openai.streamed_error_retry)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            sse_error_payload_status >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            parse_sse_error_event >/dev/null
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
    ui.terminal.sgr_mouse)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::mouse_drag_updates_selection -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::mouse_up_clears_edge_scroll -- --exact >/dev/null
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
    storage.session.resume_continue)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            sessions::tests::roundtrip_save_load -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            sessions::tests::latest_returns_most_recent_for_cwd -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            sessions::tests::roundtrip_jsonl_incremental -- --exact >/dev/null
        run_mojo_test tests/session_test.mojo
        run_mojo_test tests/cli_test.mojo
        run_mojo_test tests/runtime_test.mojo
        ;;
    cancellation.http.active)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            cancel::tests::race_interrupted_by_concurrent_cancel -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            cancel::tests::child_cancelled_by_parent -- --exact >/dev/null
        run_mojo_test tests/http_test.mojo
        ;;
    cancellation.process.active)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            runtime::tests::shutdown_flag_aborts_callback_even_with_fresh_scope -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            cancel::tests::cancel_map_cancel_all -- --exact >/dev/null
        run_mojo_test tests/plugin_test.mojo
        ;;
    contracts.extension.v1)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            loader::tests::begin_shutdown_rejects_later_loads_and_is_idempotent -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            --test plugin_host reload_replaces_commands -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            tools::registry::tests::replace_plugin_swaps_own_tools -- --exact >/dev/null
        run_mojo_test tests/extension_contract_test.mojo
        ;;
    contracts.ui.transcript.v1)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            app::tests::slash_noncommand_sends_as_prompt -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-ui \
            components::command::tests::navigation_wraps -- --exact >/dev/null
        run_mojo_test tests/ui_test.mojo
        ;;
    contracts.storage.codecs)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            id::tests::roundtrip_base58 -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            id::tests::ref_preserves_caller_string -- --nocapture >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-storage \
            auth::tests::mcp_auth_round_trip -- --exact >/dev/null
        run_mojo_test tests/storage_test.mojo
        ;;
    contracts.invocation.fake)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            tools::registry::tests::audience_names_round_trip -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            tools::registry::tests::definitions_excludes_wrong_audience -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            types::tests::tool_results_builds_message_with_tool_result_blocks -- --exact >/dev/null
        run_mojo_test tests/invocation_test.mojo
        ;;
    contracts.provider.fake)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            types::tests::request_options_clamped_fast_requires_model_support -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            agent::run::tests::turn_counting -- --nocapture >/dev/null
        run_mojo_test tests/provider_contract_test.mojo
        ;;
    contracts.domain.adt)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            types::tests::user_with_images_text_and_images -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            types::tests::message_kind_is_backward_compatible -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-providers \
            error::tests::timeout_is_retryable -- --exact >/dev/null
        run_mojo_test tests/domain_test.mojo
        ;;
    extension.executable.lifecycle)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            loader::tests::with_jit_off_loads_builtins_and_registers_tools -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            loader::tests::begin_shutdown_rejects_later_loads_and_is_idempotent -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            --test plugin_host register_echo_tool -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            --test plugin_host reload_replaces_commands -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-lua \
            --test plugin_host \
            incompatible_package_is_skipped_and_its_sibling_still_loads \
            -- --nocapture >/dev/null
        run_mojo_test tests/plugin_test.mojo
        run_mojo_test tests/plugin_sdk_test.mojo
        run_mojo_test tests/plugin_source_test.mojo
        run_plugin_e2e
        run_mojo_test tests/runtime_test.mojo
        ;;
    mcp.streamable_http.basic)
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            mcp::protocol::tests::request_skips_none_params -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            mcp::protocol::tests::tool_info_honours_input_schema_rename -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            mcp::protocol::tests::call_tool_result_honours_is_error_rename -- --exact >/dev/null
        cargo test --manifest-path "$upstream/Cargo.toml" -p maki-agent \
            mcp::http::tests::server_negotiated_protocol_version_echoed_after_initialize -- --exact >/dev/null
        run_mojo_test tests/mcp_test.mojo
        run_mojo_test tests/runtime_test.mojo
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
        # Each behavior below runs upstream and Mochi assertions independently.
        # There are currently no shared fixtures or direct output comparisons.
        mismatches=0
        failed=""
        behaviors="agent.provider_error.result agent.system_prompt.instructions acp.v1.session.lifecycle config.layered.merge storage.workspace.stores ops.logging.telemetry permissions.deny_precedence permissions.session_generalization storage.session.v2.truncated_tail storage.session.latest_cwd provider.openai.chat.streaming provider.openai.streamed_error_retry provider.openai.contract_adapter provider.anthropic.messages.streaming provider.google.generate.streaming provider.model.catalog_metadata agent.task.structured_output storage.session.resume_continue cancellation.http.active cancellation.process.active contracts.extension.v1 contracts.ui.transcript.v1 contracts.storage.codecs contracts.invocation.fake contracts.provider.fake contracts.domain.adt extension.executable.lifecycle mcp.streamable_http.basic ui.command.catalog ui.command.request_modes ui.input.history ui.input.word_aware_paste ui.picker.filter_navigation ui.mouse.selection ui.terminal.sgr_mouse ui.overlay.modal_gating ui.search.escape_restore ui.search.navigation ui.search.display mcp.oauth.discovery_pkce ops.version.newer"
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
            printf '{"status":"paired-tests-passed","method":"independent-test-suites","direct_comparisons":0,"behaviors":%s,"failures":0,"failed":[]}\n' "$count"
        else
            printf '{"status":"paired-tests-failed","method":"independent-test-suites","direct_comparisons":0,"behaviors":%s,"failures":%s,"failed":[%s]}\n' "$count" "$mismatches" "$failed"
            exit 1
        fi
        ;;
    *)
        echo "unknown parity behavior: $1" >&2
        exit 2
        ;;
esac
