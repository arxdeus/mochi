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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
