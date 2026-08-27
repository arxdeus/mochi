from std.ffi import CStringSlice, c_int, c_long, c_pid_t, c_size_t, external_call
from std.os import Process, getenv
from std.os.path import exists
from std.sys import argv
from std.sys._libc import close, exit, pipe

from mochi.acp import AcpMessage, AcpRuntimeServer
from mochi.cli import (
    DEFAULT_MODEL,
    DEFAULT_PROVIDER,
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
from mochi.mcp import (
    McpClient,
    McpOAuthState,
    StdioTransport,
    StreamableHttpTransport,
    begin_mcp_oauth_with,
    complete_mcp_oauth_with,
)
from mochi.ops import plan_update, replace_from_download, restore_backup
from mochi.permissions import PermissionAnswer, PermissionEffect, PermissionManager
from mochi.plugin import PluginClient, PluginExecutable, PluginTransport
from mochi.prompt import build_system_prompt, load_instruction_text
from mochi.provider import (
    AnthropicProviderSpec,
    GeminiProviderSpec,
    builtin_model_catalog,
    builtin_provider_registry,
    OpenAICompatibleProvider,
    ProductionProvider,
    copilot_discovered_endpoint,
    copilot_guess_endpoint,
    copilot_discovery_request,
    copilot_provider_spec,
    OpenAIOAuthCredentials,
    find_model_info,
    load_openai_oauth_credentials,
    openai_oauth_credentials_path,
    openai_device_login_with,
    refresh_openai_oauth_with,
    save_openai_oauth_credentials,
)
from mochi.runtime import Runtime, RuntimeResult, _runtime_model
from mochi.session import Session, SessionStore
from mochi.storage import (
    AuthRecord,
    MakiId,
    McpAuthData,
    SessionRef,
    StoragePaths,
    delete_mcp_auth,
    load_mcp_auth,
    load_provider_credentials,
    save_mcp_auth,
    save_provider_credentials,
)
from mochi.tools import ToolRegistry
from mochi.types import CancellationToken, Message
from mochi.ui import (
    UiEvent,
    UiReducer,
    UiState,
    command_completion,
    command_help_lines,
    command_matches,
    search_result_lines,
    decode_sgr_mouse,
)
from mochi.workspace import InputHistory, NoteStore, PreferenceStore, project_id


def main() raises:
    var arguments = List[String]()
    var command_line = argv()
    for index in range(1, len(command_line)):
        arguments.append(String(command_line[index]))

    var config = parse_args(arguments^)
    var startup_cwd = getenv("PWD", ".")
    var startup_paths = StoragePaths.resolve()
    if config.rollback:
        restore_backup(
            startup_paths.state + "/mochi_backup", String(command_line[0])
        )
        print("Restored previous version.")
        return
    if config.update_file:
        var latest = config.update_version.value()
        var plan = plan_update(VERSION, latest, String(command_line[0]))
        if not plan.update_available:
            print("Already up to date (v" + VERSION + ")")
            return
        replace_from_download(
            config.update_file.value(),
            plan.executable,
            startup_paths.state + "/mochi_backup",
        )
        print("Updated successfully to v" + latest + ".")
        print("To restore: mochi rollback")
        return
    var layered = load_layered_config(
        startup_paths.config + "/config.json",
        startup_cwd + "/.maki/config.json",
    )
    if layered.model and config.model == DEFAULT_MODEL:
        config.model = layered.model.value()
    if layered.provider and config.provider == DEFAULT_PROVIDER:
        config.provider = layered.provider.value()
    if layered.provider_url and config.provider_url == DEFAULT_PROVIDER_URL:
        config.provider_url = layered.provider_url.value()
    config.normalize_provider_url()
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
    var provider = _production_provider(config)
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
    runtime.restore_modes(session.meta)
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
            var saved_auth = load_mcp_auth(
                paths, endpoint.name, endpoint.value, _now_ms() // 1000
            )
            if saved_auth and saved_auth.value().tokens:
                var auth = saved_auth.value().copy()
                transport.apply_oauth(
                    McpOAuthState(
                        auth.tokens.value().copy(),
                        auth.token_endpoint.value() if auth.token_endpoint else "",
                        auth.client_id,
                        auth.client_secret.value() if auth.client_secret else "",
                        endpoint.value,
                    )
                )
            var client = McpClient(endpoint.name)
            try:
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
            except error:
                var reason = String(error)
                runtime.attach_mcp_http(endpoint.name, client^, transport^)
                if "status 401" in reason:
                    _ = runtime.mark_mcp_http_error(endpoint.name, "needs auth")
                    print("MCP", endpoint.name, "needs authentication.")
                else:
                    _ = runtime.mark_mcp_http_error(endpoint.name, "error: " + reason)
                    print("MCP", endpoint.name, "failed:", reason)
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
        runtime.apply_plugin_prompt_hints()

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
            var preferences = PreferenceStore(paths.state + "/preferences.json")
            preferences.load()
            _interactive(
                runtime,
                session,
                session_store,
                history,
                memories,
                preferences,
                paths,
                config.output_format,
            )
    except error:
        runtime.shutdown_remotes()
        raise error
    runtime.shutdown_remotes()


def _production_provider(config: CliConfig) raises -> ProductionProvider:
    var info = find_model_info(config.model)
    var api_key = config.api_key()
    var saved_host: Optional[String] = None
    if api_key.strip() == "":
        var saved = load_provider_credentials(
            StoragePaths.resolve(), config.provider
        )
        if saved:
            api_key = saved.value().api_key
            saved_host = saved.value().host.copy()
    var provider_url = config.provider_url
    if saved_host:
        provider_url = saved_host.value()
    if config.provider == "anthropic":
        return ProductionProvider(
            AnthropicProviderSpec(provider_url, api_key),
            FlokiTransport(),
            info,
        )
    if config.provider == "gemini":
        return ProductionProvider(
            GeminiProviderSpec(provider_url, api_key),
            FlokiTransport(),
            info,
        )
    if config.provider == "copilot":
        var token = api_key.copy()
        var host = String("github.com")
        if token.strip() == "":
            var saved = load_provider_credentials(
                StoragePaths.resolve(), "copilot"
            )
            if saved:
                token = saved.value().api_key
                if saved.value().host:
                    host = saved.value().host.value()
        if token.strip() == "":
            raise Error("not authenticated, set GH_COPILOT_TOKEN")
        var endpoint = config.provider_url
        if endpoint == "https://api.githubcopilot.com":
            try:
                var transport = FlokiTransport()
                endpoint = copilot_discovered_endpoint(
                    transport.perform(copilot_discovery_request(token, host))
                )
            except:
                endpoint = "https://api.githubcopilot.com"
        var dialect = copilot_guess_endpoint(config.model)
        if dialect == "messages":
            var spec = AnthropicProviderSpec(endpoint, token)
            spec.bearer_auth = True
            return ProductionProvider(spec^, FlokiTransport(), info)
        var spec = copilot_provider_spec(endpoint, token)
        spec.responses_api = dialect == "responses"
        return ProductionProvider(OpenAICompatibleProvider(spec^), info)
    var spec = config.provider_spec()
    spec.base_url = provider_url
    if len(spec.api_keys) == 0 and api_key != "":
        spec.add_api_key(api_key)
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
    return ProductionProvider(provider^, info)


def _run_acp(config: CliConfig, cwd: String, paths: StoragePaths) raises:
    var permissions = PermissionManager(
        PermissionEffect.prompt(), yolo=config.yolo
    )
    var runtime = Runtime(
        _production_provider(config),
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
    var cancel = CancellationToken()
    cancel.activate_sigint()
    var result = runtime.run(prompt, cancel^)
    CancellationToken.deactivate_sigint()
    try:
        session.update_from_result(
            result.messages, result.usage, runtime.model, _now_ms()
        )
        runtime.persist_subagents(session)
        session.meta = runtime.save_modes(session.meta)
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
    mut preferences: PreferenceStore,
    paths: StoragePaths,
    output_format: String,
) raises:
    var ui = UiState()
    ui.set_history(history.entries.copy())
    ui.set_transcript(runtime.messages)
    ui.set_extension_commands(runtime.plugin_command_names())
    while True:
        var line = _read_interactive_line(ui)
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
            if action.name == "exit":
                return
            elif action.name == "reload":
                try:
                    print("Reloaded executable extensions:", runtime.reload_plugins())
                    ui.set_extension_commands(runtime.plugin_command_names())
                except error:
                    print("Reload failed:", error)
            elif action.name == "yolo":
                runtime.permissions.yolo = not runtime.permissions.yolo
                if runtime.permissions.yolo:
                    print("YOLO mode enabled.")
                else:
                    print("YOLO mode disabled.")
            elif action.name == "thinking":
                if runtime.set_thinking(action.text):
                    session.meta = runtime.save_modes(session.meta)
                    store.save(session)
                    print("Thinking:", runtime.options.thinking.display())
                elif not _runtime_model(
                    runtime.model,
                    runtime.provider.name,
                    runtime.provider.model_info,
                ).supports_thinking():
                    print("Thinking requires a model that supports it")
                else:
                    print(
                        "Usage: /thinking [off|adaptive|minimal|low|medium|high|xhigh|max|<budget>]"
                    )
            elif action.name == "fast":
                var fast = not runtime.options.fast
                if runtime.set_fast(fast):
                    session.meta = runtime.save_modes(session.meta)
                    store.save(session)
                    if fast:
                        print("Fast mode: on")
                    else:
                        print("Fast mode: off")
                else:
                    print(
                        "Fast mode requires an Anthropic Opus 4.6+ model (API only)"
                    )
            elif action.name == "workflow":
                var workflow = runtime.toggle_workflow()
                session.meta = runtime.save_modes(session.meta)
                store.save(session)
                if workflow:
                    print("Workflow mode: on")
                else:
                    print("Workflow mode: off")
            elif action.name == "cd":
                if _interactive_cd(runtime, session, action.text):
                    store.save(session)
            elif action.name == "btw":
                _interactive_btw(runtime, session, action.text)
            elif action.name == "tasks":
                _interactive_tasks(session, ui)
            elif action.name == "mcp":
                _interactive_mcp(runtime, ui, paths)
            elif action.name == "theme":
                _interactive_theme(preferences, ui)
            elif action.name == "login":
                _interactive_login(runtime, ui, paths)
            elif action.name == "model":
                _interactive_model(runtime, command^, ui)
                session.model = runtime.model
            elif action.name == "memory":
                _interactive_memory(memories, action.text)
            elif action.name == "compact":
                if runtime.compact_if_needed(force=True):
                    session.replace_runtime_messages(runtime.messages)
                    store.save(session)
                    print("Conversation compacted.")
                else:
                    print("Nothing to compact.")
            elif action.name == "new" or action.name == "clear":
                session = _new_session(runtime.model, session.cwd)
                runtime.set_messages(List[Message]())
                ui = UiState()
                ui.set_history(history.entries.copy())
                ui.set_transcript(runtime.messages)
                print("Started session:", session.id)
            elif action.name == "usage":
                _interactive_usage(session, runtime)
            elif action.name == "queue":
                _interactive_queue(runtime)
            elif action.name == "help":
                _interactive_help()
            else:
                try:
                    print(runtime.invoke_plugin_command(action.name, action.text))
                except error:
                    print("Unknown command:", action.name, "(" + String(error) + ")")
            continue
        _run_prompt(runtime, session, store, action.text, output_format)
        if _interactive_permissions(runtime):
            _run_resume(runtime, session, store, output_format)
        ui.set_transcript(runtime.messages)
        _ = UiReducer.reduce(ui, UiEvent.complete())


def _interactive_permissions(mut runtime: Runtime) raises -> Bool:
    var resolved = False
    while True:
        var pending = runtime.take_pending_permission()
        if not pending:
            return resolved
        var permission = pending.value().copy()
        print("Permission required for", permission.tool)
        for scope in permission.scopes:
            print("  ", scope)
        print("[y] allow once, [a] allow for session, [n] deny: ", end="")
        var answer = _read_line()
        if not answer:
            _ = runtime.resolve_permission(
                permission, PermissionAnswer.deny()
            )
            return resolved
        var choice = String(answer.value().strip()).lower()
        if choice == "a" or choice == "always":
            _ = runtime.resolve_permission(
                permission, PermissionAnswer.allow_session()
            )
        elif choice == "y" or choice == "yes":
            _ = runtime.resolve_permission(
                permission, PermissionAnswer.allow_once()
            )
        else:
            _ = runtime.resolve_permission(permission, PermissionAnswer.deny())
        resolved = True


def _run_resume(
    mut runtime: Runtime,
    mut session: Session,
    store: SessionStore,
    output_format: String,
):
    var cancel = CancellationToken()
    cancel.activate_sigint()
    var result = runtime.resume(cancel^)
    CancellationToken.deactivate_sigint()
    try:
        session.update_from_result(
            result.messages, result.usage, runtime.model, _now_ms()
        )
        runtime.persist_subagents(session)
        session.meta = runtime.save_modes(session.meta)
        store.save(session)
    except error:
        print("Session save failed:", error)
    _print_result(result, output_format)


def _interactive_theme(
    mut preferences: PreferenceStore, mut ui: UiState
) raises:
    comptime themes = [
        "ayu_dark", "ayu_light", "ayu_mirage", "carbonfox",
        "catppuccin_frappe", "catppuccin_latte", "catppuccin_macchiato",
        "catppuccin_mocha", "dark_daltonized", "dracula", "everforest_dark",
        "fleet_dark", "github_dark", "gruvbox", "gruvbox_light", "kanagawa",
        "kanagawa_ink", "kanagawa_plum", "material_darker", "monokai_pro",
        "night_owl", "nightfox", "nord", "onedark", "rose_pine",
        "rose_pine_dawn", "rose_pine_midnight", "rose_pine_moon",
        "solarized_dark", "solarized_light", "tokyonight", "vscode_dark_plus",
        "zenburn",
    ]
    var current = String("dracula")
    var saved = preferences.get("theme")
    if saved and saved.value().kind == JsonValue.STRING:
        current = saved.value().string_value
    var items = String("")
    for theme in materialize[themes]():
        if items != "":
            items += "\n"
        items += ("1:" if theme == current else "0:") + theme
    _ = UiReducer.reduce(ui, UiEvent.picker_open("Themes", items))
    var raw_mode = external_call["mochi_terminal_enable_raw", c_int]()
    while ui.picker_name != "":
        _render_picker(ui)
        var byte = external_call["getchar", c_int]()
        if byte == 3 or byte == 4:
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 10 or byte == 13:
            current = ui.picker_items[ui.picker_selected]
            preferences.set("theme", JsonValue.string(current))
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 27:
            var bracket = external_call["mochi_terminal_read_byte", c_int, c_int](20)
            if bracket == 91:
                var key = external_call["mochi_terminal_read_byte", c_int, c_int](20)
                if key == 65:
                    _ = UiReducer.reduce(ui, UiEvent.picker_previous())
                elif key == 66:
                    _ = UiReducer.reduce(ui, UiEvent.picker_next())
            else:
                _ = UiReducer.reduce(ui, UiEvent.picker_close())
    if raw_mode > 0:
        external_call["mochi_terminal_disable_raw", NoneType]()
    print("\r\x1b[2KTheme: " + current)


def _interactive_mcp(
    mut runtime: Runtime, mut ui: UiState, paths: StoragePaths
) raises:
    var items = runtime.mcp_picker_items()
    if items == "":
        print("MCP servers:")
        print("  No MCP servers configured.")
        return
    _ = UiReducer.reduce(ui, UiEvent.picker_open("MCP Servers", items))
    var raw_mode = external_call["mochi_terminal_enable_raw", c_int]()
    var authenticate = String("")
    var logout = String("")
    var reconnect = String("")
    while ui.picker_name != "":
        _render_picker(ui)
        var byte = external_call["getchar", c_int]()
        if byte == 3 or byte == 4:
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 10 or byte == 13 or byte == 32:
            var action = UiReducer.reduce(ui, UiEvent.picker_toggle())
            if action.is_picker_toggle():
                _ = runtime.set_mcp_enabled(action.name, action.text == "on")
        elif byte == 97:
            authenticate = ui.picker_items[ui.picker_selected]
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 108:
            logout = ui.picker_items[ui.picker_selected]
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 114:
            reconnect = ui.picker_items[ui.picker_selected]
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 27:
            var bracket = external_call["mochi_terminal_read_byte", c_int, c_int](20)
            if bracket == 91:
                var key = external_call["mochi_terminal_read_byte", c_int, c_int](20)
                if key == 65:
                    _ = UiReducer.reduce(ui, UiEvent.picker_previous())
                elif key == 66:
                    _ = UiReducer.reduce(ui, UiEvent.picker_next())
            else:
                _ = UiReducer.reduce(ui, UiEvent.picker_close())
    if raw_mode > 0:
        external_call["mochi_terminal_disable_raw", NoneType]()
    print("\r\x1b[2K", end="")
    if authenticate != "":
        _authenticate_mcp(runtime, paths, authenticate)
    elif reconnect != "":
        try:
            var count = runtime.reconnect_mcp_http(reconnect)
            print("MCP", reconnect, "reconnected; tools=", count)
        except error:
            _ = runtime.mark_mcp_http_error(reconnect, "error: " + String(error))
            print("MCP", reconnect, "reconnect failed:", error)
    elif logout != "":
        var url = runtime.mcp_http_url(logout)
        if not url:
            print("MCP OAuth is only available for HTTP servers.")
            return
        delete_mcp_auth(paths, logout)
        _ = runtime.clear_mcp_oauth(logout)
        print("MCP", logout, "logged out.")


def _authenticate_mcp(
    mut runtime: Runtime, paths: StoragePaths, server_name: String
) raises:
    var server_url = runtime.mcp_http_url(server_name)
    if not server_url:
        print("MCP OAuth is only available for HTTP servers.")
        return
    var bound_port: c_int = 0
    var listener = external_call[
        "mochi_oauth_callback_bind", c_int, c_int, Pointer[mut=True, c_int, MutAnyOrigin]
    ](8765, rebind[Pointer[mut=True, c_int, MutAnyOrigin]](Pointer(to=bound_port)))
    if listener < 0:
        print("Unable to start MCP OAuth callback listener.")
        return
    var redirect_uri = "http://127.0.0.1:" + String(bound_port) + "/callback"
    var existing = load_mcp_auth(
        paths, server_name, server_url.value(), _now_ms() // 1000
    )
    var client_id = String("")
    var client_secret = String("")
    if existing and existing.value().redirect_uri and existing.value().redirect_uri.value() == redirect_uri:
        client_id = existing.value().client_id
        if existing.value().client_secret:
            client_secret = existing.value().client_secret.value()
    var transport = FlokiTransport()
    var flow = begin_mcp_oauth_with(
        transport,
        server_url.value(),
        redirect_uri,
        client_id=client_id,
        client_secret=client_secret,
    )
    print("Open this URL in your browser:\n\n  " + flow.authorization_url + "\n")
    _ = external_call[
        "mochi_open_browser", c_int, CStringSlice[ImmutAnyOrigin]
    ](rebind[CStringSlice[ImmutAnyOrigin]](flow.authorization_url.as_c_string_slice()))
    print("Waiting for callback on " + redirect_uri + "...")
    print("Or paste the complete redirect URL here:")
    var callback = List[UInt8](length=8192, fill=0)
    var status = external_call[
        "mochi_oauth_callback_wait", c_int, c_int, Pointer[mut=True, UInt8, MutAnyOrigin], c_size_t, c_int
    ](
        listener,
        rebind[Pointer[mut=True, UInt8, MutAnyOrigin]](callback.unsafe_ptr()),
        c_size_t(len(callback)),
        300,
    )
    if status < 0:
        print("MCP OAuth authorization timed out.")
        return
    var callback_text = String(String(unsafe_from_utf8=Span(callback)).strip("\0"))
    var tokens = complete_mcp_oauth_with(
        transport, flow, callback_text, _now_ms()
    )
    var data = McpAuthData(
        server_url.value(),
        Optional(tokens.copy()),
        flow.client_id,
        Optional(flow.client_secret) if flow.client_secret != "" else None,
        Optional(flow.client_secret_expires_at) if flow.client_secret_expires_at > 0 else None,
        Optional(flow.redirect_uri),
        Optional(flow.token_endpoint),
    )
    save_mcp_auth(paths, server_name, data)
    _ = runtime.apply_mcp_oauth(
        server_name,
        McpOAuthState(
            tokens^,
            flow.token_endpoint,
            flow.client_id,
            flow.client_secret,
            flow.server_url,
        ),
    )
    try:
        var count = runtime.reconnect_mcp_http(server_name)
        print("MCP", server_name, "authenticated; tools=", count)
    except error:
        _ = runtime.mark_mcp_http_error(server_name, "error: " + String(error))
        print("MCP", server_name, "authenticated but reconnect failed:", error)


def _render_picker(ui: UiState):
    print("\r\x1b[2K" + ui.picker_name + ": ", end="")
    if len(ui.picker_items) > 0:
        var selected = ui.picker_selected
        var toggle = "[x] " if ui.picker_enabled[selected] else "[ ] "
        print(
            toggle + ui.picker_items[selected] + "  " + String(selected + 1)
            + "/" + String(len(ui.picker_items)) + "  Enter toggle · Esc close",
            end="",
        )


def _interactive_tasks(session: Session, mut ui: UiState) raises:
    var names = session.task_names()
    var items = String("")
    for name in names:
        if items != "":
            items += "\n"
        items += "0:" + name
    _ = UiReducer.reduce(ui, UiEvent.picker_open("Tasks", items))
    var selected = -1
    var raw_mode = external_call["mochi_terminal_enable_raw", c_int]()
    while ui.picker_name != "":
        _render_picker(ui)
        var byte = external_call["getchar", c_int]()
        if byte == 3 or byte == 4:
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 10 or byte == 13:
            selected = ui.picker_selected
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 27:
            var bracket = external_call["mochi_terminal_read_byte", c_int, c_int](20)
            if bracket == 91:
                var key = external_call["mochi_terminal_read_byte", c_int, c_int](20)
                if key == 65:
                    _ = UiReducer.reduce(ui, UiEvent.picker_previous())
                elif key == 66:
                    _ = UiReducer.reduce(ui, UiEvent.picker_next())
            else:
                _ = UiReducer.reduce(ui, UiEvent.picker_close())
    if raw_mode > 0:
        external_call["mochi_terminal_disable_raw", NoneType]()
    print("\r\x1b[2K", end="")
    if selected < 0:
        return
    var messages = session.task_messages(selected)
    print("Task:", names[selected])
    if len(messages) == 0:
        print("  No messages.")
    for message in messages:
        print(message.role + ": " + message.content)


def _interactive_cd(
    mut runtime: Runtime, mut session: Session, arguments: String
) -> Bool:
    var path = String(arguments.strip())
    var home = getenv("HOME", "")
    if path == "":
        path = home
    elif path == "~":
        path = home
    elif path.startswith("~/"):
        path = home + "/" + String(path.removeprefix("~/"))
    if path == "":
        print("cd: home directory is not set")
        return False
    var resolved = List[UInt8](length=4096, fill=0)
    var status = external_call[
        "mochi_change_directory", c_int, CStringSlice[ImmutAnyOrigin], Pointer[mut=True, UInt8, MutAnyOrigin], c_size_t
    ](
        rebind[CStringSlice[ImmutAnyOrigin]](path.as_c_string_slice()),
        rebind[Pointer[mut=True, UInt8, MutAnyOrigin]](
            resolved.unsafe_ptr()
        ),
        c_size_t(len(resolved)),
    )
    if status != 0:
        print("cd: unable to change directory (errno " + String(status) + ")")
        return False
    var length = 0
    while length < len(resolved) and resolved[length] != 0:
        length += 1
    var cwd = String(unsafe_from_utf8=Span(resolved)[0:length])
    runtime.tools.cwd = cwd
    session.cwd = cwd
    print("cd", path)
    return True


def _interactive_btw(
    mut runtime: Runtime, session: Session, question: String
):
    var trimmed = String(question.strip())
    if trimmed == "":
        print("Usage: /btw <question>")
        return
    var result = runtime.ask_btw(trimmed, session.id)
    if result.startswith("Error: "):
        print(result)
    else:
        print("/btw")
        print(result)


def _interactive_help():
    print("Commands:")
    for line in command_help_lines():
        print("  " + line)


def _interactive_usage(session: Session, runtime: Runtime):
    var input_tokens = 0
    var output_tokens = 0
    if session.token_usage.kind == JsonValue.OBJECT:
        try:
            input_tokens = session.token_usage.get("input_tokens").int_value
            output_tokens = session.token_usage.get("output_tokens").int_value
        except:
            pass
    print("Model:", runtime.model)
    print("Input tokens:", input_tokens)
    print("Output tokens:", output_tokens)
    print("Compactions:", runtime.compactions)
    print("Retries:", runtime.retries)
    print("Messages:", len(runtime.messages))


def _interactive_queue(runtime: Runtime):
    print("Queued inputs:", runtime.queued_input_count())
    print("Queued compactions:", runtime.queued_compaction_count())
    for i in range(len(runtime.queued_inputs)):
        print(String(i + 1) + ")", runtime.queued_inputs[i])


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


def _interactive_login(
    mut runtime: Runtime, mut ui: UiState, paths: StoragePaths
) raises:
    var registry = builtin_provider_registry()
    var names = registry.names()
    names.append("openai-oauth")
    var items = String("")
    for name in names:
        if items != "":
            items += "\n"
        items += "0:" + name
    _ = UiReducer.reduce(ui, UiEvent.picker_open("Login", items))
    var selected = String("")
    var raw_mode = external_call["mochi_terminal_enable_raw", c_int]()
    while ui.picker_name != "":
        _render_picker(ui)
        var byte = external_call["getchar", c_int]()
        if byte == 3 or byte == 4:
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 10 or byte == 13:
            selected = ui.picker_items[ui.picker_selected]
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 27:
            var bracket = external_call["mochi_terminal_read_byte", c_int, c_int](20)
            if bracket == 91:
                var key = external_call["mochi_terminal_read_byte", c_int, c_int](20)
                if key == 65:
                    _ = UiReducer.reduce(ui, UiEvent.picker_previous())
                elif key == 66:
                    _ = UiReducer.reduce(ui, UiEvent.picker_next())
            else:
                _ = UiReducer.reduce(ui, UiEvent.picker_close())
    if raw_mode > 0:
        external_call["mochi_terminal_disable_raw", NoneType]()
    print("\r\x1b[2K", end="")
    if selected == "":
        return
    if selected == "openai-oauth":
        _interactive_openai_oauth(runtime)
        return
    print("API key for " + selected + ": ", end="")
    var key = _read_line()
    if not key or String(key.value().strip()) == "":
        print("Login cancelled.")
        return
    var spec = registry.get(selected)
    save_provider_credentials(
        paths,
        selected,
        AuthRecord(String(key.value().strip()), Optional(spec.base_url)),
    )
    if runtime.provider.name == selected or (
        selected == "gemini" and runtime.provider.name == "google"
    ):
        runtime.provider.set_api_key(String(key.value().strip()))
    print("Saved credentials for", selected + ".")


def _interactive_openai_oauth(mut runtime: Runtime):
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
        runtime.provider.enable_openai_oauth(credentials)
        if "codex" not in runtime.model:
            runtime.model = "gpt-5.3-codex"
        print("Model:", runtime.model)
    except error:
        print("Login failed:", error)


def _interactive_model(
    mut runtime: Runtime, command: String, mut ui: UiState
) raises:
    var requested = String(command.removeprefix("/model").strip())
    if requested != "":
        runtime.model = requested^
        runtime.provider.set_model_info(find_model_info(runtime.model))
        print("Model:", runtime.model)
        return
    var items = String("")
    var current_index = 0
    var index = 0
    for model in builtin_model_catalog():
        if items != "":
            items += "\n"
        if model.id == runtime.model:
            current_index = index
        items += ("1:" if model.id == runtime.model else "0:") + model.id
        index += 1
    _ = UiReducer.reduce(ui, UiEvent.picker_open("Models", items))
    ui.picker_selected = current_index
    var raw_mode = external_call["mochi_terminal_enable_raw", c_int]()
    while ui.picker_name != "":
        _render_picker(ui)
        var byte = external_call["getchar", c_int]()
        if byte == 3 or byte == 4:
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 10 or byte == 13:
            runtime.model = ui.picker_items[ui.picker_selected]
            runtime.provider.set_model_info(find_model_info(runtime.model))
            _ = UiReducer.reduce(ui, UiEvent.picker_close())
        elif byte == 27:
            var bracket = external_call["mochi_terminal_read_byte", c_int, c_int](20)
            if bracket == 91:
                var key = external_call["mochi_terminal_read_byte", c_int, c_int](20)
                if key == 65:
                    _ = UiReducer.reduce(ui, UiEvent.picker_previous())
                elif key == 66:
                    _ = UiReducer.reduce(ui, UiEvent.picker_next())
            else:
                _ = UiReducer.reduce(ui, UiEvent.picker_close())
    if raw_mode > 0:
        external_call["mochi_terminal_disable_raw", NoneType]()
    print("\r\x1b[2KModel: " + runtime.model)


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


def _read_interactive_line(mut ui: UiState) raises -> Optional[String]:
    var raw_mode = external_call["mochi_terminal_enable_raw", c_int]()
    if raw_mode <= 0:
        print("> ", end="")
        return _read_line()
    _set_terminal_input_modes(True)
    _render_editor(ui)
    while True:
        var byte = external_call["getchar", c_int]()
        if byte < 0 or byte == 4:
            _set_terminal_input_modes(False)
            external_call["mochi_terminal_disable_raw", NoneType]()
            print()
            if ui.draft == "":
                return None
            return Optional(ui.draft.copy())
        if byte == 3:
            if ui.search_open:
                _ = UiReducer.reduce(ui, UiEvent.search_close())
            else:
                _ = UiReducer.reduce(ui, UiEvent.edit(""))
            _render_editor(ui)
            continue
        if byte == 6:
            _ = UiReducer.reduce(ui, UiEvent.search_open())
            _render_editor(ui)
            continue
        if ui.search_open:
            if byte == 10 or byte == 13:
                _ = UiReducer.reduce(ui, UiEvent.search_select())
            elif byte == 127 or byte == 8:
                _ = UiReducer.reduce(ui, UiEvent.search_backspace())
            elif byte == 27:
                var search_escape = external_call[
                    "mochi_terminal_read_byte", c_int, c_int
                ](20)
                if search_escape == 91:
                    var search_key = external_call[
                        "mochi_terminal_read_byte", c_int, c_int
                    ](20)
                    if search_key == 60:
                        _read_sgr_mouse(ui)
                    elif search_key == 65:
                        _ = UiReducer.reduce(ui, UiEvent.search_previous())
                    elif search_key == 66:
                        _ = UiReducer.reduce(ui, UiEvent.search_next())
                    elif search_key == 50:
                        var zero = external_call[
                            "mochi_terminal_read_byte", c_int, c_int
                        ](20)
                        var zero_again = external_call[
                            "mochi_terminal_read_byte", c_int, c_int
                        ](20)
                        var tilde = external_call[
                            "mochi_terminal_read_byte", c_int, c_int
                        ](20)
                        if zero == 48 and zero_again == 48 and tilde == 126:
                            _ = UiReducer.reduce(
                                ui,
                                UiEvent.search_query(
                                    ui.search_query + _read_bracketed_paste()
                                ),
                            )
                else:
                    _ = UiReducer.reduce(ui, UiEvent.search_close())
            elif byte >= 32:
                _ = UiReducer.reduce(
                    ui,
                    UiEvent.search_query(
                        ui.search_query + _read_utf8_character(Int(byte))
                    ),
                )
            _render_editor(ui)
            continue
        if byte == 10 or byte == 13:
            if ui.cursor == ui.draft.count_codepoints() and ui.draft.endswith("\\"):
                _ = UiReducer.reduce(ui, UiEvent.continue_line())
                _render_editor(ui)
                continue
            _set_terminal_input_modes(False)
            external_call["mochi_terminal_disable_raw", NoneType]()
            print()
            return Optional(ui.draft.copy())
        if byte == 127 or byte == 8:
            _ = UiReducer.reduce(ui, UiEvent.delete_backward())
        elif byte == 9 and ui.draft.startswith("/"):
            _ = UiReducer.reduce(
                ui, UiEvent.edit(command_completion(ui.draft, ui.command_selected))
            )
        elif byte == 27:
            var bracket = external_call[
                "mochi_terminal_read_byte", c_int, c_int
            ](20)
            if bracket == 91:
                var key = external_call[
                    "mochi_terminal_read_byte", c_int, c_int
                ](20)
                if key == 60:
                    _read_sgr_mouse(ui)
                elif key == 65:
                    if ui.draft.startswith("/") and len(command_matches(ui.draft)) > 0:
                        _ = UiReducer.reduce(ui, UiEvent.command_previous())
                    else:
                        _ = UiReducer.reduce(ui, UiEvent.history_up())
                elif key == 66:
                    if ui.draft.startswith("/") and len(command_matches(ui.draft)) > 0:
                        _ = UiReducer.reduce(ui, UiEvent.command_next())
                    else:
                        _ = UiReducer.reduce(ui, UiEvent.history_down())
                elif key == 67:
                    _ = UiReducer.reduce(ui, UiEvent.move_cursor(1))
                elif key == 68:
                    _ = UiReducer.reduce(ui, UiEvent.move_cursor(-1))
                elif key == 50:
                    var zero = external_call["getchar", c_int]()
                    var zero_again = external_call["getchar", c_int]()
                    var tilde = external_call["getchar", c_int]()
                    if zero == 48 and zero_again == 48 and tilde == 126:
                        _ = UiReducer.reduce(ui, UiEvent.paste_spaced(_read_bracketed_paste()))
        elif byte >= 32:
            _ = UiReducer.reduce(ui, UiEvent.insert(_read_utf8_character(Int(byte))))
        _render_editor(ui)


def _set_terminal_input_modes(enabled: Bool):
    external_call["mochi_terminal_set_input_modes", NoneType, c_int](
        c_int(1 if enabled else 0)
    )


def _read_sgr_mouse(mut ui: UiState) raises:
    var encoded = String("")
    while True:
        var byte = external_call["mochi_terminal_read_byte", c_int, c_int](20)
        if byte < 0:
            return
        if byte == 77 or byte == 109:
            var event = decode_sgr_mouse(encoded, Int(byte))
            if event:
                _ = UiReducer.reduce(ui, event.value())
                if ui.selection_pending_copy:
                    _copy_pending_input_selection(ui)
            return
        encoded += chr(Int(byte))


def _copy_pending_input_selection(mut ui: UiState):
    var text = ui.selected_input_text()
    if text != "":
        var c_text = text.as_c_string_slice()
        var native = external_call[
            "mochi_native_clipboard_write",
            c_int,
            CStringSlice[ImmutAnyOrigin],
            c_size_t,
        ](
            rebind[CStringSlice[ImmutAnyOrigin]](c_text),
            c_size_t(text.byte_length()),
        )
        if native != 0:
            _ = external_call[
                "mochi_osc52_clipboard_write",
                c_int,
                CStringSlice[ImmutAnyOrigin],
                c_size_t,
            ](
                rebind[CStringSlice[ImmutAnyOrigin]](c_text),
                c_size_t(text.byte_length()),
            )
    ui.clear_pending_copy()


def _read_bracketed_paste() raises -> String:
    var result = String("")
    var escape = String("")
    while True:
        var byte = external_call["getchar", c_int]()
        if byte < 0:
            return result^
        escape += chr(Int(byte))
        if escape.endswith("\x1b[201~"):
            return String(escape.removesuffix("\x1b[201~"))
        if not "\x1b[201~".startswith(escape):
            result += escape
            escape = ""


def _read_utf8_character(first: Int) raises -> String:
    var count = 1
    if first >= 0xF0:
        count = 4
    elif first >= 0xE0:
        count = 3
    elif first >= 0xC0:
        count = 2
    var bytes = List[UInt8]()
    bytes.append(UInt8(first))
    for _ in range(1, count):
        var byte = external_call["getchar", c_int]()
        if byte < 0:
            break
        bytes.append(UInt8(byte))
    return String(unsafe_from_utf8=Span(bytes))


def _render_editor(mut ui: UiState):
    var columns = Int(external_call["mochi_terminal_columns", c_int]())
    if columns <= 0:
        columns = ui.viewport_width
    ui.register_terminal_zones(columns, 1)
    if ui.search_open:
        var count = len(ui.search_matches)
        var selected = 0
        if count > 0:
            selected = ui.search_selected + 1
        var preview = String("")
        var results = search_result_lines(ui)
        if count > 0:
            preview = "  |  " + results[ui.search_selected]
        elif ui.search_query != "":
            preview = "  |  No matches"
        print(
            "\r\x1b[2KSearch: " + ui.search_query + "  " + String(selected)
            + "/" + String(count) + preview,
            end="",
        )
        return
    var tail = ui.draft.count_codepoints() - ui.cursor
    print("\r\x1b[2K> " + ui.draft, end="")
    if tail > 0:
        print("\x1b[" + String(tail) + "D", end="")
    if ui.draft.startswith("/") and not " " in ui.draft:
        var matches = command_matches(ui.draft)
        if len(matches) > 0:
            var selected = min(ui.command_selected, len(matches) - 1)
            print(
                "\x1b[s\x1b[90m  " + matches[selected] + "  "
                + String(selected + 1) + "/" + String(len(matches))
                + "\x1b[0m\x1b[u",
                end="",
            )


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
