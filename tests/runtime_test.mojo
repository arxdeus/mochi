from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.http import FlokiTransport
from mochi.json import JsonValue, parse_json, serialize_json
from mochi.mcp import McpClient, McpOAuthState, StdioTransport, StreamableHttpTransport
from mochi.permissions import (
    PermissionAnswer,
    PermissionEffect,
    PermissionManager,
    PermissionRule,
)
from mochi.plugin import (
    PluginClient,
    PluginRegistration,
    PluginTransport,
    RpcMessage,
    handshake_result,
    invoke_result,
    registration_result,
    shutdown_result,
)
from mochi.provider_contract import ThinkingConfig
from mochi.storage import OAuthTokens
from mochi.provider import (
    AnthropicProviderSpec,
    GeminiProviderSpec,
    OpenAICompatibleProvider,
    OpenAIProviderAdapter,
    ProductionProvider,
    ProviderResult,
    ProviderSpec,
    RetryState,
    find_model_info,
)
from mochi.session import Session
from mochi.runtime import (
    Runtime,
    ToolDefinition,
    apply_scripted_response,
    build_request_body,
    build_responses_request_body,
    message_json,
    _runtime_model,
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


def test_runtime_uses_catalog_model_metadata() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-5.3-codex",
    )
    assert_equal(runtime.provider.model_info.context_window.value(), 400000)
    var model = _runtime_model(
        runtime.model,
        runtime.provider.name,
        runtime.provider.model_info,
    )
    assert_equal(model.context_window, 400000)
    assert_true(model.supports_thinking())
    assert_true(model.supports_vision())


def test_runtime_accepts_production_provider_dialects() raises:
    var anthropic = Runtime(
        ProductionProvider(
            AnthropicProviderSpec("https://api.anthropic.test", "secret"),
            FlokiTransport(),
            find_model_info("claude-opus-4-6"),
        ),
        ToolRegistry("/tmp"),
        allowed(),
        "claude-opus-4-6",
    )
    assert_equal(anthropic.provider.kind, "anthropic")
    assert_equal(anthropic.provider.name, "anthropic")
    assert_false(anthropic.provider.uses_responses_api())
    var gemini = Runtime(
        ProductionProvider(
            GeminiProviderSpec(
                "https://generativelanguage.googleapis.test/v1beta", "secret"
            ),
            FlokiTransport(),
            find_model_info("gemini-2.5-pro"),
        ),
        ToolRegistry("/tmp"),
        allowed(),
        "gemini-2.5-pro",
    )
    assert_equal(gemini.provider.kind, "gemini")
    assert_equal(gemini.provider.name, "google")


def test_runtime_provider_api_key_update() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("openai", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    runtime.provider.set_api_key("saved-key")
    assert_equal(
        runtime.provider.adapter[OpenAIProviderAdapter].inner.auth_token(),
        "saved-key",
    )


def test_runtime_interactive_request_modes() raises:
    var runtime = Runtime(
        ProductionProvider(
            AnthropicProviderSpec("https://api.anthropic.test", "secret"),
            FlokiTransport(),
            find_model_info("claude-opus-4-6"),
        ),
        ToolRegistry("/tmp"),
        allowed(),
        "claude-opus-4-6",
    )
    assert_true(runtime.set_thinking(""))
    assert_equal(runtime.options.thinking.tag, ThinkingConfig.ADAPTIVE)
    assert_true(runtime.set_thinking("8192"))
    assert_equal(runtime.options.thinking.budget_tokens, 8192)
    assert_false(runtime.set_thinking("garbage"))
    assert_equal(runtime.options.thinking.budget_tokens, 8192)
    assert_true(runtime.set_fast(True))
    assert_true(runtime.options.fast)
    assert_true(runtime.set_fast(False))
    assert_false(runtime.options.fast)
    assert_true(runtime.toggle_workflow())
    assert_true(runtime.tools.workflow)
    var meta = runtime.save_modes(JsonValue.object())
    var restored = Runtime(
        ProductionProvider(
            AnthropicProviderSpec("https://api.anthropic.test", "secret"),
            FlokiTransport(),
            find_model_info("claude-opus-4-6"),
        ),
        ToolRegistry("/tmp"),
        allowed(),
        "claude-opus-4-6",
    )
    restored.restore_modes(meta)
    assert_equal(restored.options.thinking.budget_tokens, 8192)
    assert_false(restored.options.fast)
    assert_true(restored.workflow)
    assert_true(restored.tools.workflow)
    assert_false(runtime.toggle_workflow())
    assert_false(runtime.tools.workflow)

    var unsupported = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    assert_false(unsupported.set_thinking("high"))
    assert_false(unsupported.set_fast(True))


def test_queued_input_is_wrapped_and_consumed() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    runtime.queue_input("new direction")
    assert_equal(runtime.queued_input_count(), 1)
    assert_true(runtime.consume_queued_input())
    assert_equal(runtime.queued_input_count(), 0)
    assert_true("<user-interrupt>" in runtime.messages[0].content)
    assert_true("new direction" in runtime.messages[0].content)
    assert_false(runtime.consume_queued_input())
    runtime.messages = [
        Message("user", "one"),
        Message("assistant", "two"),
        Message("user", "three"),
    ]
    runtime.compact_keep = 1
    runtime.queue_compaction()
    assert_equal(runtime.queued_compaction_count(), 1)
    assert_true(runtime.consume_queued_command())
    assert_equal(runtime.queued_compaction_count(), 0)
    assert_equal(runtime.compactions, 1)


def test_system_prompt_is_sent_but_not_persisted() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(
            ProviderSpec("scripted", "https://invalid.local")
        ),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    runtime.set_system_prompt("system instructions")
    runtime.set_messages([Message("user", "prior")])
    var body = runtime.request_body()
    var messages = body.get("messages")
    assert_equal(messages.array_value[0].get("role").string_value, "system")
    assert_equal(
        messages.array_value[0].get("content").string_value,
        "system instructions",
    )
    assert_equal(len(runtime.messages), 1)
    assert_equal(runtime.messages[0].content, "prior")


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


def test_permission_prompt_answers_execute_and_persist_session_allow() raises:
    var prompted = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        PermissionManager(),
        "gpt-test",
    )
    prompted.dispatch(
        ToolCall("pending", "bash", '{"command":"printf pending"}'),
        CancellationToken(),
    )
    var pending = prompted.take_pending_permission()
    assert_true(pending)
    assert_equal(pending.value().tool_call_id, "pending")
    assert_equal(pending.value().tool, "bash")
    assert_equal(pending.value().scopes[0], "printf pending")
    var resolved = prompted.resolve_permission(
        pending.value(), PermissionAnswer.allow_once()
    )
    assert_true("pending" in resolved)
    assert_true(
        "pending" in prompted.messages[len(prompted.messages) - 1].content
    )

    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        PermissionManager(),
        "gpt-test",
    )
    runtime.answer_next_permission(PermissionAnswer.allow_session())
    runtime.dispatch(
        ToolCall("first", "bash", '{"command":"printf allowed"}'),
        CancellationToken(),
    )
    assert_true("allowed" in runtime.messages[len(runtime.messages) - 1].content)
    runtime.dispatch(
        ToolCall("second", "bash", '{"command":"printf again"}'),
        CancellationToken(),
    )
    assert_true("again" in runtime.messages[len(runtime.messages) - 1].content)

    var denied = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        PermissionManager(),
        "gpt-test",
    )
    denied.answer_next_permission(PermissionAnswer.deny())
    denied.dispatch(
        ToolCall("deny", "bash", '{"command":"printf blocked"}'),
        CancellationToken(),
    )
    assert_true("Permission denied" in denied.messages[len(denied.messages) - 1].content)


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


def test_remote_status_lines() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    var client = McpClient("fixture")
    runtime.attach_mcp_stdio("fixture", client^, StdioTransport())
    var http = StreamableHttpTransport("https://mcp.example/mcp")
    http.set_bearer_token("saved")
    var http_client = McpClient("authenticated")
    http_client.session.initialized = True
    runtime.attach_mcp_http("authenticated", http_client^, http^)
    runtime.plugin_names.append("formatter")
    var lines = runtime.remote_status_lines()
    assert_equal(lines[0], "fixture · stdio · connecting")
    assert_equal(lines[1], "authenticated · http · running · authenticated")
    assert_equal(lines[2], "formatter · executable extension · running")
    assert_equal(runtime.mcp_picker_items(), "1:fixture\n1:authenticated")
    assert_true(runtime.set_mcp_enabled("fixture", False))
    assert_equal(runtime.mcp_picker_items(), "0:fixture\n1:authenticated")
    assert_equal(runtime.remote_status_lines()[0], "fixture · stdio · disabled")
    assert_false(runtime.set_mcp_enabled("missing", False))
    assert_equal(
        runtime.mcp_http_url("authenticated").value(),
        "https://mcp.example/mcp",
    )
    assert_false(runtime.mcp_http_url("missing"))
    assert_true(
        runtime.apply_mcp_oauth(
            "authenticated",
            McpOAuthState(
                OAuthTokens("new-access", "refresh", 1000, None),
                "https://auth.example/token",
                "client",
                "secret",
                "https://mcp.example/mcp",
            ),
        )
    )
    assert_equal(runtime.mcp_http_transports[0].bearer_token, "new-access")
    assert_true(runtime.clear_mcp_oauth("authenticated"))
    assert_equal(runtime.mcp_http_transports[0].bearer_token, "")
    assert_false(runtime.mcp_http_authenticated[0])
    assert_equal(
        runtime.remote_status_lines()[1],
        "authenticated · http · needs auth",
    )
    assert_true(runtime.mark_mcp_http_error("authenticated", "error: offline"))
    assert_equal(
        runtime.remote_status_lines()[1],
        "authenticated · http · error: offline",
    )


def test_runtime_reconnects_http_mcp_and_replaces_tools() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    runtime.add_remote_tools(
        "mcp", "server", parse_json('[{"name":"old_tool"}]')
    )
    var transport = StreamableHttpTransport("https://mcp.example/mcp")
    transport.enqueue_fixture_response(
        200,
        "application/json",
        '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}',
    )
    transport.enqueue_fixture_response(202, "application/json", "")
    transport.enqueue_fixture_response(
        200,
        "application/json",
        '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"new_tool"}]}}',
    )
    var client = McpClient("server")
    runtime.attach_mcp_http("server", client^, transport^)
    assert_equal(runtime.reconnect_mcp_http("server"), 1)
    assert_equal(runtime.remote_endpoint("old_tool"), "")
    assert_equal(runtime.remote_endpoint("new_tool"), "server")
    assert_equal(runtime.mcp_http_errors[0], "")


def test_live_remote_mcp_and_plugin_dispatch() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    runtime.add_remote_tools(
        "mcp", "search-server", parse_json('[{"name":"remote_search"}]')
    )
    var mcp_transport = StdioTransport()
    mcp_transport.enqueue_fixture_response(
        '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"found"}]}}'
    )
    runtime.attach_mcp_stdio(
        "search-server", McpClient("search-server"), mcp_transport^
    )
    runtime.dispatch(
        ToolCall("mcp-call", "remote_search", '{"query":"mojo"}'),
        CancellationToken(),
    )
    assert_true('"text":"found"' in runtime.messages[len(runtime.messages) - 1].content)

    var plugin_transport = PluginTransport()
    plugin_transport.enqueue_fixture_response(handshake_result(1, "formatter"))
    var registration = PluginRegistration("formatter", "1.0.0")
    registration.tools.append(parse_json('{"name":"remote_format"}'))
    plugin_transport.enqueue_fixture_response(registration_result(2, registration))
    plugin_transport.enqueue_fixture_response(
        invoke_result(3, parse_json('{"content":"formatted"}'))
    )
    plugin_transport.enqueue_fixture_response(shutdown_result(4))
    var plugin = PluginClient(plugin_transport^)
    plugin.connect()
    runtime.add_remote_tools(
        "plugin", "formatter", registration.tools.copy()
    )
    runtime.attach_plugin("formatter", plugin^)
    runtime.dispatch(
        ToolCall("plugin-call", "remote_format", '{"text":"mojo"}'),
        CancellationToken(),
    )
    assert_equal(
        runtime.messages[len(runtime.messages) - 1].content,
        '{"content":"formatted"}',
    )
    runtime.shutdown_remotes()


def test_runtime_task_runs_isolated_child_and_persists_transcript() raises:
    var provider = OpenAICompatibleProvider(
        ProviderSpec("scripted", "https://invalid.local")
    )
    var child_response = ProviderResult()
    child_response.message = Message("assistant", "child summary")
    provider.enqueue_result(child_response)
    var runtime = Runtime(
        provider^,
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    _ = runtime.toggle_workflow()
    runtime.dispatch(
        ToolCall("task-1", "task", '{"description":"research","prompt":"inspect"}'),
        CancellationToken(),
    )
    assert_equal(runtime.messages[len(runtime.messages) - 1].content, "child summary")
    assert_equal(runtime.subagent_ids[0], "task-1")
    assert_equal(runtime.subagent_names[0], "research")
    assert_equal(len(runtime.subagent_messages[0]), 2)
    assert_equal(runtime.subagent_messages[0][0].content, "inspect")
    assert_equal(runtime.subagent_messages[0][1].content, "child summary")
    var session = Session("session", "gpt-test", "/tmp", 1)
    runtime.persist_subagents(session)
    assert_equal(session.task_names()[1], "research")
    var saved = session.task_messages(1)
    assert_equal(len(saved), 2)
    assert_equal(saved[1].content, "child summary")


def test_runtime_task_structured_output_retries_and_validates() raises:
    var provider = OpenAICompatibleProvider(
        ProviderSpec("scripted", "https://invalid.local")
    )
    var invalid = ProviderResult()
    invalid.message = Message("assistant", "not json")
    provider.enqueue_result(invalid)
    var valid = ProviderResult()
    valid.message = Message("assistant", '{"answer":"done"}')
    provider.enqueue_result(valid)
    var runtime = Runtime(
        provider^,
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    _ = runtime.toggle_workflow()
    runtime.dispatch(
        ToolCall(
            "task-json",
            "task",
            '{"description":"structured","prompt":"answer","output_schema":{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}}}}',
        ),
        CancellationToken(),
    )
    assert_equal(
        runtime.messages[len(runtime.messages) - 1].content,
        '{"answer":"done"}',
    )
    assert_equal(len(runtime.subagent_messages[0]), 4)


def test_runtime_plugin_commands_and_prompt_hints() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    runtime.system_prompt = "base"
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "extension"))
    var registration = PluginRegistration("extension", "1.0.0")
    registration.commands.append(parse_json('{"name":"hello"}'))
    registration.prompt_hints.append(JsonValue.string("Extension guidance"))
    transport.enqueue_fixture_response(registration_result(2, registration))
    transport.enqueue_fixture_response(
        invoke_result(3, parse_json('{"content":"command ran"}'))
    )
    var client = PluginClient(transport^)
    client.connect()
    runtime.attach_plugin("extension", client^)
    assert_equal(runtime.plugin_command_names()[0], "hello")
    runtime.apply_plugin_prompt_hints()
    assert_true("Extension guidance" in runtime.system_prompt)
    var output = parse_json(runtime.invoke_plugin_command("hello", "one two"))
    assert_equal(output.get("content").string_value, "command ran")
    var request = RpcMessage.parse(runtime.plugin_clients[0].transport.fixture_writes[2])
    assert_equal(request.payload.get("kind").string_value, "command")
    assert_equal(
        request.payload.get("arguments").get("arguments").string_value,
        "one two",
    )


def test_runtime_reload_replaces_plugin_routes() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "first"))
    var first = PluginRegistration("first", "1.0.0")
    first.tools.append(
        parse_json('{"name":"old_tool","description":"old","inputSchema":{}}')
    )
    transport.enqueue_fixture_response(registration_result(2, first))
    transport.enqueue_fixture_response(handshake_result(1, "second"))
    var second = PluginRegistration("second", "2.0.0")
    second.tools.append(
        parse_json('{"name":"new_tool","description":"new","inputSchema":{}}')
    )
    transport.enqueue_fixture_response(registration_result(2, second))
    var client = PluginClient(transport^)
    client.connect()
    runtime.add_remote_tools("plugin", "first", first.tools.copy())
    runtime.attach_plugin("first", client^)
    assert_true(runtime.remote.is_remote("old_tool"))
    assert_equal(runtime.reload_plugins(), 1)
    assert_false(runtime.remote.is_remote("old_tool"))
    assert_true(runtime.remote.is_remote("new_tool"))
    assert_equal(runtime.plugin_names[0], "second")


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


def test_runtime_resume_does_not_append_user_message() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
        ToolRegistry("/tmp"),
        allowed(),
        "gpt-test",
    )
    runtime.messages.append(Message("tool", "approved"))
    var cancel = CancellationToken()
    cancel.cancel()
    var result = runtime.resume(cancel^)
    assert_equal(result.stop_reason, "cancelled")
    assert_equal(len(result.messages), 1)
    assert_equal(result.messages[0].role, "tool")


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
    assert_equal(retry.next_delay_ms(), 1041)
    assert_true(RetryState.retryable_status(429))
    assert_false(RetryState.retryable_status(401))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
