from mochi.json import JsonValue, parse_json
from mochi.plugin import (
    ERROR_INTERNAL,
    ERROR_INVALID_PARAMS,
    ERROR_INVALID_REQUEST,
    ERROR_INVALID_STATE,
    ERROR_INVOKE,
    ERROR_METHOD_NOT_FOUND,
    ERROR_PARSE,
    ERROR_PROTOCOL,
    METHOD_HANDSHAKE,
    PluginProtocol,
    PluginRegistration,
    RpcMessage,
)
from mochi.plugin_sdk import (
    PluginHandler,
    PluginServer,
    _bounded_response,
    _read_line,
    _write_all,
)
from std.ffi import c_int
from std.sys._libc import close, pipe
from std.testing import TestSuite, assert_equal, assert_raises, assert_true


struct EchoHandler(Movable, PluginHandler):
    var invokes: Int
    var stopped: Bool
    var fail_invoke: Bool
    var invalid_registration: Bool

    def __init__(
        out self,
        fail_invoke: Bool = False,
        invalid_registration: Bool = False,
    ):
        self.invokes = 0
        self.stopped = False
        self.fail_invoke = fail_invoke
        self.invalid_registration = invalid_registration

    def registration(self) raises -> PluginRegistration:
        var registration = PluginRegistration("echo", "1.0.0")
        registration.tools.append(
            parse_json(
                '{"name":"echo","description":"Echo JSON arguments",'
                '"schema":{"type":"object"}}'
            )
        )
        registration.commands.append(parse_json('{"name":"hello"}'))
        if self.invalid_registration:
            registration.tools = JsonValue.object()
        return registration^

    def invoke(
        mut self, kind: String, name: String, var arguments: JsonValue
    ) raises -> JsonValue:
        if self.fail_invoke:
            raise Error("scripted invocation failure")
        self.invokes += 1
        var result = JsonValue.object()
        result.set("kind", JsonValue.string(kind))
        result.set("name", JsonValue.string(name))
        result.set("arguments", arguments^)
        return result^

    def shutdown(mut self) raises:
        self.stopped = True


def _error_code(line: String) raises -> Int:
    var message = RpcMessage.parse(line)
    assert_equal(message.kind, RpcMessage.ERROR)
    return message.error.code


def _ready_server() raises -> PluginServer[EchoHandler]:
    var server = PluginServer[EchoHandler](EchoHandler())
    var host = PluginProtocol()
    host.accept_handshake(server.handle_line(host.handshake("sdk-test")))
    host.accept_registration(server.handle_line(host.registration_request()))
    assert_true(server.is_ready())
    return server^


def test_server_lifecycle_matches_host_protocol() raises:
    var server = PluginServer[EchoHandler](EchoHandler())
    var host = PluginProtocol()

    host.accept_handshake(server.handle_line(host.handshake("sdk-test")))
    assert_equal(server.state, PluginServer[EchoHandler].HANDSHAKEN)

    host.accept_registration(server.handle_line(host.registration_request()))
    assert_true(server.is_ready())
    assert_equal(host.registration.value().name, "echo")
    assert_equal(len(host.registration.value().tools.array_value), 1)
    assert_equal(
        host.registration.value()
        .commands.array_value[0]
        .get("name")
        .string_value,
        "/hello",
    )

    var arguments = parse_json('{"text":"hello"}')
    var response = server.handle_line(host.invoke("tool", "echo", arguments^))
    var result = host.accept_invoke(response)
    assert_equal(result.get("kind").string_value, "tool")
    assert_equal(result.get("name").string_value, "echo")
    assert_equal(result.get("arguments").get("text").string_value, "hello")
    assert_equal(server.handler.invokes, 1)

    host.accept_shutdown(server.handle_line(host.shutdown()))
    assert_true(server.is_closed())
    assert_true(server.handler.stopped)


def test_strict_order_and_unknown_methods() raises:
    var server = PluginServer[EchoHandler](EchoHandler())
    var register = RpcMessage.request(1, "plugin/register", JsonValue.object())
    assert_equal(
        _error_code(server.handle_line(register.to_line())), ERROR_INVALID_STATE
    )
    assert_equal(server.state, PluginServer[EchoHandler].NEW)

    var unknown = RpcMessage.request(2, "plugin/missing", JsonValue.object())
    assert_equal(
        _error_code(server.handle_line(unknown.to_line())),
        ERROR_METHOD_NOT_FOUND,
    )

    var host = PluginProtocol()
    host.accept_handshake(server.handle_line(host.handshake()))
    var duplicate = RpcMessage.request(3, METHOD_HANDSHAKE, JsonValue.object())
    assert_equal(
        _error_code(server.handle_line(duplicate.to_line())),
        ERROR_INVALID_STATE,
    )


def test_handshake_and_invoke_validation() raises:
    var server = PluginServer[EchoHandler](EchoHandler())
    var invalid = RpcMessage.request(1, METHOD_HANDSHAKE, JsonValue.array())
    assert_equal(
        _error_code(server.handle_line(invalid.to_line())), ERROR_INVALID_PARAMS
    )

    var params = JsonValue.object()
    params.set("protocol", JsonValue.string("other.protocol"))
    params.set("version", JsonValue.integer(1))
    params.set("host", JsonValue.string("host"))
    invalid = RpcMessage.request(2, METHOD_HANDSHAKE, params^)
    assert_equal(
        _error_code(server.handle_line(invalid.to_line())), ERROR_PROTOCOL
    )

    server = _ready_server()
    var invoke = RpcMessage.request(3, "plugin/invoke", JsonValue.object())
    assert_equal(
        _error_code(server.handle_line(invoke.to_line())), ERROR_INVALID_PARAMS
    )
    assert_true(server.is_ready())


def test_parse_response_registration_and_handler_errors() raises:
    var server = PluginServer[EchoHandler](EchoHandler())
    assert_equal(_error_code(server.handle_line("not-json")), ERROR_PARSE)
    assert_equal(
        _error_code(
            server.handle_line(RpcMessage.result(9, JsonValue.null()).to_line())
        ),
        ERROR_INVALID_REQUEST,
    )

    var invalid_server = PluginServer[EchoHandler](
        EchoHandler(invalid_registration=True)
    )
    var invalid_host = PluginProtocol()
    invalid_host.accept_handshake(
        invalid_server.handle_line(invalid_host.handshake())
    )
    var register = invalid_host.registration_request()
    assert_equal(
        _error_code(invalid_server.handle_line(register)), ERROR_INTERNAL
    )
    assert_equal(invalid_server.state, PluginServer[EchoHandler].FAILED)

    var failing = PluginServer[EchoHandler](EchoHandler(fail_invoke=True))
    var host = PluginProtocol()
    host.accept_handshake(failing.handle_line(host.handshake()))
    host.accept_registration(failing.handle_line(host.registration_request()))
    var request = host.invoke("tool", "echo", JsonValue.object())
    assert_equal(_error_code(failing.handle_line(request)), ERROR_INVOKE)
    assert_true(failing.is_ready())


def test_stdio_reader_batches_and_retains_following_lines() raises:
    var descriptors = List[c_int](length=2, fill=0)
    assert_equal(pipe(descriptors.unsafe_ptr()), 0)
    var writer = FileDescriptor(Int(descriptors[1]))
    writer.write_bytes("first\nsecond\n".as_bytes())
    _ = close(descriptors[1])

    var reader = FileDescriptor(Int(descriptors[0]))
    var buffered = List[UInt8]()
    var first = _read_line(reader, buffered)
    assert_true(first)
    assert_equal(first.value(), "first")
    assert_true(len(buffered) > 0)
    var second = _read_line(reader, buffered)
    assert_true(second)
    assert_equal(second.value(), "second")
    assert_true(not _read_line(reader, buffered))
    _ = close(descriptors[0])


def test_stdio_writer_advances_until_the_complete_frame_is_written() raises:
    var descriptors = List[c_int](length=2, fill=0)
    assert_equal(pipe(descriptors.unsafe_ptr()), 0)
    _write_all(Int(descriptors[1]), "chunked response\n", 3)
    _ = close(descriptors[1])

    var reader = FileDescriptor(Int(descriptors[0]))
    var buffered = List[UInt8]()
    var response = _read_line(reader, buffered)
    assert_true(response)
    assert_equal(response.value(), "chunked response")
    _ = close(descriptors[0])


def test_transport_rejects_oversized_request_and_bounds_response() raises:
    var bytes = List[UInt8](length=258, fill=UInt8(120))
    var response = _bounded_response(41, String(from_utf8=Span(bytes)), 256)
    assert_true(response.byte_length() <= 257)
    var message = RpcMessage.parse(response)
    assert_equal(message.id, 41)
    assert_equal(message.kind, RpcMessage.ERROR)
    assert_equal(message.error.code, ERROR_INTERNAL)

    var reader = FileDescriptor(-1)
    with assert_raises():
        _ = _read_line(reader, bytes, 256)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
