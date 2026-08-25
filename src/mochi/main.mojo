from std.ffi import CStringSlice, c_int, c_pid_t, external_call
from std.os import Process
from std.sys import argv
from std.sys._libc import close, exit, pipe

from mochi.cli import (
    VERSION,
    _words,
    help_text,
    parse_args,
    read_stdin,
    standard_tool_definitions,
    validate_protocol_metadata,
)
from mochi.json import JsonValue, serialize_json
from mochi.mcp import McpClient, StdioTransport, StreamableHttpTransport
from mochi.permissions import PermissionEffect, PermissionManager
from mochi.plugin import PluginClient, PluginExecutable, PluginTransport
from mochi.provider import OpenAICompatibleProvider
from mochi.runtime import Runtime, RuntimeResult
from mochi.tools import ToolRegistry
from mochi.types import CancellationToken


def main() raises:
    var arguments = List[String]()
    var command_line = argv()
    for index in range(1, len(command_line)):
        arguments.append(String(command_line[index]))

    var config = parse_args(arguments^)
    if config.show_help:
        print(help_text(), end="")
        return
    if config.show_version:
        print("mochi", VERSION)
        return

    validate_protocol_metadata(config)
    var registry = ToolRegistry(".")
    var permissions = PermissionManager(
        PermissionEffect.prompt(), yolo=config.yolo
    )
    var runtime = Runtime(
        OpenAICompatibleProvider(config.provider_spec()),
        registry^,
        permissions^,
        config.model,
    )
    for definition in standard_tool_definitions():
        runtime.add_tool(definition.copy())

    # Keep every process/HTTP session alive for the complete runtime scope.
    var stdio_clients = List[McpClient]()
    var stdio_transports = List[StdioTransport]()
    var http_clients = List[McpClient]()
    var http_transports = List[StreamableHttpTransport]()
    var plugin_clients = List[PluginClient]()
    try:
        for endpoint in config.mcp_stdio:
            var transport = _spawn_stdio(_words(endpoint.value))
            var client = McpClient(endpoint.name)
            var capabilities = client.initialize(transport)
            var tools = client.list_tools(transport)
            print(
                "MCP", endpoint.name, "initialized; tools=", len(tools),
                "capabilities=", serialize_json(capabilities),
            )
            stdio_clients.append(client^)
            stdio_transports.append(transport^)
        for endpoint in config.mcp_http:
            var transport = StreamableHttpTransport(endpoint.value)
            var client = McpClient(endpoint.name)
            var capabilities = client.initialize(transport)
            var tools = client.list_tools(transport)
            print(
                "MCP", endpoint.name, "initialized; tools=", len(tools),
                "capabilities=", serialize_json(capabilities),
            )
            http_clients.append(client^)
            http_transports.append(transport^)
        for path in config.plugins:
            var client = PluginClient(_spawn_plugin(PluginExecutable(path)))
            client.connect()
            var registration = client.protocol.registration.value().copy()
            print(
                "Plugin", registration.name, registration.version,
                "initialized; tools=", len(registration.tools.array_value),
            )
            plugin_clients.append(client^)

        if config.print_mode and not config.prompt:
            config.prompt = Optional(read_stdin())
        if config.prompt:
            _run_prompt(runtime, config.prompt.value(), config.output_format)
        else:
            _interactive(runtime, config.output_format)
    except error:
        _cleanup(http_transports, plugin_clients)
        raise error
    _cleanup(http_transports, plugin_clients)


def _spawn_stdio(var command: List[String]) raises -> StdioTransport:
    if len(command) == 0:
        raise Error("MCP command is empty")
    var fds = _spawn_piped(command^)
    var transport = StdioTransport()
    transport.process = Process(child_pid=c_pid_t(fds[0]))
    transport.write_fd = Int32(fds[1])
    transport.read_fd = Int32(fds[2])
    return transport^


def _spawn_plugin(executable: PluginExecutable) raises -> PluginTransport:
    var fds = _spawn_piped(executable.command())
    var transport = PluginTransport()
    transport.pid = c_pid_t(fds[0])
    transport.write_fd = Int32(fds[1])
    transport.read_fd = Int32(fds[2])
    return transport^


def _spawn_piped(var command: List[String]) raises -> List[Int]:
    if len(command) == 0 or command[0] == "":
        raise Error("executable command is empty")
    var input_fds = List[c_int](length=2, fill=0)
    var output_fds = List[c_int](length=2, fill=0)
    if pipe(input_fds.unsafe_ptr()) != 0 or pipe(output_fds.unsafe_ptr()) != 0:
        raise Error("unable to create child process pipes")
    var pid = external_call["fork", c_pid_t]()
    if pid < 0:
        raise Error("unable to fork child process")
    if pid == 0:
        _ = external_call["dup2", c_int](input_fds[0], c_int(0))
        _ = external_call["dup2", c_int](output_fds[1], c_int(1))
        _ = close(input_fds[0])
        _ = close(input_fds[1])
        _ = close(output_fds[0])
        _ = close(output_fds[1])
        var child_argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
            length=len(command) + 1, fill={}
        )
        for i in range(len(command)):
            child_argv[i] = rebind[CStringSlice[ImmutAnyOrigin]](
                command[i].as_c_string_slice()
            )
        _ = external_call["execvp", c_int](
            command[0].as_c_string_slice(), child_argv.unsafe_ptr()
        )
        exit(c_int(127))
    _ = close(input_fds[0])
    _ = close(output_fds[1])
    return [Int(pid), Int(input_fds[1]), Int(output_fds[0])]


def _cleanup(
    mut http_transports: List[StreamableHttpTransport],
    mut plugin_clients: List[PluginClient],
):
    for i in range(len(http_transports)):
        try:
            http_transports[i].delete_session()
        except:
            pass
    for i in range(len(plugin_clients)):
        try:
            plugin_clients[i].shutdown()
        except:
            plugin_clients[i].cancel()


def _run_prompt(mut runtime: Runtime, prompt: String, output_format: String):
    var result = runtime.run(prompt, CancellationToken())
    _print_result(result, output_format)


def _interactive(mut runtime: Runtime, output_format: String) raises:
    while True:
        print("> ", end="")
        var line = _read_line()
        if not line:
            return
        var prompt = line.value()
        if prompt == "exit" or prompt == "quit":
            return
        if prompt != "":
            _run_prompt(runtime, prompt^, output_format)


def _read_line() raises -> Optional[String]:
    var reader = FileDescriptor(0)
    var result = String("")
    while True:
        var buffer = Array[Byte, 1](fill=0)
        var count = reader.read_bytes(buffer)
        if count <= 0:
            if result == "":
                return None
            return Optional(result^)
        if UInt8(buffer[0]) == 10:
            return Optional(result^)
        if UInt8(buffer[0]) != 13:
            result += String(buffer[0])


def _print_result(result: RuntimeResult, output_format: String):
    if output_format == "text":
        print(result.text)
        return
    var value = JsonValue.object()
    try:
        value.set("type", JsonValue.string("result"))
        value.set("text", JsonValue.string(result.text))
        value.set("stop_reason", JsonValue.string(result.stop_reason))
        value.set("turns", JsonValue.integer(result.turns))
        var usage = JsonValue.object()
        usage.set("input_tokens", JsonValue.integer(result.usage.input_tokens))
        usage.set("output_tokens", JsonValue.integer(result.usage.output_tokens))
        value.set("usage", usage^)
        print(serialize_json(value))
    except error:
        print("{\"type\":\"error\",\"message\":\"output serialization failed\"}")
