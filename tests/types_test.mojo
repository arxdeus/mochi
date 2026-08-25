from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from mochi.types import CancellationToken, Message, ProviderEvent, ToolCall, Usage


def test_message_and_tool_calls() raises:
    var message = Message("assistant", "calling tool")
    message.add_tool_call(ToolCall("call-1", "read", "{path:x}"))
    assert_equal(message.role, "assistant")
    assert_equal(len(message.tool_calls), 1)
    assert_equal(message.tool_calls[0].name, "read")


def test_usage_accumulates() raises:
    var usage = Usage(3, 2)
    usage.add(Usage(4, 5))
    assert_equal(usage.input_tokens, 7)
    assert_equal(usage.output_tokens, 7)
    assert_equal(usage.total_tokens(), 14)


def test_provider_event_factories() raises:
    var text = ProviderEvent.text_delta("hello")
    assert_equal(text.kind, "text_delta")
    assert_equal(text.text, "hello")

    var done = ProviderEvent.done("stop")
    assert_equal(done.kind, "done")
    assert_equal(done.stop_reason, "stop")

    var tool = ProviderEvent.tool_call_delta(ToolCall("c", "bash", "{}"))
    assert_true(tool.tool_call)
    assert_equal(tool.tool_call.value().name, "bash")


def test_cancellation_token() raises:
    var token = CancellationToken()
    assert_false(token.is_cancelled())
    token.check()
    token.cancel()
    assert_true(token.is_cancelled())
    with assert_raises():
        token.check()


def test_cancellation_copy_visibility() raises:
    var original = CancellationToken()
    var copied = original.copy()
    copied.cancel()
    assert_true(original.is_cancelled())
    assert_true(copied.is_cancelled())


def test_cancellation_hierarchy_is_one_way() raises:
    var parent = CancellationToken()
    var first = parent.child()
    var second = parent.child()
    var grandchild = first.child()
    first.cancel()
    assert_false(parent.is_cancelled())
    assert_false(second.is_cancelled())
    assert_true(first.is_cancelled())
    assert_true(grandchild.is_cancelled())
    parent.cancel()
    assert_true(second.is_cancelled())


def test_cancellation_is_monotonic() raises:
    var token = CancellationToken()
    token.cancel()
    token.cancel()
    assert_true(token.is_cancelled())
    var late_child = token.child()
    assert_true(late_child.is_cancelled())


def _child_of_temporary_parent() -> CancellationToken:
    var parent = CancellationToken()
    return parent.child()


def _copy_of_temporary_token() -> CancellationToken:
    var token = CancellationToken()
    return token.copy()


def test_cancellation_lifetime() raises:
    var child = _child_of_temporary_parent()
    assert_false(child.is_cancelled())
    child.cancel()
    assert_true(child.is_cancelled())

    var copied = _copy_of_temporary_token()
    assert_false(copied.is_cancelled())
    copied.cancel()
    assert_true(copied.is_cancelled())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
