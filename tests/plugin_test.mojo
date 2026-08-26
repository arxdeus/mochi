from mochi.json import JsonValue, parse_json
from mochi.plugin import (
    ERROR_INVALID_PARAMS,
    METHOD_HANDSHAKE,
    METHOD_INVOKE,
    METHOD_REGISTER,
    METHOD_SHUTDOWN,
    PLUGIN_PROTOCOL_VERSION,
    PluginClient,
    PluginExecutable,
    PluginProtocol,
    PluginRegistration,
    PluginTransport,
    RpcMessage,
    error_result,
    handshake_result,
    invoke_result,
    registration_result,
    shutdown_result,
)
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true


def test_json_rpc_lines_and_protocol_constants() raises:
    var protocol = PluginProtocol()
    var line = protocol.handshake("test-host")
    assert_true(line.endswith("\n"))
    var request = RpcMessage.parse(line)
    assert_equal(request.method, METHOD_HANDSHAKE)
    assert_equal(request.id, 1)
    assert_equal(request.payload.get("version").int_value, PLUGIN_PROTOCOL_VERSION)
    assert_equal(request.payload.get("host").string_value, "test-host")


def test_handshake_registration_invoke_shutdown_state_flow() raises:
    var protocol = PluginProtocol()
    var handshake = RpcMessage.parse(protocol.handshake())
    protocol.accept_handshake(handshake_result(handshake.id, "example"))

    var register = RpcMessage.parse(protocol.registration_request())
    assert_equal(register.method, METHOD_REGISTER)
    var metadata = PluginRegistration("example", "1.2.3")
    metadata.tools.append(parse_json("{\"name\":\"search\",\"description\":\"Search\"}"))
    metadata.commands.append(parse_json("{\"name\":\"hello\"}"))
    metadata.events.append(JsonValue.string("session.started"))
    metadata.prompt_hints.append(JsonValue.string("Be concise"))
    metadata.keymaps.append(parse_json("{\"key\":\"ctrl+k\",\"command\":\"hello\"}"))
    protocol.accept_registration(registration_result(register.id, metadata))
    assert_true(protocol.is_ready())
    assert_true(protocol.registration)
    assert_equal(protocol.registration.value().name, "example")
    assert_equal(len(protocol.registration.value().tools.array_value), 1)
    assert_equal(len(protocol.registration.value().commands.array_value), 1)
    assert_equal(len(protocol.registration.value().events.array_value), 1)
    assert_equal(len(protocol.registration.value().prompt_hints.array_value), 1)
    assert_equal(len(protocol.registration.value().keymaps.array_value), 1)

    var arguments = parse_json("{\"query\":\"mojo\"}")
    var invoke = RpcMessage.parse(protocol.invoke("tool", "search", arguments^))
    assert_equal(invoke.method, METHOD_INVOKE)
    assert_equal(invoke.payload.get("kind").string_value, "tool")
    assert_equal(invoke.payload.get("name").string_value, "search")
    var answer = parse_json("{\"content\":\"found\"}")
    var result = protocol.accept_invoke(invoke_result(invoke.id, answer^))
    assert_equal(result.get("content").string_value, "found")
    assert_true(protocol.is_ready())

    var shutdown = RpcMessage.parse(protocol.shutdown())
    assert_equal(shutdown.method, METHOD_SHUTDOWN)
    protocol.accept_shutdown(shutdown_result(shutdown.id))
    assert_equal(protocol.state, PluginProtocol.CLOSED)


def test_invalid_order_version_id_and_remote_error() raises:
    var protocol = PluginProtocol()
    with assert_raises():
        _ = protocol.registration_request()

    var handshake = RpcMessage.parse(protocol.handshake())
    var wrong_version = parse_json(handshake_result(handshake.id))
    var wrong_result = wrong_version.get("result")
    wrong_result.set("version", JsonValue.integer(99))
    wrong_version.set("result", wrong_result^)
    with assert_raises():
        protocol.accept_handshake(wrong_version.serialize())
    assert_equal(protocol.state, PluginProtocol.FAILED)

    protocol = PluginProtocol()
    handshake = RpcMessage.parse(protocol.handshake())
    with assert_raises():
        protocol.accept_handshake(handshake_result(handshake.id + 1))
    assert_equal(protocol.state, PluginProtocol.FAILED)

    protocol = PluginProtocol()
    handshake = RpcMessage.parse(protocol.handshake())
    with assert_raises():
        protocol.accept_handshake(
            error_result(handshake.id, ERROR_INVALID_PARAMS, "bad handshake")
        )
    assert_equal(protocol.state, PluginProtocol.FAILED)


def test_transport_codec_and_client_orchestration() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "fixture"))
    var metadata = PluginRegistration("fixture", "1.0.0")
    transport.enqueue_fixture_response(registration_result(2, metadata))
    transport.enqueue_fixture_response(
        invoke_result(3, parse_json("{\"content\":\"echo\"}"))
    )
    transport.enqueue_fixture_response(shutdown_result(4))

    var client = PluginClient(transport^)
    client.connect("codec-test")
    assert_true(client.is_ready())
    assert_equal(len(client.transport.fixture_writes), 2)
    assert_true(client.transport.fixture_writes[0].endswith("\n"))
    var handshake = RpcMessage.parse(client.transport.fixture_writes[0])
    assert_equal(handshake.method, METHOD_HANDSHAKE)
    assert_equal(handshake.payload.get("host").string_value, "codec-test")
    var registration = RpcMessage.parse(client.transport.fixture_writes[1])
    assert_equal(registration.method, METHOD_REGISTER)

    var result = client.invoke("tool", "echo", JsonValue.object())
    assert_equal(result.get("content").string_value, "echo")
    var invoke = RpcMessage.parse(client.transport.fixture_writes[2])
    assert_equal(invoke.method, METHOD_INVOKE)
    assert_equal(invoke.payload.get("name").string_value, "echo")

    client.shutdown()
    assert_equal(client.protocol.state, PluginProtocol.CLOSED)
    var shutdown = RpcMessage.parse(client.transport.fixture_writes[3])
    assert_equal(shutdown.method, METHOD_SHUTDOWN)


def test_client_reconnects_after_shutdown() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "first"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("first", "1.0.0"))
    )
    transport.enqueue_fixture_response(shutdown_result(3))
    transport.enqueue_fixture_response(handshake_result(1, "second"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("second", "2.0.0"))
    )
    var client = PluginClient(transport^)
    client.connect()
    client.shutdown()
    client.reconnect()
    assert_true(client.is_ready())
    assert_equal(client.protocol.registration.value().name, "second")


def test_transport_cancel_terminates_owned_child() raises:
    var executable = PluginExecutable("/bin/sh")
    executable.add_argument("-c")
    executable.add_argument("sleep 30")
    var transport = PluginTransport.spawn(executable)
    assert_true(transport.pid > 0)
    transport.cancel()
    assert_equal(Int(transport.pid), -1)
    assert_equal(Int(transport.write_fd), -1)
    assert_equal(Int(transport.read_fd), -1)


def test_transport_codec_rejects_unconnected_send() raises:
    var transport = PluginTransport()
    with assert_raises():
        _ = transport.send_line("{\"jsonrpc\":\"2.0\"}")
    assert_equal(len(transport.fixture_writes), 1)
    assert_true(transport.fixture_writes[0].endswith("\n"))


def test_malformed_messages_and_registration() raises:
    with assert_raises():
        _ = RpcMessage.parse("not json")
    with assert_raises():
        _ = RpcMessage.parse("{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":null}")
    with assert_raises():
        _ = RpcMessage.parse(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":{}}"
        )

    var protocol = PluginProtocol()
    var handshake = RpcMessage.parse(protocol.handshake())
    protocol.accept_handshake(handshake_result(handshake.id))
    var register = RpcMessage.parse(protocol.registration_request())
    with assert_raises():
        protocol.accept_registration(invoke_result(register.id, JsonValue.object()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
