"""Bounded provider-neutral invocation contracts and deterministic test adapter."""

from mochi.json import JsonValue
from mochi.tools import ToolResult
from mochi.types import CancellationToken


struct InvocationAudience(Equatable, ImplicitlyCopyable):
    """Bit flags describing who may discover and issue an invocation."""

    comptime NONE: UInt8 = 0
    comptime MAIN: UInt8 = 1
    comptime RESEARCH_SUB: UInt8 = 2
    comptime GENERAL_SUB: UInt8 = 4
    comptime INTERPRETER: UInt8 = 8
    comptime WORKFLOW: UInt8 = 16
    comptime ALL: UInt8 = 31
    comptime USER: UInt8 = Self.MAIN
    comptime MODEL: UInt8 = Self.MAIN

    var bits: UInt8

    def __init__(out self, bits: UInt8):
        self.bits = bits & Self.ALL

    @staticmethod
    def none() -> Self:
        return Self(Self.NONE)

    @staticmethod
    def main() -> Self:
        return Self(Self.MAIN)

    @staticmethod
    def research_sub() -> Self:
        return Self(Self.RESEARCH_SUB)

    @staticmethod
    def general_sub() -> Self:
        return Self(Self.GENERAL_SUB)

    @staticmethod
    def interpreter() -> Self:
        return Self(Self.INTERPRETER)

    @staticmethod
    def workflow() -> Self:
        return Self(Self.WORKFLOW)

    @staticmethod
    def user() -> Self:
        return Self.main()

    @staticmethod
    def model() -> Self:
        return Self.main()

    @staticmethod
    def all() -> Self:
        return Self(Self.ALL)

    @staticmethod
    def both() -> Self:
        return Self.all()

    def contains(self, other: Self) -> Bool:
        return (self.bits & other.bits) == other.bits

    def intersects(self, other: Self) -> Bool:
        return (self.bits & other.bits) != 0

    def combined(self, other: Self) -> Self:
        return Self(self.bits | other.bits)

    def __eq__(self, other: Self) -> Bool:
        return self.bits == other.bits

    def __ne__(self, other: Self) -> Bool:
        return self.bits != other.bits


struct InvocationSource(Copyable, Movable):
    """A closed source tag with an optional stable owner identifier."""

    comptime BUILTIN = 0
    comptime MCP = 1
    comptime PLUGIN = 2
    comptime HOST = 3
    comptime SUBAGENT = 4

    var tag: Int
    var owner: String

    def __init__(out self, tag: Int, var owner: String = ""):
        self.tag = tag
        self.owner = owner^

    @staticmethod
    def builtin() -> Self:
        return Self(Self.BUILTIN)

    @staticmethod
    def mcp(var server: String) -> Self:
        return Self(Self.MCP, server^)

    @staticmethod
    def plugin(var name: String) -> Self:
        return Self(Self.PLUGIN, name^)

    @staticmethod
    def host(var name: String = "") -> Self:
        return Self(Self.HOST, name^)

    @staticmethod
    def subagent(var name: String) -> Self:
        return Self(Self.SUBAGENT, name^)

    def is_builtin(self) -> Bool:
        return self.tag == Self.BUILTIN

    def is_mcp(self) -> Bool:
        return self.tag == Self.MCP

    def is_plugin(self) -> Bool:
        return self.tag == Self.PLUGIN

    def is_host(self) -> Bool:
        return self.tag == Self.HOST

    def is_subagent(self) -> Bool:
        return self.tag == Self.SUBAGENT


struct InvocationDefinition(Copyable, Movable):
    """Discoverable invocation metadata without an executable callback."""

    var name: String
    var description: String
    var input_schema: JsonValue
    var audience: InvocationAudience
    var source: InvocationSource

    def __init__(
        out self,
        var name: String,
        var description: String = "",
        var input_schema: JsonValue = JsonValue.object(),
        audience: InvocationAudience = InvocationAudience.all(),
        var source: InvocationSource = InvocationSource.builtin(),
    ):
        self.name = name^
        self.description = description^
        self.input_schema = input_schema^
        self.audience = audience
        self.source = source^


struct InvocationRequest(Copyable, Movable):
    """One invocation attempt with caller-provided identity and arguments."""

    var id: String
    var name: String
    var arguments: JsonValue
    var audience: InvocationAudience
    var cancel: CancellationToken
    var deadline_ms: Optional[Int]
    var parent_id: Optional[String]
    var session_id: Optional[String]

    def __init__(
        out self,
        var id: String,
        var name: String,
        var cancel: CancellationToken,
        var arguments: JsonValue = JsonValue.object(),
        audience: InvocationAudience = InvocationAudience.model(),
        var deadline_ms: Optional[Int] = None,
        var parent_id: Optional[String] = None,
        var session_id: Optional[String] = None,
    ):
        self.id = id^
        self.name = name^
        self.arguments = arguments^
        self.audience = audience
        self.cancel = cancel^
        self.deadline_ms = deadline_ms^
        self.parent_id = parent_id^
        self.session_id = session_id^


struct InvocationResult(Copyable, Movable):
    """Transport-independent success or failure returned by an invocation."""

    comptime SUCCESS = 0
    comptime FAILURE = 1
    comptime REJECTED = 2
    comptime CANCELLED = 3
    comptime TIMED_OUT = 4

    var ok: Bool
    var content: String
    var status: Int
    var output_kind: String
    var structured: JsonValue
    var annotation: Optional[String]
    var instructions: JsonValue
    var state: JsonValue
    var written_path: Optional[String]
    var image: JsonValue

    def __init__(out self, ok: Bool, var content: String):
        self.ok = ok
        self.content = content^
        self.status = Self.SUCCESS if ok else Self.FAILURE
        self.output_kind = "plain"
        self.structured = JsonValue.null()
        self.annotation = None
        self.instructions = JsonValue.array()
        self.state = JsonValue.null()
        self.written_path = None
        self.image = JsonValue.null()

    @staticmethod
    def success(var content: String) -> Self:
        return Self(True, content^)

    @staticmethod
    def failure(var content: String) -> Self:
        return Self(False, content^)

    @staticmethod
    def rejected(var content: String) -> Self:
        var result = Self(False, content^)
        result.status = Self.REJECTED
        return result^

    @staticmethod
    def cancelled(var content: String = "cancelled") -> Self:
        var result = Self(False, content^)
        result.status = Self.CANCELLED
        return result^

    @staticmethod
    def timed_out(var content: String = "invocation timed out") -> Self:
        var result = Self(False, content^)
        result.status = Self.TIMED_OUT
        return result^

    @staticmethod
    def from_tool_result(result: ToolResult) -> Self:
        return Self(result.ok, result.content)

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        """Decode the JSON-safe subset of Maki's plugin tool result contract."""
        if value.kind == JsonValue.STRING:
            return Self.success(value.string_value)
        if value.kind != JsonValue.OBJECT:
            raise Error("invocation result must be a string or object")

        var content: String
        if value.contains("llm_output"):
            content = _result_string(value, "llm_output")
        elif value.contains("content"):
            content = _result_string(value, "content")
        else:
            raise Error("invocation result requires llm_output or content")

        var ok = True
        if value.contains("is_error"):
            ok = not _result_bool(value, "is_error")
        elif value.contains("ok"):
            # `ok` belongs to Mochi's internal result codec.  A Maki
            # `is_error` value is authoritative when both are present.
            ok = _result_bool(value, "ok")
        var result = Self(ok, content^)
        if value.contains("status"):
            result.status = _result_int(value, "status")
        if value.contains("output_kind"):
            result.output_kind = _result_string(value, "output_kind")
        elif value.contains("format"):
            result.output_kind = _result_string(value, "format")
        if value.contains("structured"):
            result.structured = value.get("structured")
        if value.contains("annotation"):
            result.annotation = Optional(_result_string(value, "annotation"))
        if value.contains("instructions"):
            var instructions = value.get("instructions")
            if instructions.kind == JsonValue.ARRAY:
                var valid = JsonValue.array()
                for block in instructions.array_value:
                    if (
                        block.kind == JsonValue.OBJECT
                        and block.contains("path")
                        and block.get("path").kind == JsonValue.STRING
                        and block.contains("content")
                        and block.get("content").kind == JsonValue.STRING
                    ):
                        valid.append(block.copy())
                result.instructions = valid^
        if value.contains("state"):
            result.state = value.get("state")
        if value.contains("written_path"):
            result.written_path = Optional(
                _result_string(value, "written_path")
            )
        if value.contains("image"):
            var image = value.get("image")
            if image.kind != JsonValue.OBJECT:
                raise Error(
                    "invocation result image must contain media_type and data"
                )
            var media_type = _result_string(image, "media_type")
            if (
                media_type != "image/png"
                and media_type != "image/jpeg"
                and media_type != "image/gif"
                and media_type != "image/webp"
            ):
                raise Error("unsupported invocation result image media_type")
            var data = _result_string(image, "data")
            if not _valid_base64(data):
                raise Error("invocation result image data is not valid base64")
            result.image = image^
        return result^

    def to_tool_result(self) -> ToolResult:
        return ToolResult(self.ok, self.content)


struct InvocationEvent(Copyable, Movable):
    """A deterministic lifecycle event suitable for bounded traces."""

    comptime STARTED = 0
    comptime COMPLETED = 1
    comptime FAILED = 2
    comptime REJECTED = 3
    comptime CANCELLED = 4
    comptime TIMED_OUT = 5

    var tag: Int
    var request_id: String
    var name: String
    var content: String

    def __init__(
        out self,
        tag: Int,
        var request_id: String,
        var name: String,
        var content: String = "",
    ):
        self.tag = tag
        self.request_id = request_id^
        self.name = name^
        self.content = content^

    @staticmethod
    def started(request: InvocationRequest) -> Self:
        return Self(Self.STARTED, request.id, request.name)

    @staticmethod
    def completed(request: InvocationRequest, result: InvocationResult) -> Self:
        return Self(Self.COMPLETED, request.id, request.name, result.content)

    @staticmethod
    def failed(request: InvocationRequest, result: InvocationResult) -> Self:
        var tag = Self.FAILED
        if result.status == InvocationResult.REJECTED:
            tag = Self.REJECTED
        elif result.status == InvocationResult.CANCELLED:
            tag = Self.CANCELLED
        elif result.status == InvocationResult.TIMED_OUT:
            tag = Self.TIMED_OUT
        return Self(tag, request.id, request.name, result.content)

    def is_started(self) -> Bool:
        return self.tag == Self.STARTED

    def is_completed(self) -> Bool:
        return self.tag == Self.COMPLETED

    def is_failed(self) -> Bool:
        return self.tag == Self.FAILED

    def is_rejected(self) -> Bool:
        return self.tag == Self.REJECTED

    def is_cancelled(self) -> Bool:
        return self.tag == Self.CANCELLED

    def is_timed_out(self) -> Bool:
        return self.tag == Self.TIMED_OUT


struct InvocationTrace(Copyable, Movable):
    """Append-only lifecycle trace with an explicit event bound."""

    var events: List[InvocationEvent]
    var max_events: Int
    var dropped_events: Int

    def __init__(out self, max_events: Int = 256) raises:
        if max_events < 0:
            raise Error("invocation trace bound must not be negative")
        self.events = List[InvocationEvent]()
        self.max_events = max_events
        self.dropped_events = 0

    def append(mut self, var event: InvocationEvent):
        if self.max_events == 0:
            self.dropped_events += 1
            return
        if len(self.events) >= self.max_events:
            _ = self.events.pop(0)
            self.dropped_events += 1
        self.events.append(event^)

    def clear(mut self):
        self.events.clear()
        self.dropped_events = 0


struct FakeInvocationAdapter(Copyable, Movable):
    """Deterministic bounded registry and FIFO result fixture."""

    var definitions: List[InvocationDefinition]
    var result_names: List[String]
    var results: List[InvocationResult]
    var trace: InvocationTrace
    var max_definitions: Int
    var max_results: Int

    def __init__(
        out self,
        max_definitions: Int = 64,
        max_results: Int = 256,
        max_events: Int = 512,
    ) raises:
        if max_definitions < 0 or max_results < 0:
            raise Error("invocation adapter bounds must not be negative")
        self.definitions = List[InvocationDefinition]()
        self.result_names = List[String]()
        self.results = List[InvocationResult]()
        self.trace = InvocationTrace(max_events)
        self.max_definitions = max_definitions
        self.max_results = max_results

    def contains(self, name: String) -> Bool:
        for definition in self.definitions:
            if definition.name == name:
                return True
        return False

    def register(mut self, var definition: InvocationDefinition) raises:
        if definition.name == "":
            raise Error("invocation name must not be empty")
        if self.contains(definition.name):
            raise Error("invocation already registered: " + definition.name)
        if len(self.definitions) >= self.max_definitions:
            raise Error("invocation definition capacity exceeded")
        self.definitions.append(definition^)

    def enqueue(
        mut self, var name: String, var result: InvocationResult
    ) raises:
        if not self.contains(name):
            raise Error("invocation is not registered: " + name)
        if len(self.results) >= self.max_results:
            raise Error("invocation result capacity exceeded")
        self.result_names.append(name^)
        self.results.append(result^)

    def invoke(mut self, request: InvocationRequest) raises -> InvocationResult:
        var definition_index = -1
        for i in range(len(self.definitions)):
            if self.definitions[i].name == request.name:
                definition_index = i
                break
        if definition_index < 0:
            var result = InvocationResult.rejected(
                "invocation is not registered: " + request.name
            )
            self.trace.append(InvocationEvent.failed(request, result))
            return result^
        if request.audience.bits == InvocationAudience.NONE or (
            request.audience.bits & (request.audience.bits - 1)
        ) != 0:
            var result = InvocationResult.rejected(
                "invocation request must have exactly one audience: "
                + request.name
            )
            self.trace.append(InvocationEvent.failed(request, result))
            return result^
        if not self.definitions[definition_index].audience.contains(
            request.audience
        ):
            var result = InvocationResult.rejected(
                "invocation audience is not allowed: " + request.name
            )
            self.trace.append(InvocationEvent.failed(request, result))
            return result^
        if request.cancel.is_cancelled():
            var result = InvocationResult.cancelled()
            self.trace.append(InvocationEvent.failed(request, result))
            return result^
        self.trace.append(InvocationEvent.started(request))
        for i in range(len(self.result_names)):
            if self.result_names[i] == request.name:
                _ = self.result_names.pop(i)
                var result = self.results.pop(i)
                if request.cancel.is_cancelled():
                    result = InvocationResult.cancelled()
                if result.ok:
                    self.trace.append(
                        InvocationEvent.completed(request, result)
                    )
                else:
                    self.trace.append(InvocationEvent.failed(request, result))
                return result^
        var result = InvocationResult.failure(
            "no invocation result queued: " + request.name
        )
        self.trace.append(InvocationEvent.failed(request, result))
        return result^


def invocation_definition_to_json(definition: InvocationDefinition) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("name", JsonValue.string(definition.name))
    value.set("description", JsonValue.string(definition.description))
    value.set("input_schema", definition.input_schema.copy())
    value.set("audience", JsonValue.integer(Int(definition.audience.bits)))
    value.set("source", JsonValue.integer(definition.source.tag))
    value.set("owner", JsonValue.string(definition.source.owner))
    return value^


def invocation_result_to_json(result: InvocationResult) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("ok", JsonValue.boolean(result.ok))
    value.set("status", JsonValue.integer(result.status))
    value.set("content", JsonValue.string(result.content))
    value.set("output_kind", JsonValue.string(result.output_kind))
    value.set("structured", result.structured.copy())
    value.set("instructions", result.instructions.copy())
    value.set("state", result.state.copy())
    value.set("image", result.image.copy())
    if result.annotation:
        value.set("annotation", JsonValue.string(result.annotation.value()))
    if result.written_path:
        value.set("written_path", JsonValue.string(result.written_path.value()))
    return value^


def _result_string(value: JsonValue, key: String) raises -> String:
    var field = value.get(key)
    if field.kind != JsonValue.STRING:
        raise Error("invocation result field must be a string: " + key)
    return field.string_value


def _result_bool(value: JsonValue, key: String) raises -> Bool:
    var field = value.get(key)
    if field.kind != JsonValue.BOOL:
        raise Error("invocation result field must be a boolean: " + key)
    return field.bool_value


def _result_int(value: JsonValue, key: String) raises -> Int:
    var field = value.get(key)
    if field.kind != JsonValue.INT:
        raise Error("invocation result field must be an integer: " + key)
    return field.int_value


def _valid_base64(value: String) -> Bool:
    if value == "" or value.byte_length() % 4 != 0:
        return False
    var padding = 0
    for index in range(value.byte_length()):
        var byte = UInt8(ord(value[byte=index]))
        if byte == 61:
            padding += 1
            if index < value.byte_length() - 2 or padding > 2:
                return False
            continue
        if padding > 0:
            return False
        var valid = (
            (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
            or (byte >= 48 and byte <= 57)
            or byte == 43
            or byte == 47
        )
        if not valid:
            return False
    return True
