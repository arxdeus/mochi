from std.testing import TestSuite, assert_equal, assert_true

from mochi.acp import (
    ACP_PROTOCOL_VERSION,
    AcpMessage,
    AcpSession,
    permission_request,
    session_update,
)
from mochi.json import JsonValue


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
