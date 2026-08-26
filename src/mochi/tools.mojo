"""Pure Mojo tool preparation, authorization, and tagged built-in execution."""

from std.ffi import c_int, external_call
from std.os import listdir, remove
from std.os.path import exists, isdir

from mochi.json import JsonValue, parse_json
from mochi.permissions import PermissionDecision, PermissionEffect, PermissionManager


struct PreparedTool(Copyable, Movable):
    """Validated invocation. Execution is deliberately separate from preparation."""

    var name: String
    var arguments: JsonValue
    var scopes: List[String]

    def __init__(out self, var name: String, var arguments: JsonValue):
        self.name = name^
        self.arguments = arguments^
        self.scopes = List[String]()

    def add_scope(mut self, var scope: String):
        self.scopes.append(scope^)


@fieldwise_init
struct ToolResult(Copyable, Movable):
    var ok: Bool
    var content: String

    @staticmethod
    def success(var content: String) -> Self:
        return Self(True, content^)

    @staticmethod
    def failure(var content: String) -> Self:
        return Self(False, content^)


@fieldwise_init
struct RemoteToolMetadata(Copyable, Movable):
    """Model metadata plus a concrete remote routing tag."""

    var protocol: String
    var endpoint: String
    var name: String
    var description: String
    var parameters: JsonValue


struct RemoteToolRouter(Copyable, Movable):
    """Tagged remote dispatch state with deterministic result queues.

    Concrete MCP/plugin clients may feed results into this router without being
    erased behind an impossible transport trait object.
    """

    var protocols: List[String]
    var endpoints: List[String]
    var names: List[String]
    var result_names: List[String]
    var results: List[ToolResult]

    def __init__(out self):
        self.protocols = List[String]()
        self.endpoints = List[String]()
        self.names = List[String]()
        self.result_names = List[String]()
        self.results = List[ToolResult]()

    def register(mut self, metadata: RemoteToolMetadata) raises:
        if metadata.protocol != "mcp" and metadata.protocol != "plugin":
            raise Error("unsupported remote tool protocol: " + metadata.protocol)
        for name in self.names:
            if name == metadata.name:
                raise Error("duplicate remote tool route: " + metadata.name)
        self.protocols.append(metadata.protocol)
        self.endpoints.append(metadata.endpoint)
        self.names.append(metadata.name)

    def route_index(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def is_remote(self, name: String) -> Bool:
        return self.route_index(name) >= 0

    def protocol_for(self, name: String) -> String:
        var index = self.route_index(name)
        return self.protocols[index] if index >= 0 else ""

    def endpoint_for(self, name: String) -> String:
        var index = self.route_index(name)
        return self.endpoints[index] if index >= 0 else ""

    def remove_endpoint(mut self, protocol: String, endpoint: String):
        for i in range(len(self.names) - 1, -1, -1):
            if self.protocols[i] == protocol and self.endpoints[i] == endpoint:
                var name = self.names.pop(i)
                _ = self.protocols.pop(i)
                _ = self.endpoints.pop(i)
                for j in range(len(self.result_names) - 1, -1, -1):
                    if self.result_names[j] == name:
                        _ = self.result_names.pop(j)
                        _ = self.results.pop(j)

    def enqueue_result(mut self, var name: String, var result: ToolResult) raises:
        if not self.is_remote(name):
            raise Error("remote tool route is not registered: " + name)
        self.result_names.append(name^)
        self.results.append(result^)

    def take_queued(mut self, name: String) -> Optional[ToolResult]:
        for i in range(len(self.result_names)):
            if self.result_names[i] == name:
                _ = self.result_names.pop(i)
                return Optional(self.results.pop(i))
        return None

    def execute(mut self, prepared: PreparedTool) -> ToolResult:
        var queued = self.take_queued(prepared.name)
        if queued:
            return queued.value().copy()
        return ToolResult.failure("no remote result queued: " + prepared.name)


struct ToolRegistry(Copyable, Movable):
    """Registry of practical tagged built-ins; no Python or dynamic callbacks."""

    var cwd: String
    var names: List[String]
    var owners: List[String]
    var subagent_prompts: List[String]
    var subagent_responses: List[String]
    var max_subagents: Int
    var subagent_calls: Int
    var workflow: Bool

    def __init__(out self, var cwd: String = ".", max_subagents: Int = 8):
        self.cwd = cwd^
        self.names = List[String]()
        self.owners = List[String]()
        self.subagent_prompts = List[String]()
        self.subagent_responses = List[String]()
        self.max_subagents = max_subagents
        self.subagent_calls = 0
        self.workflow = False
        self.names.append("read")
        self.owners.append("builtin")
        self.names.append("write")
        self.owners.append("builtin")
        self.names.append("edit")
        self.owners.append("builtin")
        self.names.append("list")
        self.owners.append("builtin")
        self.names.append("bash")
        self.owners.append("builtin")
        self.names.append("code_execution")
        self.owners.append("builtin")
        self.names.append("task")
        self.owners.append("builtin")

    def index_of(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def register(mut self, var name: String, var owner: String = "builtin") raises:
        var index = self.index_of(name)
        if index >= 0:
            if self.owners[index] != owner:
                raise Error("tool name conflict: " + name)
            return
        self.names.append(name^)
        self.owners.append(owner^)

    def register_remote(mut self, metadata: RemoteToolMetadata) raises:
        self.register(
            metadata.name,
            metadata.protocol + ":" + metadata.endpoint,
        )

    def is_remote(self, name: String) -> Bool:
        var index = self.index_of(name)
        return index >= 0 and self.owners[index] != "builtin"

    def remove_owner(mut self, owner: String):
        for i in range(len(self.names) - 1, -1, -1):
            if self.owners[i] == owner:
                _ = self.names.pop(i)
                _ = self.owners.pop(i)

    def add_subagent_response(mut self, var prompt: String, var response: String):
        """Install a deterministic Mojo-side subagent callback response."""
        self.subagent_prompts.append(prompt^)
        self.subagent_responses.append(response^)

    def set_workflow(mut self, enabled: Bool):
        self.workflow = enabled

    def resolve_path(self, path: String) -> String:
        if path.startswith("/") or self.cwd == ".":
            return path
        return self.cwd + "/" + path

    def prepare(self, name: String, arguments_text: String) raises -> PreparedTool:
        if self.index_of(name) < 0:
            raise Error("unknown tool: " + name)
        var arguments = parse_json(arguments_text if arguments_text else "{}")
        if arguments.kind != JsonValue.OBJECT:
            raise Error("tool arguments must be an object")
        var prepared = PreparedTool(name, arguments^)
        if name == "read" or name == "write" or name == "edit" or name == "list":
            var path = self.resolve_path(_string_arg(prepared.arguments, "path"))
            prepared.arguments.set("path", JsonValue.string(path))
            prepared.add_scope(path)
        elif name == "bash":
            prepared.add_scope(_string_arg(prepared.arguments, "command"))
        elif name == "code_execution":
            _ = _string_arg(prepared.arguments, "code")
            prepared.add_scope("mojo-mini-interpreter")
        elif name == "task":
            _ = _string_arg(prepared.arguments, "description")
            _ = _string_arg(prepared.arguments, "prompt")
            prepared.add_scope("subagent")
        elif self.is_remote(name):
            prepared.add_scope(self.owners[self.index_of(name)])
        return prepared^

    def authorize(self, prepared: PreparedTool, permissions: PermissionManager) -> PermissionDecision:
        return permissions.check(prepared.name, prepared.scopes)

    def execute(mut self, prepared: PreparedTool) -> ToolResult:
        try:
            if prepared.name == "read":
                return ToolResult.success(open(_string_arg(prepared.arguments, "path"), "r").read())
            if prepared.name == "write":
                return self._write(prepared.arguments)
            if prepared.name == "edit":
                return self._edit(prepared.arguments)
            if prepared.name == "list":
                return self._list(prepared.arguments)
            if prepared.name == "bash":
                return self._bash(prepared.arguments)
            if prepared.name == "code_execution":
                return self._code_execution(prepared.arguments)
            if prepared.name == "task":
                if not self.workflow:
                    return ToolResult.failure("subagents require workflow mode")
                return ToolResult.success(self._subagent(_string_arg(prepared.arguments, "prompt")))
            return ToolResult.failure("unknown tool: " + prepared.name)
        except error:
            return ToolResult.failure("Error: " + String(error))

    def _write(self, arguments: JsonValue) raises -> ToolResult:
        var path = _string_arg(arguments, "path")
        var content = _string_arg(arguments, "content")
        with open(path, "w") as file:
            file.write(content)
        return ToolResult.success("{\"path\":" + _json_quote(path) + ",\"bytes\":" + String(content.byte_length()) + "}")

    def _edit(self, arguments: JsonValue) raises -> ToolResult:
        var path = _string_arg(arguments, "path")
        var old = _string_arg(arguments, "old_string")
        var replacement = _string_arg(arguments, "new_string")
        var content = open(path, "r").read()
        if old == "" or _count(content, old) != 1:
            raise Error("old_string must occur exactly once")
        var changed = content.replace(old, replacement)
        with open(path, "w") as file:
            file.write(changed)
        return ToolResult.success("{\"path\":" + _json_quote(path) + "}")

    def _list(self, arguments: JsonValue) raises -> ToolResult:
        var path = _string_arg(arguments, "path")
        var output = String("[")
        var first = True
        for name in listdir(path):
            if not first:
                output += ","
            first = False
            var suffix = "/" if isdir(path + "/" + name) else ""
            output += _json_quote(name + suffix)
        output += "]"
        return ToolResult.success(output^)

    def _bash(self, arguments: JsonValue) raises -> ToolResult:
        var command = _string_arg(arguments, "command")
        var pid = external_call["getpid", c_int]()
        var output_path = "/tmp/mochi-tool-output-" + String(pid) + ".txt"
        var wrapped = (
            "cd " + _shell_quote(self.cwd) + " && (" + command + ") > "
            + _shell_quote(output_path) + " 2>&1"
        )
        var c_command = wrapped.as_c_string_slice()
        var status = external_call["system", c_int](c_command.unsafe_ptr())
        var output = String("")
        if exists(output_path):
            output = open(output_path, "r").read()
            remove(output_path)
        var exit_code = status
        if status >= 0:
            exit_code = (status >> 8) & 255
        var content = (
            "{\"exit_code\":" + String(exit_code)
            + ",\"output\":" + _json_quote(output) + "}"
        )
        if exit_code == 0:
            return ToolResult.success(content^)
        return ToolResult.failure(content^)

    def _subagent(mut self, prompt: String) raises -> String:
        self.subagent_calls += 1
        if self.subagent_calls > self.max_subagents:
            raise Error("subagent limit exceeded")
        for i in range(len(self.subagent_prompts)):
            if self.subagent_prompts[i] == prompt:
                return self.subagent_responses[i]
        raise Error("no scripted subagent response: " + prompt)

    def _code_execution(mut self, arguments: JsonValue) raises -> ToolResult:
        """Run a bounded line-oriented interpreter: ECHO, SET, APPEND, SUBAGENT."""
        var code = _string_arg(arguments, "code")
        var output = String("")
        var variable = String("")
        var steps = 0
        for line_slice in code.split("\n"):
            var line = String(line_slice).strip()
            if not line:
                continue
            steps += 1
            if steps > 64:
                raise Error("mini-interpreter step limit exceeded")
            if line.startswith("ECHO "):
                output += String(line.removeprefix("ECHO ")) + "\n"
            elif line.startswith("SET "):
                variable = String(line.removeprefix("SET "))
            elif line == "APPEND":
                output += variable
            elif line.startswith("SUBAGENT "):
                if not self.workflow:
                    raise Error("subagents require workflow mode")
                output += self._subagent(String(line.removeprefix("SUBAGENT "))) + "\n"
            else:
                raise Error("unknown mini-interpreter command: " + line)
            if output.byte_length() > 100000:
                raise Error("mini-interpreter output limit exceeded")
        return ToolResult.success("{\"output\":" + _json_quote(output) + ",\"subagents\":" + String(self.subagent_calls) + "}")


def _string_arg(arguments: JsonValue, key: String) raises -> String:
    if not arguments.contains(key):
        raise Error("missing tool argument: " + key)
    var value = arguments.get(key)
    if value.kind != JsonValue.STRING:
        raise Error("tool argument must be a string: " + key)
    return value.string_value


def _count(value: String, needle: String) -> Int:
    return len(value.split(needle)) - 1


def _shell_quote(value: String) -> String:
    return "'" + value.replace("'", "'\\''") + "'"


def _json_quote(value: String) -> String:
    return JsonValue.string(value).serialize()
