from std.ffi import CStringSlice, c_int, c_long, c_pid_t, external_call
from std.os import Process, getenv
from std.os.path import exists
from std.sys import argv
from std.sys._libc import close, exit, pipe

from mochi.acp import AcpMessage, AcpRuntimeServer
from mochi.cli import (
    DEFAULT_MODEL,
    DEFAULT_PROVIDER_URL,
    VERSION,
    CliConfig,
    _words,
    help_text,
    parse_args,
    read_stdin,
    standard_tool_definitions,
    validate_protocol_metadata,
)
from mochi.config import load_layered_config
from mochi.http import FlokiTransport
from mochi.json import JsonValue, serialize_json
from mochi.mcp import McpClient, StdioTransport, StreamableHttpTransport
from mochi.permissions import PermissionEffect, PermissionManager
from mochi.plugin import PluginClient, PluginExecutable, PluginTransport
from mochi.prompt import build_system_prompt, load_instruction_text
from mochi.provider import (
    OpenAICompatibleProvider,
    OpenAIOAuthCredentials,
    load_openai_oauth_credentials,
    openai_oauth_credentials_path,
    openai_device_login_with,
    refresh_openai_oauth_with,
    save_openai_oauth_credentials,
)
from mochi.runtime import Runtime, RuntimeResult
from mochi.session import Session, SessionStore
from mochi.storage import MakiId, SessionRef, StoragePaths
from mochi.tools import ToolRegistry
from mochi.types import CancellationToken
from mochi.ui import UiEvent, UiReducer, UiState
from mochi.workspace import InputHistory, NoteStore, project_id


def main() raises:
    var arguments = List[String]()
    var command_line = argv()
    for index in range(1, len(command_line)):
        arguments.append(String(command_line[index]))

    var config = parse_args(arguments^)
    var startup_cwd = getenv("PWD", ".")
    var startup_paths = StoragePaths.resolve()
    var layered = load_layered_config(
        startup_paths.config + "/config.json",
        startup_cwd + "/.maki/config.json",
    )
    if layered.model and config.model == DEFAULT_MODEL:
        config.model = layered.model.value()
    if layered.provider_url and config.provider_url == DEFAULT_PROVIDER_URL:
        config.provider_url = layered.provider_url.value()
    if layered.output_format and config.output_format == "text":
        config.output_format = layered.output_format.value()
    if layered.yolo and not config.yolo:
        config.yolo = layered.yolo.value()
    if config.acp:
        _run_acp(config, startup_cwd, startup_paths)
        return
    if config.show_help:
        print(help_text(), end="")
        return
    if config.show_version:
        print("mochi", VERSION)
        return
    if config.openai_oauth_login:
        var transport = FlokiTransport()
        _ = openai_device_login_with(transport, _now_ms())
        print("Authenticated successfully.")
        return

    validate_protocol_metadata(config)
    var registry = ToolRegistry(".")
    var permissions = PermissionManager(
        PermissionEffect.prompt(), yolo=config.yolo
    )
    var spec = config.provider_spec()
    var provider = OpenAICompatibleProvider(spec.copy())
    if config.openai_oauth:
        var credentials = load_openai_oauth_credentials()
        if credentials.expired(_now_ms()):
            var transport = FlokiTransport()
            credentials = refresh_openai_oauth_with(transport, credentials, _now_ms())
            save_openai_oauth_credentials(credentials)
        spec.account_id = credentials.account_id
        provider = OpenAICompatibleProvider(spec^)
        provider.set_oauth(credentials.oauth_state())
    var cwd = startup_cwd
    var paths = startup_paths.copy()
    var session_store = SessionStore(paths.state + "/sessions")
    var session: Session
    if config.session_id:
        var reference = SessionRef(config.session_id.value())
        session = session_store.load(reference.as_str())
        config.model = session.model
    elif config.continue_session:
        var latest = session_store.latest(cwd)
        if latest:
            session = latest.value().copy()
            config.model = session.model
        else:
            session = _new_session(config.model, cwd)
    else:
        session = _new_session(config.model, cwd)
    var runtime = Runtime(
        provider^,
        registry^,
        permissions^,
        config.model,
        max_turns=layered.max_turns.value() if layered.max_turns else 50,
    )
    runtime.set_messages(session.runtime_messages())
    runtime.set_system_prompt(
        build_system_prompt(
            cwd,
            config.model,
            _platform(),
            _date(),
            load_instruction_text(cwd),
        )
    )
    for definition in standard_tool_definitions():
        runtime.add_tool(definition.copy())

    try:
        for endpoint in config.mcp_stdio:
            var transport = _spawn_stdio(_words(endpoint.value))
            var client = McpClient(endpoint.name)
            var capabilities = client.initialize(transport)
            var tools = client.list_tools(transport)
            runtime.add_remote_tools(
                "mcp", endpoint.name, _json_array(tools)
            )
            print(
                "MCP", endpoint.name, "initialized; tools=", len(tools),
                "capabilities=", serialize_json(capabilities),
            )
            runtime.attach_mcp_stdio(endpoint.name, client^, transport^)
        for endpoint in config.mcp_http:
            var transport = StreamableHttpTransport(endpoint.value)
            var client = McpClient(endpoint.name)
            var capabilities = client.initialize(transport)
            var tools = client.list_tools(transport)
            runtime.add_remote_tools(
                "mcp", endpoint.name, _json_array(tools)
            )
            print(
                "MCP", endpoint.name, "initialized; tools=", len(tools),
                "capabilities=", serialize_json(capabilities),
            )
            runtime.attach_mcp_http(endpoint.name, client^, transport^)
        for path in config.plugins:
            var client = PluginClient(_spawn_plugin(PluginExecutable(path)))
            client.connect()
            var registration = client.protocol.registration.value().copy()
            runtime.add_remote_tools(
                "plugin", registration.name, registration.tools.copy()
            )
            print(
                "Plugin", registration.name, registration.version,
                "initialized; tools=", len(registration.tools.array_value),
            )
            runtime.attach_plugin(registration.name, client^)

        if config.print_mode and not config.prompt:
            config.prompt = Optional(read_stdin())
        if config.prompt:
            _run_prompt(
                runtime,
                session,
                session_store,
                config.prompt.value(),
                config.output_format,
            )
        else:
            var history = InputHistory(paths.state + "/input_history")
            history.load()
            var memories = NoteStore(
                paths.state
                + "/projects/"
                + project_id(cwd)
                + "/memories"
            )
            _interactive(
                runtime,
                session,
                session_store,
                history,
                memories,
                config.output_format,
            )
    except error:
        runtime.shutdown_remotes()
        raise error
    runtime.shutdown_remotes()


def _run_acp(config: CliConfig, cwd: String, paths: StoragePaths) raises:
    var permissions = PermissionManager(
        PermissionEffect.prompt(), yolo=config.yolo
    )
    var runtime = Runtime(
        OpenAICompatibleProvider(config.provider_spec()),
        ToolRegistry(cwd),
        permissions^,
        config.model,
    )
    runtime.set_system_prompt(
        build_system_prompt(
            cwd,
            config.model,
            _platform(),
            _date(),
            load_instruction_text(cwd),
        )
    )
    for definition in standard_tool_definitions():
        runtime.add_tool(definition.copy())
    var server = AcpRuntimeServer(
        runtime^, SessionStore(paths.state + "/sessions"), _now_ms()
    )
    while True:
        var line = _read_line()
        if not line:
            server.shutdown()
            return
        try:
            var request = AcpMessage.parse(line.value())
            for response in server.handle(request):
                print(response.line(), end="")
        except error:
            print(
                AcpMessage.failure(0, -32600, String(error)).line(),
                end="",
            )


def _platform() -> String:
    var value = getenv("OSTYPE", "")
    if value != "":
        return value
    return "unknown"


def _date() -> String:
    var seconds: c_long = 0
    _ = external_call["time", c_long](Pointer(to=seconds))
    return String(seconds)


def _json_array(values: List[JsonValue]) raises -> JsonValue:
    var result = JsonValue.array()
    for value in values:
        result.append(value.copy())
    return result^


def _now_ms() -> Int:
    var seconds: c_long = 0
    _ = external_call["time", c_long](Pointer(to=seconds))
    return Int(seconds) * 1000


def _spawn_stdio(var command: List[String]) raises -> StdioTransport:
    if len(command) == 0:
        raise Error("MCP command is empty")
    var fds = _spawn_piped(command^)
    var transport = StdioTransport()
    transport.process = Process(child_pid=c_pid_t(fds[0]))
    transport.pid = c_pid_t(fds[0])
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


def _new_session(model: String, cwd: String) raises -> Session:
    var now = _now_ms()
    var id = SessionRef.from_id(MakiId.generate()).as_str()
    return Session(id^, model, cwd, now)


def _run_prompt(
    mut runtime: Runtime,
    mut session: Session,
    store: SessionStore,
    prompt: String,
    output_format: String,
):
    var result = runtime.run(prompt, CancellationToken())
    try:
        session.update_from_result(
            result.messages, result.usage, runtime.model, _now_ms()
        )
        store.save(session)
    except error:
        print("Session save failed:", error)
    _print_result(result, output_format)


def _interactive(
    mut runtime: Runtime,
    mut session: Session,
    store: SessionStore,
    mut history: InputHistory,
    mut memories: NoteStore,
    output_format: String,
) raises:
    var ui = UiState()
    while True:

        print("> ", end="")
        var line = _read_line()
        if not line:
            return
        var raw = String(line.value())
        history.add(String(raw.strip()))
        if raw.strip() == "exit" or raw.strip() == "quit":
            return
        _ = UiReducer.reduce(ui, UiEvent.edit(raw^))
        var action = UiReducer.reduce(ui, UiEvent.submit())
        if action.is_none():
            continue
        if action.is_command():
            var command = "/" + action.name
            if action.text != "":
                command += " " + action.text
            if action.name == "login":
                _interactive_login(runtime)
            elif action.name == "model":
                _interactive_model(runtime, command^)
            elif action.name == "memory":
                _interactive_memory(memories, action.text)
            elif action.name == "help":
                print(
                    "Commands: /login, /model [MODEL], /memory [list|read|write|delete], /help, exit"
                )
            else:
                print("Unknown command:", action.name)
            continue
        _run_prompt(runtime, session, store, action.text, output_format)
        _ = UiReducer.reduce(ui, UiEvent.complete())


def _interactive_memory(mut memories: NoteStore, arguments: String):
    try:
        var parts = arguments.split(" ")
        var command = "list" if arguments == "" else String(parts[0])
        if command == "list":
            for name in memories.list():
                print(name)
        elif command == "read" and len(parts) >= 2:
            print(memories.read(String(parts[1])))
        elif command == "delete" and len(parts) >= 2:
            memories.delete(String(parts[1]))
        elif command == "write" and len(parts) >= 3:
            var content = String("")
            for index in range(2, len(parts)):
                if content != "":
                    content += " "
                content += String(parts[index])
            memories.write(String(parts[1]), content^)
        else:
            print("Usage: /memory [list|read NAME|write NAME TEXT|delete NAME]")
    except error:
        print("Memory command failed:", error)


def _interactive_login(mut runtime: Runtime):
    try:
        var path = openai_oauth_credentials_path()
        var credentials: OpenAIOAuthCredentials
        if exists(path):
            credentials = load_openai_oauth_credentials(path)
            if credentials.expired(_now_ms()):
                var transport = FlokiTransport()
                credentials = refresh_openai_oauth_with(
                    transport, credentials, _now_ms()
                )
                save_openai_oauth_credentials(credentials, path)
                print("OpenAI OAuth session refreshed.")
            else:
                print("Using cached OpenAI OAuth session.")
        else:
            var transport = FlokiTransport()
            credentials = openai_device_login_with(transport, _now_ms(), path)
            print("Authenticated successfully.")
        runtime.provider.inner.spec.responses_api = True
        runtime.provider.inner.spec.account_id = credentials.account_id
        runtime.provider.inner.set_oauth(credentials.oauth_state())
        if "codex" not in runtime.model:
            runtime.model = "gpt-5.3-codex"
        print("Model:", runtime.model)
    except error:
        print("Login failed:", error)


def _interactive_model(mut runtime: Runtime, command: String) raises:
    var requested = String(command.removeprefix("/model").strip())
    if requested != "":
        runtime.model = requested^
        print("Model:", runtime.model)
        return
    var models: List[String] = [
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex-mini",
    ]
    print("Current model:", runtime.model)
    for i in range(len(models)):
        print(String(i + 1) + ")", models[i])
    print("Choose a number or enter a model ID: ", end="")
    var selection = _read_line()
    if not selection:
        return
    var value = String(selection.value().strip())
    var index = _decimal(value)
    if index > 0 and index <= len(models):
        runtime.model = models[index - 1]
    elif value != "":
        runtime.model = value^
    print("Model:", runtime.model)


def _decimal(value: String) -> Int:
    if value == "":
        return -1
    var result = 0
    for cp in value.codepoints():
        var digit = Int(cp.to_u32()) - 48
        if digit < 0 or digit > 9:
            return -1
        result = result * 10 + digit
    return result


def _read_line() raises -> Optional[String]:
    var result = String("")
    while True:
        var byte = external_call["getchar", c_int]()
        if byte < 0:
            if result == "":
                return None
            return Optional(result^)
        if byte == 10:
            return Optional(result^)
        if byte != 13:
            result += chr(Int(byte))


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
