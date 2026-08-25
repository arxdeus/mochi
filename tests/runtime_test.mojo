from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.json import JsonValue, parse_json, serialize_json
from mochi.permissions import PermissionEffect, PermissionManager, PermissionRule
from mochi.provider import OpenAICompatibleProvider, ProviderSpec, RetryState
from mochi.runtime import (
    Runtime,
    ToolDefinition,
    apply_scripted_response,
    build_request_body,
    build_responses_request_body,
    message_json,
)
from mochi.tools import ToolRegistry, ToolResult
from mochi.types import CancellationToken, Message, ToolCall, Usage


def allowed() -> PermissionManager:
    var permissions = PermissionManager()
    permissions.add_rule(PermissionRule("*", PermissionEffect.allow(), "*"))
    return permissions^


def schema() raises -> JsonValue:
    return parse_json(
        '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}'
    )


def test_request_body_messages_and_tool_definitions() raises:
    var messages: List[Message] = [Message("system", "help"), Message("user", "read it")]
    var assistant = Message("assistant", "checking")
    assistant.add_tool_call(ToolCall("call-1", "read", '{"path":"a.txt"}'))
    messages.append(assistant^)
    var tool_result = Message("tool", "contents")
    tool_result.tool_call_id = "call-1"
    tool_result.name = "read"
    messages.append(tool_result^)
    var definitions: List[ToolDefinition] = [
        ToolDefinition("read", "Read a file", schema())
    ]
    var body = build_request_body("gpt-test", messages, definitions)
    assert_equal(body.get("model").string_value, "gpt-test")
    assert_true(body.get("stream").bool_value)
    assert_equal(body.get("tool_choice").string_value, "auto")
    var raw_messages = body.get("messages")
    assert_equal(len(raw_messages.array_value), 4)
    assert_equal(
        raw_messages.array_value[2].get("tool_calls").array_value[0].get("function").get("arguments").string_value,
        '{"path":"a.txt"}',
    )
    assert_equal(raw_messages.array_value[3].get("tool_call_id").string_value, "call-1")
    var raw_tool = body.get("tools").array_value[0].copy()
    assert_equal(raw_tool.get("type").string_value, "function")
    assert_equal(raw_tool.get("function").get("name").string_value, "read")


def test_responses_request_body() raises:
    var messages: List[Message] = [Message("user", "inspect")]
    var assistant = Message("assistant", "checking")
    assistant.add_tool_call(ToolCall("call-1", "read", '{"path":"a.txt"}'))
    messages.append(assistant^)
    var output = Message("tool", "contents")
    output.tool_call_id = "call-1"
    messages.append(output^)
    var definitions: List[ToolDefinition] = [ToolDefinition("read", "Read", schema())]
    var body = build_responses_request_body("gpt-codex", messages, definitions)
    assert_true(body.get("stream").bool_value)
    assert_false(body.get("store").bool_value)
    assert_equal(body.get("input").array_value[0].get("content").array_value[0].get("type").string_value, "input_text")
    assert_equal(body.get("input").array_value[2].get("type").string_value, "function_call")
    assert_equal(body.get("input").array_value[3].get("type").string_value, "function_call_output")
    assert_equal(body.get("tools").array_value[0].get("name").string_value, "read")


def test_scripted_response_updates_multi_turn_state_and_usage() raises:
    var messages: List[Message] = [Message("user", "inspect")]
    var usage = Usage()
    var first = (
        'data: {"choices":[{"delta":{"content":"checking","tool_calls":[{"index":0,"id":"call-1","function":{"name":"read","arguments":"{\\"path\\":\\"a.txt\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}\n\ndata: [DONE]\n\n'
    )
    assert_equal(apply_scripted_response(messages, usage, first), "tool_calls")
    assert_equal(len(messages), 2)
    assert_equal(messages[1].content, "checking")
    assert_equal(messages[1].tool_calls[0].name, "read")
    assert_equal(usage.input_tokens, 5)
    assert_equal(usage.output_tokens, 2)

    var tool = Message("tool", "contents")
    tool.tool_call_id = "call-1"
    messages.append(tool^)
    var second = (
        'data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":1}}\n\ndata: [DONE]\n\n'
    )
    assert_equal(apply_scripted_response(messages, usage, second), "stop")
    assert_equal(messages[3].content, "done")
    assert_equal(usage.input_tokens, 12)
    assert_equal(usage.output_tokens, 3)


def test_dispatch_permissions_cancellation_and_compaction() raises:
    var spec = ProviderSpec("scripted", "https://invalid.local")
    var denied = PermissionManager(PermissionEffect.deny())
    var runtime = Runtime(
        OpenAICompatibleProvider(spec^),
        ToolRegistry("/tmp"),
        denied^,
        "gpt-test",
        max_context_chars=5,
        compact_keep=1,
    )
    runtime.messages.append(Message("old", "long old content"))
    runtime.messages.append(Message("user", "new long content"))
    assert_true(runtime.compact_if_needed())
    assert_equal(runtime.messages[0].role, "system")
    assert_equal(runtime.compactions, 1)

    runtime.dispatch(ToolCall("w", "write", '{"path":"blocked","content":"x"}'), CancellationToken())
    assert_true("Permission denied" in runtime.messages[len(runtime.messages) - 1].content)
    runtime.permissions = allowed()
    var token = CancellationToken()
    token.cancel()
    runtime.dispatch(ToolCall("r", "read", '{"path":"anything"}'), token)
    assert_true("cancelled" in runtime.messages[len(runtime.messages) - 1].content)


def test_remote_mcp_plugin_registration_and_dispatch() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    var mcp_tools = parse_json(
        '[{"name":"remote_search","description":"Search remotely","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}}}]'
    )
    runtime.add_remote_tools("mcp", "search-server", mcp_tools)
    var plugin_tools = parse_json(
        '[{"name":"remote_format","description":"Format text","parameters":{"type":"object"}}]'
    )
    runtime.add_remote_tools("plugin", "formatter", plugin_tools)

    assert_equal(len(runtime.definitions), 2)
    var body = runtime.request_body()
    var tools = body.get("tools")
    assert_equal(
        tools.array_value[0].get("function").get("name").string_value,
        "remote_search",
    )
    assert_equal(
        tools.array_value[0].get("function").get("parameters").get("type").string_value,
        "object",
    )
    assert_equal(
        tools.array_value[1].get("function").get("name").string_value,
        "remote_format",
    )

    runtime.enqueue_remote_result(
        "remote_search", ToolResult.success('{"content":"found"}')
    )
    runtime.enqueue_remote_result(
        "remote_format", ToolResult.success('{"content":"formatted"}')
    )
    runtime.dispatch(
        ToolCall("remote-1", "remote_search", '{"query":"mojo"}'),
        CancellationToken(),
    )
    assert_equal(runtime.messages[len(runtime.messages) - 1].content, '{"content":"found"}')
    assert_equal(runtime.messages[len(runtime.messages) - 1].tool_call_id, "remote-1")
    runtime.dispatch(
        ToolCall("remote-2", "remote_format", '{"text":"mojo"}'),
        CancellationToken(),
    )
    assert_equal(runtime.messages[len(runtime.messages) - 1].content, '{"content":"formatted"}')


def test_provider_error_is_visible_in_result() raises:
    var spec = ProviderSpec("fixture", "https://invalid.local")
    spec.max_retries = 0
    var provider = OpenAICompatibleProvider(spec^)
    provider.fail_with("fixture failure")
    var runtime = Runtime(
        provider^,
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    var result = runtime.run("hello", CancellationToken())
    assert_equal(result.stop_reason, "provider_error")
    assert_equal(result.text, "Error: fixture failure")
    assert_equal(result.text, runtime.messages[len(runtime.messages) - 1].content)


def test_runtime_cancellation_max_turn_and_retry_helpers() raises:
    var spec = ProviderSpec("scripted", "https://invalid.local")
    var runtime = Runtime(
        OpenAICompatibleProvider(spec^),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
        max_turns=0,
    )
    var maxed = runtime.run("hello", CancellationToken())
    assert_equal(maxed.stop_reason, "max_turns")
    assert_equal(maxed.turns, 0)

    var cancelled_runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    var token = CancellationToken()
    token.cancel()
    var cancelled = cancelled_runtime.run("hello", token)
    assert_equal(cancelled.stop_reason, "cancelled")
    assert_equal(cancelled.turns, 0)

    var retry = RetryState(2)
    assert_true(retry.can_retry())
    assert_equal(retry.next_delay_ms(), 541)
    assert_true(RetryState.retryable_status(429))
    assert_false(RetryState.retryable_status(401))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
