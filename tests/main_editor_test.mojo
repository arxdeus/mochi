from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.main import (
    _TerminalEditorFrame,
    _editor_frame_sequence,
    _finish_editor_frame_sequence,
    _interactive_ui_state,
    _replace_interactive_session,
    _search_cursor_column,
    _terminal_clip,
    _terminal_input_rows,
)
from mochi.json import JsonValue
from mochi.permissions import PermissionManager
from mochi.plugin import (
    EVENT_SESSION_END,
    METHOD_LIFECYCLE,
    PluginClient,
    PluginRegistration,
    PluginTransport,
    RpcMessage,
    handshake_result,
    registration_result,
    session_end_result,
)
from mochi.provider import OpenAICompatibleProvider, ProviderSpec
from mochi.runtime import Runtime
from mochi.session import Session
from mochi.tools import ToolRegistry
from mochi.types import Message
from mochi.ui import UiEvent, UiReducer


def test_rows_match_cursor_layout_wrapping() raises:
    var exact = _terminal_input_rows("abcdefghij", 12)
    assert_equal(len(exact), 1)
    assert_equal(exact[0], "> abcdefghij")

    var wrapped = _terminal_input_rows("abcdefghijk", 12)
    assert_equal(len(wrapped), 2)
    assert_equal(wrapped[0], "> abcdefghij")
    assert_equal(wrapped[1], "k")

    var multiline = _terminal_input_rows("a\n漢b", 12)
    assert_equal(len(multiline), 2)
    assert_equal(multiline[0], "> a")
    assert_equal(multiline[1], "  漢b")

    # Maki wraps by scalar UnicodeWidthChar values even though its caret span
    # later collapses this complete ZWJ sequence to two cells.
    var emoji = _terminal_input_rows("👩‍💻x", 6)
    assert_equal(len(emoji), 2)
    assert_equal(emoji[0], "> 👩‍💻")
    assert_equal(emoji[1], "x")

    # Regional indicators are one scalar cell apiece in unicode-width.
    var flag = _terminal_input_rows("🇺🇸x", 4)
    assert_equal(len(flag), 2)
    assert_equal(flag[0], "> 🇺🇸")
    assert_equal(flag[1], "x")


def test_full_cursor_line_reserves_trailing_row_in_logical_order() raises:
    var single = _terminal_input_rows(
        "abcdefghij", 12, cursor=5, reserve_cursor_row=True
    )
    assert_equal(len(single), 2)
    assert_equal(single[0], "> abcdefghij")
    assert_equal(single[1], "")

    var multiline = _terminal_input_rows(
        "abcdefghij\nz", 12, cursor=5, reserve_cursor_row=True
    )
    assert_equal(len(multiline), 3)
    assert_equal(multiline[0], "> abcdefghij")
    assert_equal(multiline[1], "")
    assert_equal(multiline[2], "  z")


def test_editor_clip_uses_terminal_cells() raises:
    assert_equal(_terminal_clip("a漢b", 3), "a漢")
    assert_equal(_terminal_clip("éx", 2), "éx")
    assert_equal(_terminal_clip("⌚x", 2), "⌚")
    assert_equal(_terminal_clip("👩‍👩‍👧‍👦x", 2), "👩‍👩‍👧‍👦")


def test_search_cursor_is_visible_at_query_end() raises:
    assert_equal(_search_cursor_column("x", 80), 9)
    assert_equal(_search_cursor_column("⌚", 80), 10)
    assert_equal(_search_cursor_column("👩‍👩‍👧‍👦", 80), 10)
    assert_equal(_search_cursor_column("abcdefgh", 10), -1)


def test_frame_sequence_places_or_hides_the_real_cursor() raises:
    var frame = _TerminalEditorFrame()
    var input_rows: List[String] = ["> hello", "world"]
    var visible = _editor_frame_sequence(frame, input_rows, 1, 2, 7)
    assert_equal(
        visible,
        "\x1b[?25l\x1b[2K> hello\r\n\x1b[2Kworld\r" + "\x1b[2C\x1b[?25h",
    )
    assert_equal(frame.rows, 2)
    assert_equal(frame.cursor_row, 1)
    assert_equal(frame.scroll_y, 7)

    var search_rows: List[String] = ["Search: x"]
    var search = _editor_frame_sequence(frame, search_rows, 0, 9, 0)
    assert_equal(
        search,
        "\x1b[?25l\r\x1b[1A\x1b[2K\x1b[1B\r\x1b[2K"
        + "\x1b[1A\r\x1b[2KSearch: x\r\x1b[9C\x1b[?25h",
    )
    assert_true(search.endswith("\x1b[?25h"))
    assert_equal(frame.rows, 1)
    assert_equal(frame.cursor_row, 0)
    assert_equal(frame.scroll_y, 0)

    var overlay_rows: List[String] = ["overlay"]
    var hidden = _editor_frame_sequence(frame, overlay_rows, -1, 0, 0)
    assert_false(hidden.endswith("\x1b[?25h"))

    var finish = _finish_editor_frame_sequence(frame)
    assert_equal(finish, "\r\n\x1b[?25h")
    assert_true(finish.endswith("\x1b[?25h"))
    assert_equal(frame.rows, 0)


def test_new_interactive_ui_preserves_extension_commands() raises:
    var history: List[String] = ["before reset"]
    var messages: List[Message] = [Message("assistant", "ready")]
    var state = _interactive_ui_state(history, messages, ["/MiXeD"])
    _ = UiReducer.reduce(state, UiEvent.edit("/mixed argument"))
    var action = UiReducer.reduce(state, UiEvent.submit())
    assert_true(action.is_command())
    assert_equal(action.name, "/MiXeD")
    assert_equal(action.text, "argument")
    assert_equal(state.history[0], "before reset")
    assert_equal(state.roles[0], "assistant")


def test_interactive_session_replacement_ends_prior_id_before_commit() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(
            ProviderSpec("scripted", "https://invalid.local")
        ),
        ToolRegistry("/tmp"),
        PermissionManager(),
        "gpt-test",
    )
    runtime.set_messages([Message("user", "old transcript")])
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "lifecycle"))
    var registration = PluginRegistration("lifecycle", "1.0.0")
    registration.events.append(JsonValue.string(EVENT_SESSION_END))
    transport.enqueue_fixture_response(registration_result(2, registration))
    transport.enqueue_fixture_response(session_end_result(3))
    var plugin = PluginClient(transport^)
    plugin.connect()
    runtime.attach_plugin("lifecycle", plugin^)

    var session = Session("old-session", "gpt-test", "/work", 1)
    var replacement = Session("new-session", "gpt-test", "/work", 2)
    var errors = _replace_interactive_session(runtime, session, replacement^)

    assert_equal(len(errors), 0)
    assert_equal(session.id, "new-session")
    assert_equal(len(runtime.messages), 0)
    assert_equal(len(runtime.plugin_clients[0].transport.fixture_writes), 3)
    var lifecycle = RpcMessage.parse(
        runtime.plugin_clients[0].transport.fixture_writes[2]
    )
    assert_equal(lifecycle.method, METHOD_LIFECYCLE)
    assert_equal(
        lifecycle.payload.get("data").get("session_id").string_value,
        "old-session",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
