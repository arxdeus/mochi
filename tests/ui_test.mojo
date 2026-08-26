from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.types import Message, ToolCall
from mochi.ui import (
    DocPos,
    ScreenSelection,
    Selection,
    UiAction,
    UiEvent,
    UiRect,
    UiReducer,
    UiState,
    ui_transcript_line,
    command_completion,
    command_descriptions,
    command_help_lines,
    command_matches,
    command_max_args,
    is_builtin_command,
    command_names,
    transcript_messages,
    search_result_lines,
    validate_ui_transcript_line,
)


def test_submit_transition() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.edit("  explain this  "))
    var action = UiReducer.reduce(state, UiEvent.submit())
    assert_true(action.is_submit())
    assert_equal(action.text, "explain this")
    assert_equal(state.draft, "")
    assert_equal(state.cursor, 0)
    assert_true(state.busy)

    _ = UiReducer.reduce(state, UiEvent.complete())
    assert_false(state.busy)
    var blank = UiReducer.reduce(state, UiEvent.submit())
    assert_true(blank.is_none())


def test_cancel_transition() raises:
    var state = UiState()
    var idle = UiReducer.reduce(state, UiEvent.cancel())
    assert_true(idle.is_none())
    _ = UiReducer.reduce(state, UiEvent.edit("go"))
    _ = UiReducer.reduce(state, UiEvent.submit())
    var cancel = UiReducer.reduce(state, UiEvent.cancel())
    assert_true(cancel.is_cancel())
    assert_false(state.busy)


def test_command_transition() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.edit("/cd  fast "))
    var parsed = UiReducer.reduce(state, UiEvent.submit())
    assert_true(parsed.is_command())
    assert_equal(parsed.name, "cd")
    assert_equal(parsed.text, "fast")
    assert_false(state.busy)

    _ = UiReducer.reduce(state, UiEvent.edit("discarded"))
    var direct = UiReducer.reduce(state, UiEvent.command("help", "topics"))
    assert_true(direct.is_command())
    assert_equal(direct.name, "help")
    assert_equal(direct.text, "topics")
    assert_equal(state.draft, "")
    assert_equal(state.cursor, 0)

    _ = UiReducer.reduce(state, UiEvent.edit("/nonexistent arg"))
    var unknown = UiReducer.reduce(state, UiEvent.submit())
    assert_true(unknown.is_submit())
    assert_equal(unknown.text, "/nonexistent arg")

    var fuzzy_state = UiState()
    _ = UiReducer.reduce(fuzzy_state, UiEvent.edit("/pct"))
    var fuzzy_action = UiReducer.reduce(fuzzy_state, UiEvent.submit())
    assert_true(fuzzy_action.is_command())
    assert_equal(fuzzy_action.name, "compact")

    var case_state = UiState()
    _ = UiReducer.reduce(case_state, UiEvent.edit("/CD ~/foo"))
    var case_action = UiReducer.reduce(case_state, UiEvent.submit())
    assert_true(case_action.is_command())
    assert_equal(case_action.name, "cd")
    assert_equal(case_action.text, "~/foo")


def test_extension_command_routes_with_arguments() raises:
    var state = UiState()
    state.set_extension_commands(["hello"])
    _ = UiReducer.reduce(state, UiEvent.edit("/hello one two"))
    var action = UiReducer.reduce(state, UiEvent.submit())
    assert_true(action.is_command())
    assert_equal(action.name, "hello")
    assert_equal(action.text, "one two")


def test_toggleable_picker_navigation_and_actions() raises:
    var state = UiState()
    _ = UiReducer.reduce(
        state, UiEvent.picker_open("MCP Servers", "1:filesystem\n0:github")
    )
    assert_equal(state.picker_name, "MCP Servers")
    assert_equal(state.picker_items[0], "filesystem")
    assert_true(state.picker_enabled[0])
    assert_false(state.picker_enabled[1])
    _ = UiReducer.reduce(state, UiEvent.picker_previous())
    assert_equal(state.picker_selected, 1)
    _ = UiReducer.reduce(state, UiEvent.picker_filter("gth"))
    assert_equal(len(state.picker_filtered), 1)
    assert_equal(state.picker_selected, 1)
    _ = UiReducer.reduce(state, UiEvent.picker_backspace())
    _ = UiReducer.reduce(state, UiEvent.picker_backspace())
    _ = UiReducer.reduce(state, UiEvent.picker_backspace())
    assert_equal(len(state.picker_filtered), 2)
    var toggle = UiReducer.reduce(state, UiEvent.picker_toggle())
    assert_true(toggle.is_picker_toggle())
    assert_equal(toggle.name, "github")
    assert_equal(toggle.text, "on")
    var view = UiReducer.view(state)
    assert_equal(view.lines[len(view.lines) - 2], "  [x] filesystem")
    assert_equal(view.lines[len(view.lines) - 1], "> [x] github")
    _ = UiReducer.reduce(state, UiEvent.picker_close())
    assert_equal(state.picker_name, "")
    assert_equal(len(state.picker_items), 0)


def test_picker_filter_no_matches_and_page_navigation() raises:
    var state = UiState()
    var items = String("")
    for i in range(25):
        if items != "":
            items += "\n"
        items += "0:item-" + String(i)
    _ = UiReducer.reduce(state, UiEvent.picker_open("Items", items))
    _ = UiReducer.reduce(state, UiEvent.picker_page_next())
    assert_equal(state.picker_selected, 10)
    _ = UiReducer.reduce(state, UiEvent.picker_page_previous())
    assert_equal(state.picker_selected, 0)
    _ = UiReducer.reduce(state, UiEvent.picker_filter("zzz"))
    assert_equal(len(state.picker_filtered), 0)
    assert_true("No matches" in UiReducer.view(state).lines[1])


def test_doc_selection_projection_and_clamping() raises:
    var area = UiRect(5, 3, 40, 10)
    var selection = Selection(2, 0, area, Selection.MESSAGES, 0)
    assert_equal(selection.anchor.row, 0)
    assert_equal(selection.anchor.col, 5)
    selection.update(20, 80, 0)
    assert_equal(selection.cursor.row, 9)
    assert_equal(selection.cursor.col, 44)
    var screen = selection.to_screen()
    assert_true(screen)
    assert_equal(screen.value().start_row, 3)
    assert_equal(screen.value().start_col, 5)
    assert_equal(screen.value().end_row, 12)
    assert_equal(screen.value().end_col, 44)

    var scrolled = Selection(7, 3, UiRect(0, 2, 80, 20), Selection.MESSAGES, 50)
    scrolled.update(10, 5, 50)
    var projected = scrolled.to_screen(50).value().copy()
    assert_equal(projected.start_row, 7)
    assert_equal(projected.start_col, 3)
    assert_equal(projected.end_row, 10)
    assert_equal(projected.end_col, 5)
    assert_false(Selection(5, 5, area, Selection.MESSAGES).to_screen())


def test_mouse_selection_zones_drag_and_pending_copy() raises:
    var state = UiState()
    state.add_zone(UiRect(0, 0, 80, 20), Selection.MESSAGES)
    state.add_zone(UiRect(10, 5, 60, 10), Selection.OVERLAY)
    assert_equal(state.zone_at(7, 20).value().zone, Selection.OVERLAY)
    _ = UiReducer.reduce(state, UiEvent.mouse_down(2, 5))
    assert_true(state.selection)
    assert_equal(state.selection.value().zone, Selection.MESSAGES)
    _ = UiReducer.reduce(state, UiEvent.mouse_drag(10, 20))
    assert_equal(state.selection.value().normalized()[1].row, 10)
    assert_equal(state.selection.value().normalized()[1].col, 20)
    _ = UiReducer.reduce(state, UiEvent.mouse_up(10, 20))
    assert_true(state.selection_pending_copy)
    assert_equal(state.selection_edge_scroll, 0)

    _ = UiReducer.reduce(state, UiEvent.mouse_down(2, 5))
    _ = UiReducer.reduce(state, UiEvent.mouse_up(2, 5))
    assert_false(state.selection)
    _ = UiReducer.reduce(state, UiEvent.picker_open("Modal", "0:item"))
    _ = UiReducer.reduce(state, UiEvent.mouse_down(2, 5))
    assert_false(state.selection)
    _ = UiReducer.reduce(state, UiEvent.mouse_down(7, 20))
    assert_true(state.selection)
    assert_equal(state.selection.value().zone, Selection.OVERLAY)


def test_modal_overlay_consumes_input_and_closes() raises:
    var state = UiState()
    state.add_zone(UiRect(0, 0, 80, 15), Selection.MESSAGES)
    state.add_zone(UiRect(10, 3, 60, 10), Selection.OVERLAY)
    _ = UiReducer.reduce(state, UiEvent.edit("draft"))
    _ = UiReducer.reduce(state, UiEvent.overlay_open("Help"))
    assert_equal(state.overlay_name, "Help")
    assert_true(state.overlay_modal)
    _ = UiReducer.reduce(state, UiEvent.insert("blocked"))
    assert_equal(state.draft, "draft")
    _ = UiReducer.reduce(state, UiEvent.scroll(-1))
    assert_true(state.auto_scroll)
    _ = UiReducer.reduce(state, UiEvent.mouse_down(1, 5))
    assert_false(state.selection)
    _ = UiReducer.reduce(state, UiEvent.mouse_down(5, 20))
    assert_true(state.selection)
    assert_equal(state.selection.value().zone, Selection.OVERLAY)
    _ = UiReducer.reduce(state, UiEvent.overlay_close())
    assert_false(state.overlay_modal)
    assert_equal(state.overlay_name, "")


def test_mouse_edge_scroll_clamps_and_reverses() raises:
    var state = UiState()
    state.viewport_height = 5
    for i in range(20):
        state.messages.append("line " + String(i))
        state.roles.append("user")
    state.viewport_offset = 5
    state.add_zone(UiRect(0, 2, 80, 5), Selection.MESSAGES)
    _ = UiReducer.reduce(state, UiEvent.mouse_down(4, 10))
    _ = UiReducer.reduce(state, UiEvent.mouse_drag(1, 10))
    assert_equal(state.selection_edge_scroll, 1)
    assert_equal(state.viewport_offset, 4)
    _ = UiReducer.reduce(state, UiEvent.mouse_drag(7, 10))
    assert_equal(state.selection_edge_scroll, -1)
    assert_equal(state.viewport_offset, 5)
    _ = UiReducer.reduce(state, UiEvent.mouse_drag(4, 10))
    assert_equal(state.selection_edge_scroll, 0)


def test_command_catalog_and_fuzzy_matches() raises:
    var names = command_names()
    assert_equal(len(names), 18)
    assert_equal(names[0], "tasks")
    assert_equal(names[17], "reload")
    assert_true("compact" in names)
    assert_true("usage" in names)
    assert_true("workflow" in names)
    assert_true(is_builtin_command("/help"))
    assert_true(is_builtin_command("HELP"))
    assert_false(is_builtin_command("memory"))
    var prefix = command_matches("/co")
    assert_equal(prefix[0], "compact")
    var fuzzy = command_matches("/pct")
    assert_equal(fuzzy[0], "compact")
    assert_equal(len(command_matches("not-a-command")), 0)
    assert_equal(command_completion("/co"), "/compact ")
    assert_equal(command_completion("/not-a-command"), "/not-a-command")
    var palette = UiState()
    _ = UiReducer.reduce(palette, UiEvent.edit("/"))
    _ = UiReducer.reduce(palette, UiEvent.command_previous())
    assert_equal(palette.command_selected, 17)
    _ = UiReducer.reduce(palette, UiEvent.command_next())
    assert_equal(palette.command_selected, 0)
    _ = UiReducer.reduce(palette, UiEvent.command_next())
    assert_equal(command_completion(palette.draft, palette.command_selected), "/compact ")
    assert_equal(command_completion("/cd ~/foo", 0), "/cd ~/foo")
    var maximums = command_max_args()
    assert_equal(maximums[0], 0)
    assert_equal(maximums[10], 1)
    assert_true(maximums[11] > 1000)
    assert_equal(len(command_matches("/compact ")), 0)
    assert_equal(command_matches("/cd ")[0], "cd")
    assert_equal(command_matches("/cd ~/foo")[0], "cd")
    assert_equal(len(command_matches("/cd ~/foo ")), 0)
    assert_equal(command_matches("/btw hello world")[0], "btw")
    assert_equal(command_matches("/cd  ~/foo")[0], "cd")
    var descriptions = command_descriptions()
    assert_equal(len(descriptions), len(names))
    assert_equal(descriptions[0], "Browse and search tasks")
    var help = command_help_lines()
    assert_equal(help[0], "/tasks  Browse and search tasks")
    assert_equal(help[17], "/reload  Reload plugins and config")


def test_unicode_editor_cursor_insert_and_delete() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.edit("aéz"))
    assert_equal(state.cursor, 3)
    _ = UiReducer.reduce(state, UiEvent.move_cursor(-1))
    assert_equal(state.cursor, 2)
    _ = UiReducer.reduce(state, UiEvent.insert("!"))
    assert_equal(state.draft, "aé!z")
    assert_equal(state.cursor, 3)
    _ = UiReducer.reduce(state, UiEvent.delete_backward())
    assert_equal(state.draft, "aéz")
    assert_equal(state.cursor, 2)
    _ = UiReducer.reduce(state, UiEvent.move_cursor(-99))
    _ = UiReducer.reduce(state, UiEvent.delete_backward())
    assert_equal(state.draft, "aéz")
    _ = UiReducer.reduce(state, UiEvent.insert("λ"))
    assert_equal(state.draft, "λaéz")


def test_paste_adds_spaces_at_word_boundaries() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.edit("readfile"))
    _ = UiReducer.reduce(state, UiEvent.move_cursor(-4))
    _ = UiReducer.reduce(state, UiEvent.paste_spaced("/tmp/x"))
    assert_equal(state.draft, "read /tmp/x file")
    _ = UiReducer.reduce(state, UiEvent.edit("λx"))
    _ = UiReducer.reduce(state, UiEvent.paste_spaced("value"))
    assert_equal(state.draft, "λx value")


def test_multiline_continuation_replaces_backslash() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.edit("first\\"))
    _ = UiReducer.reduce(state, UiEvent.continue_line())
    assert_equal(state.draft, "first\n")
    _ = UiReducer.reduce(state, UiEvent.insert("second"))
    assert_equal(state.draft, "first\nsecond")
    assert_equal(state.cursor, 12)


def test_history_navigation_preserves_draft_and_bounds() raises:
    var state = UiState()
    state.set_history(["a", "b"])
    _ = UiReducer.reduce(state, UiEvent.edit("draft"))

    _ = UiReducer.reduce(state, UiEvent.history_up())
    assert_equal(state.draft, "b")
    _ = UiReducer.reduce(state, UiEvent.history_up())
    assert_equal(state.draft, "a")
    _ = UiReducer.reduce(state, UiEvent.history_up())
    assert_equal(state.draft, "a")

    _ = UiReducer.reduce(state, UiEvent.history_down())
    assert_equal(state.draft, "b")
    _ = UiReducer.reduce(state, UiEvent.history_down())
    assert_equal(state.draft, "draft")
    assert_equal(state.cursor, 5)
    _ = UiReducer.reduce(state, UiEvent.history_down())
    assert_equal(state.draft, "draft")


def test_submit_updates_history_without_consecutive_duplicates() raises:
    var state = UiState()
    state.set_history(["old"])
    _ = UiReducer.reduce(state, UiEvent.edit("new"))
    _ = UiReducer.reduce(state, UiEvent.submit())
    assert_equal(len(state.history), 2)
    assert_equal(state.history[1], "new")
    _ = UiReducer.reduce(state, UiEvent.edit("new"))
    _ = UiReducer.reduce(state, UiEvent.submit())
    assert_equal(len(state.history), 2)


def test_structured_transcript_messages() raises:
    var assistant = Message("assistant", "checking")
    assistant.add_tool_call(ToolCall("call-1", "bash", "{}"))
    var tool = Message("tool", "ok")
    tool.name = "bash"
    var lines = transcript_messages([Message("user", "run"), assistant^, tool^])
    assert_equal(lines[0], "user: run")
    assert_equal(lines[1], "assistant: checking")
    assert_equal(lines[2], "tool call: bash")
    assert_equal(lines[3], "tool result bash: ok")


def test_state_loads_structured_transcript_for_search() raises:
    var state = UiState()
    var assistant = Message("assistant", "checking")
    assistant.add_tool_call(ToolCall("call-1", "bash", "{}"))
    var tool = Message("tool", "ok")
    tool.name = "bash"
    state.set_transcript([Message("user", "run"), assistant^, tool^])
    assert_equal(len(state.messages), 4)
    assert_equal(state.roles[0], "user")
    assert_equal(state.messages[1], "checking")
    assert_equal(state.roles[2], "tool call")
    assert_equal(state.messages[2], "bash")
    assert_equal(state.roles[3], "tool result bash")


def test_viewport_is_bounded_and_tracks_messages() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.viewport(40, 2, 99, False))
    assert_equal(state.viewport_width, 40)
    assert_equal(state.viewport_height, 2)
    assert_equal(state.viewport_offset, 0)
    _ = UiReducer.reduce(state, UiEvent.message("user", "one"))
    _ = UiReducer.reduce(state, UiEvent.message("assistant", "two"))
    _ = UiReducer.reduce(state, UiEvent.message("user", "three"))
    assert_equal(state.viewport_offset, 0)

    _ = UiReducer.reduce(state, UiEvent.viewport(0, 0, 99, False))
    assert_equal(state.viewport_width, 1)
    assert_equal(state.viewport_height, 1)
    assert_equal(state.viewport_offset, 2)
    _ = UiReducer.reduce(state, UiEvent.viewport(10, 2, 0, True))
    assert_equal(state.viewport_offset, 1)
    _ = UiReducer.reduce(state, UiEvent.message("assistant", "four"))
    assert_equal(state.viewport_offset, 2)
    _ = UiReducer.reduce(state, UiEvent.scroll(-1))
    assert_equal(state.viewport_offset, 1)
    assert_false(state.auto_scroll)
    _ = UiReducer.reduce(state, UiEvent.scroll_bottom())
    assert_equal(state.viewport_offset, 2)
    assert_true(state.auto_scroll)


def test_search_escape_restores_scroll_state() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.viewport(20, 1, 0, False))
    _ = UiReducer.reduce(state, UiEvent.message("user", "alpha"))
    _ = UiReducer.reduce(state, UiEvent.message("assistant", "beta"))
    _ = UiReducer.reduce(state, UiEvent.message("user", "gamma"))
    _ = UiReducer.reduce(state, UiEvent.viewport(20, 1, 1, False))
    _ = UiReducer.reduce(state, UiEvent.search_open())
    _ = UiReducer.reduce(state, UiEvent.search_query("gamma"))
    assert_true(state.search_open)
    assert_equal(state.viewport_offset, 2)
    assert_false(state.auto_scroll)
    _ = UiReducer.reduce(state, UiEvent.search_close())
    assert_false(state.search_open)
    assert_equal(state.viewport_offset, 1)
    assert_false(state.auto_scroll)

    _ = UiReducer.reduce(state, UiEvent.viewport(20, 1, 0, True))
    assert_equal(state.viewport_offset, 2)
    _ = UiReducer.reduce(state, UiEvent.search_open())
    _ = UiReducer.reduce(state, UiEvent.search_query("alpha"))
    assert_equal(state.viewport_offset, 0)
    _ = UiReducer.reduce(state, UiEvent.search_close())
    assert_true(state.auto_scroll)
    assert_equal(state.viewport_offset, 2)


def test_search_matches_are_sorted_by_score() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.message("user", "f---b"))
    _ = UiReducer.reduce(state, UiEvent.message("user", "fb"))
    _ = UiReducer.reduce(state, UiEvent.message("user", "foobar"))
    _ = UiReducer.reduce(state, UiEvent.search_open())
    _ = UiReducer.reduce(state, UiEvent.search_query("fb"))
    assert_equal(len(state.search_matches), 3)
    assert_equal(state.search_matches[0], 1)


def test_search_matches_role_prefix_and_matched_line() raises:
    var state = UiState()
    _ = UiReducer.reduce(
        state, UiEvent.message("user", "header\nsecond request")
    )
    _ = UiReducer.reduce(state, UiEvent.message("assistant", "response"))
    _ = UiReducer.reduce(state, UiEvent.search_open())
    _ = UiReducer.reduce(state, UiEvent.search_query("you>"))
    assert_equal(len(state.search_matches), 1)
    assert_equal(state.search_matches[0], 0)
    _ = UiReducer.reduce(state, UiEvent.search_query("second"))
    var lines = search_result_lines(state)
    assert_equal(len(lines), 1)
    assert_equal(lines[0], "> user: second request")


def test_search_enter_without_matches_restores_scroll() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.viewport(20, 1, 0, False))
    _ = UiReducer.reduce(state, UiEvent.message("user", "one"))
    _ = UiReducer.reduce(state, UiEvent.message("assistant", "two"))
    _ = UiReducer.reduce(state, UiEvent.viewport(20, 1, 0, False))
    _ = UiReducer.reduce(state, UiEvent.search_open())
    _ = UiReducer.reduce(state, UiEvent.search_query("missing"))
    _ = UiReducer.reduce(state, UiEvent.search_select())
    assert_false(state.search_open)
    assert_equal(state.viewport_offset, 0)
    assert_false(state.auto_scroll)


def test_search_navigation_wraps_and_select_keeps_match() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.viewport(20, 1, 0, False))
    _ = UiReducer.reduce(state, UiEvent.message("user", "alpha one"))
    _ = UiReducer.reduce(state, UiEvent.message("assistant", "other"))
    _ = UiReducer.reduce(state, UiEvent.message("user", "alpha two"))
    _ = UiReducer.reduce(state, UiEvent.search_open())
    _ = UiReducer.reduce(state, UiEvent.search_query("alpha"))
    assert_equal(len(state.search_matches), 2)
    assert_equal(state.viewport_offset, 0)
    _ = UiReducer.reduce(state, UiEvent.search_previous())
    assert_equal(state.search_selected, 1)
    assert_equal(state.viewport_offset, 2)
    _ = UiReducer.reduce(state, UiEvent.search_next())
    assert_equal(state.search_selected, 0)
    assert_equal(state.viewport_offset, 0)
    _ = UiReducer.reduce(state, UiEvent.search_previous())
    _ = UiReducer.reduce(state, UiEvent.search_select())
    assert_false(state.search_open)
    assert_equal(state.viewport_offset, 2)
    assert_false(state.auto_scroll)


def test_view_is_terminal_independent_snapshot() raises:
    var state = UiState()
    _ = UiReducer.reduce(state, UiEvent.viewport(30, 2, 0, False))
    _ = UiReducer.reduce(state, UiEvent.message("user", "one"))
    _ = UiReducer.reduce(state, UiEvent.message("assistant", "two"))
    _ = UiReducer.reduce(state, UiEvent.message("user", "three"))
    _ = UiReducer.reduce(state, UiEvent.viewport(30, 2, 1, False))
    _ = UiReducer.reduce(state, UiEvent.edit("next"))
    var view = UiReducer.view(state)
    assert_equal(len(view.lines), 2)
    assert_equal(view.lines[0], "assistant: two")
    assert_equal(view.lines[1], "user: three")
    assert_equal(view.draft, "next")
    assert_equal(view.width, 30)
    assert_equal(view.height, 2)
    assert_equal(view.offset, 1)
    assert_false(view.auto_scroll)


def test_golden_transcript_line() raises:
    var state = UiState()
    var event = UiEvent.edit("hello")
    var action = UiReducer.reduce(state, event)
    var line = ui_transcript_line(event, action, UiReducer.view(state))
    assert_equal(
        line,
        '{"version":1,"event":{"version":1,"tag":0,"text":"hello","name":"","role":"","width":0,"height":0,"offset":0,"auto_scroll":true},"action":{"version":1,"tag":0,"text":"","name":""},"view":{"version":1,"lines":[],"draft":"hello","busy":false,"width":80,"height":24,"offset":0,"auto_scroll":true}}',
    )
    validate_ui_transcript_line(line)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
