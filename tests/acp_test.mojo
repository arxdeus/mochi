from std.os import getenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mochi.acp import (
    ACP_PROTOCOL_VERSION,
    AcpMessage,
    AcpRuntimeServer,
    AcpSession,
    pending_permission_request,
    permission_answer,
    permission_options,
    permission_request,
    session_update,
)
from mochi.json import JsonValue, parse_json
from mochi.permissions import (
    PermissionAnswer,
    PermissionEffect,
    PermissionManager,
    PermissionRule,
)
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
    shutdown_result,
)
from mochi.provider import OpenAICompatibleProvider, ProviderSpec
from mochi.runtime import PendingPermission, Runtime
from mochi.session import Session, SessionStore
from mochi.tools import ToolRegistry
from mochi.types import CancellationToken, Message


def test_acp_codec_and_initialize() raises:
    var request = AcpMessage.request(1, "initialize", JsonValue.object())
    var decoded = AcpMessage.parse(request.line())
    assert_equal(decoded.method, "initialize")
    var session = AcpSession()
    var response = session.handle(decoded)
    assert_equal(
        response.payload.get("protocolVersion").int_value,
        ACP_PROTOCOL_VERSION,
    )
    assert_true(session.initialized)


def test_acp_session_lifecycle_and_updates() raises:
    var session = AcpSession()
    _ = session.handle(AcpMessage.request(1, "initialize", JsonValue.object()))
    var params = JsonValue.object()
    params.set("sessionId", JsonValue.string("session-1"))
    var created = session.handle(
        AcpMessage.request(2, "session/new", params.copy())
    )
    assert_equal(created.payload.get("sessionId").string_value, "session-1")
    var prompt = session.handle(
        AcpMessage.request(3, "session/prompt", params.copy())
    )
    assert_equal(prompt.payload.get("stopReason").string_value, "end_turn")
    _ = session.handle(AcpMessage.request(4, "session/cancel", params^))
    assert_equal(session.cancelled_sessions[0], "session-1")

    var update = JsonValue.object()
    update.set("sessionUpdate", JsonValue.string("agent_message_chunk"))
    var notification = session_update("session-1", update^)
    assert_equal(notification.method, "session/update")
    assert_equal(
        notification.payload.get("sessionId").string_value, "session-1"
    )


def test_acp_permission_and_unknown_method() raises:
    var permission = permission_request(
        7, "session-1", JsonValue.object(), JsonValue.array()
    )
    assert_equal(permission.method, "session/request_permission")
    var bridged = pending_permission_request(
        8,
        "session-1",
        PendingPermission("tool-1", "bash", JsonValue.object(), ["git status"]),
    )
    assert_equal(
        bridged.payload.get("toolCall").get("toolCallId").string_value,
        "tool-1",
    )
    assert_equal(
        bridged.payload.get("toolCall")
        .get("scopes")
        .array_value[0]
        .string_value,
        "git status",
    )
    var options = permission_options()
    assert_equal(len(options.array_value), 4)
    assert_equal(
        options.array_value[0].get("optionId").string_value, "allow_once"
    )
    var selected = JsonValue.object()
    selected.set("optionId", JsonValue.string("allow_always"))
    var outcome = JsonValue.object()
    outcome.set("outcome", JsonValue.string("selected"))
    outcome.set("option", selected^)
    var response = AcpMessage.response(7, JsonValue.object())
    response.payload.set("outcome", outcome^)
    assert_true(permission_answer(response) == PermissionAnswer.allow_session())
    assert_true(
        permission_answer(AcpMessage.failure(7, -32603, "failed"))
        == PermissionAnswer.deny()
    )
    var session = AcpSession()
    var failure = session.handle(
        AcpMessage.request(1, "session/prompt", JsonValue.object())
    )
    assert_equal(failure.kind, AcpMessage.ERROR)
    assert_equal(failure.error_code, -32002)


def _allowed() -> PermissionManager:
    var permissions = PermissionManager()
    permissions.add_rule(PermissionRule("*", PermissionEffect.allow(), "*"))
    return permissions^


def test_runtime_backed_prompt_and_session_persistence() raises:
    var directory = "/tmp/mochi-acp-runtime-test"
    var spec = ProviderSpec("scripted", "https://invalid.local")
    spec.max_retries = 0
    var provider = OpenAICompatibleProvider(spec^)
    provider.fail_with("fixture failure")
    var runtime = Runtime(
        provider^, ToolRegistry("/tmp"), _allowed(), "gpt-test"
    )
    var server = AcpRuntimeServer(runtime^, SessionStore(directory), 1234)
    var initialized = server.handle(
        AcpMessage.request(1, "initialize", JsonValue.object())
    )
    assert_equal(len(initialized), 1)
    var new_params = JsonValue.object()
    new_params.set("sessionId", JsonValue.string("acp-runtime"))
    new_params.set("cwd", JsonValue.string("/tmp"))
    var created = server.handle(
        AcpMessage.request(2, "session/new", new_params^)
    )
    assert_equal(
        created[0].payload.get("sessionId").string_value, "acp-runtime"
    )
    var prompt_params = JsonValue.object()
    prompt_params.set("sessionId", JsonValue.string("acp-runtime"))
    prompt_params.set("prompt", JsonValue.string("hello"))
    var prompted = server.handle(
        AcpMessage.request(3, "session/prompt", prompt_params^)
    )
    assert_equal(len(prompted), 2)
    assert_equal(prompted[0].method, "session/update")
    assert_true(
        "fixture failure"
        in prompted[0]
        .payload.get("update")
        .get("content")
        .get("text")
        .string_value
    )
    assert_equal(
        prompted[1].payload.get("stopReason").string_value, "provider_error"
    )
    var stored = SessionStore(directory).load("acp-runtime")
    assert_equal(stored.runtime_messages()[0].content, "hello")


def test_runtime_server_cancels_matching_active_prompt() raises:
    var runtime = Runtime(
        OpenAICompatibleProvider(
            ProviderSpec("scripted", "https://invalid.local")
        ),
        ToolRegistry("/tmp"),
        _allowed(),
        "gpt-test",
    )
    var server = AcpRuntimeServer(
        runtime^, SessionStore("/tmp/mochi-acp-cancel-test"), 1
    )
    server.active_session_id = "active"
    var token = CancellationToken()
    server.active_cancel = Optional(token.copy())
    assert_false(token.is_cancelled())
    assert_false(server.cancel_active("other"))
    assert_true(server.cancel_active("active"))
    assert_true(token.is_cancelled())
    var selected = JsonValue.object()
    selected.set("optionId", JsonValue.string("allow_once"))
    var outcome = JsonValue.object()
    outcome.set("outcome", JsonValue.string("selected"))
    outcome.set("option", selected^)
    var response = AcpMessage.response(1000, JsonValue.object())
    response.payload.set("outcome", outcome^)
    server.handle_permission_response(response)
    assert_equal(len(server.runtime.permission_answers), 1)
    assert_true(
        server.runtime.permission_answers[0] == PermissionAnswer.allow_once()
    )


def test_runtime_backed_load_replays_history() raises:
    var directory = "/tmp/mochi-acp-load-test"
    var store = SessionStore(directory)
    var session = Session("acp-load", "gpt-test", "/tmp", 1)
    session.replace_runtime_messages(
        [
            Message("user", "restored"),
            Message("assistant", "answer"),
        ]
    )
    store.save(session)
    var runtime = Runtime(
        OpenAICompatibleProvider(
            ProviderSpec("scripted", "https://invalid.local")
        ),
        ToolRegistry("/tmp"),
        _allowed(),
        "gpt-test",
    )
    var server = AcpRuntimeServer(runtime^, store^, 2)
    _ = server.handle(AcpMessage.request(1, "initialize", JsonValue.object()))
    var params = JsonValue.object()
    params.set("sessionId", JsonValue.string("acp-load"))
    var loaded = server.handle(AcpMessage.request(2, "session/load", params^))
    assert_equal(len(loaded), 2)
    assert_equal(
        loaded[1].payload.get("update").get("sessionUpdate").string_value,
        "history",
    )
    assert_equal(len(server.runtime.messages), 2)


def test_runtime_server_dispatches_session_end_before_replace_and_shutdown() raises:
    var spec = ProviderSpec("scripted", "https://invalid.local")
    spec.max_retries = 0
    var provider = OpenAICompatibleProvider(spec^)
    provider.fail_with("fixture failure")
    var runtime = Runtime(
        provider^,
        ToolRegistry("/tmp"),
        _allowed(),
        "gpt-test",
    )
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "lifecycle"))
    var registration = PluginRegistration("lifecycle", "1.0.0")
    registration.events.append(JsonValue.string(EVENT_SESSION_END))
    transport.enqueue_fixture_response(registration_result(2, registration))
    transport.enqueue_fixture_response(session_end_result(3))
    transport.enqueue_fixture_response(session_end_result(4))
    transport.enqueue_fixture_response(session_end_result(5))
    transport.enqueue_fixture_response(shutdown_result(6))
    var plugin = PluginClient(transport^)
    plugin.connect()
    runtime.attach_plugin("lifecycle", plugin^)

    var server = AcpRuntimeServer(
        runtime^,
        SessionStore(getenv("TMPDIR", "/tmp") + "/mochi-acp-lifecycle-test"),
        1,
    )
    _ = server.handle(AcpMessage.request(1, "initialize", JsonValue.object()))
    var first = JsonValue.object()
    first.set("sessionId", JsonValue.string("session-one"))
    _ = server.handle(AcpMessage.request(2, "session/new", first^))
    var invalid = JsonValue.object()
    invalid.set("sessionId", JsonValue.integer(7))
    with assert_raises():
        _ = server.handle(AcpMessage.request(3, "session/new", invalid^))
    assert_equal(server.active_session_id, "session-one")

    var empty = JsonValue.object()
    empty.set("sessionId", JsonValue.string(""))
    with assert_raises():
        _ = server.handle(AcpMessage.request(4, "session/new", empty^))

    var duplicate = JsonValue.object()
    duplicate.set("sessionId", JsonValue.string("session-one"))
    with assert_raises():
        _ = server.handle(AcpMessage.request(5, "session/new", duplicate^))
    assert_equal(
        len(server.runtime.plugin_clients[0].transport.fixture_writes), 2
    )
    assert_equal(len(server.sessions), 1)

    var second = JsonValue.object()
    second.set("sessionId", JsonValue.string("session-two"))
    _ = server.handle(AcpMessage.request(6, "session/new", second^))

    var first_end = RpcMessage.parse(
        server.runtime.plugin_clients[0].transport.fixture_writes[2]
    )
    assert_equal(first_end.method, METHOD_LIFECYCLE)
    assert_equal(
        first_end.payload.get("data").get("session_id").string_value,
        "session-one",
    )

    var prompt = JsonValue.object()
    prompt.set("sessionId", JsonValue.string("session-one"))
    prompt.set("prompt", JsonValue.string("resume first"))
    _ = server.handle(AcpMessage.request(7, "session/prompt", prompt^))
    assert_equal(server.active_session_id, "session-one")
    var second_end = RpcMessage.parse(
        server.runtime.plugin_clients[0].transport.fixture_writes[3]
    )
    assert_equal(
        second_end.payload.get("data").get("session_id").string_value,
        "session-two",
    )

    server.shutdown()
    var final_end = RpcMessage.parse(
        server.runtime.plugin_clients[0].transport.fixture_writes[4]
    )
    assert_equal(
        final_end.payload.get("data").get("session_id").string_value,
        "session-one",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
