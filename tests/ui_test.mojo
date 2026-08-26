from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.ui import (
    UiAction,
    UiEvent,
    UiReducer,
    UiState,
    ui_transcript_line,
    command_matches,
    command_names,
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


def test_command_catalog_and_fuzzy_matches() raises:
    var names = command_names()
    assert_true("compact" in names)
    assert_true("usage" in names)
    var prefix = command_matches("/co")
    assert_equal(prefix[0], "compact")
    var fuzzy = command_matches("pct")
    assert_equal(fuzzy[0], "compact")
    assert_equal(len(command_matches("not-a-command")), 0)


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
