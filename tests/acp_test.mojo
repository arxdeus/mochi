from std.testing import TestSuite, assert_equal, assert_true

from mochi.acp import (
    ACP_PROTOCOL_VERSION,
    AcpMessage,
    AcpRuntimeServer,
    AcpSession,
    permission_request,
    session_update,
)
from mochi.json import JsonValue, parse_json
from mochi.permissions import PermissionEffect, PermissionManager, PermissionRule
from mochi.provider import OpenAICompatibleProvider, ProviderSpec
from mochi.runtime import Runtime
from mochi.session import Session, SessionStore
from mochi.tools import ToolRegistry
from mochi.types import Message


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
    var created = session.handle(AcpMessage.request(2, "session/new", params.copy()))
    assert_equal(created.payload.get("sessionId").string_value, "session-1")
    var prompt = session.handle(AcpMessage.request(3, "session/prompt", params.copy()))
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
    var server = AcpRuntimeServer(
        runtime^, SessionStore(directory), 1234
    )
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
        in prompted[0].payload.get("update").get("content").get("text").string_value
    )
    assert_equal(prompted[1].payload.get("stopReason").string_value, "provider_error")
    var stored = SessionStore(directory).load("acp-runtime")
    assert_equal(stored.runtime_messages()[0].content, "hello")


def test_runtime_backed_load_replays_history() raises:
    var directory = "/tmp/mochi-acp-load-test"
    var store = SessionStore(directory)
    var session = Session("acp-load", "gpt-test", "/tmp", 1)
    session.replace_runtime_messages([
        Message("user", "restored"),
        Message("assistant", "answer"),
    ])
    store.save(session)
    var runtime = Runtime(
        OpenAICompatibleProvider(ProviderSpec("scripted", "https://invalid.local")),
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
