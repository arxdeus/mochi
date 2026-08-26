from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.types import Message, ToolCall
from mochi.ui import (
    UiAction,
    UiEvent,
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
    _ = UiReducer.reduce(state, UiEvent.edit("/model  fast "))
    var parsed = UiReducer.reduce(state, UiEvent.submit())
    assert_true(parsed.is_command())
    assert_equal(parsed.name, "model")
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
