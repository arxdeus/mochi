"""Core, provider-neutral domain types for Mochi."""

from std.ffi import c_int, external_call


comptime _CancellationHandle = MutPointer[NoneType, MutUntrackedOrigin]


@fieldwise_init
struct ToolCall(Copyable, Movable):
    """A model request to invoke a named tool."""

    var id: String
    var name: String
    var arguments: String


@fieldwise_init
struct Message(Copyable, Movable):
    """A conversation message with optional tool-call metadata."""

    var role: String
    var content: String
    var tool_calls: List[ToolCall]
    var tool_call_id: String
    var name: String

    def __init__(out self, role: String, content: String):
        self.role = role
        self.content = content
        self.tool_calls = List[ToolCall]()
        self.tool_call_id = ""
        self.name = ""

    def add_tool_call(mut self, var call: ToolCall):
        self.tool_calls.append(call^)


@fieldwise_init
struct Usage(Copyable, Movable):
    """Token counts accumulated across provider turns."""

    var input_tokens: Int
    var output_tokens: Int

    def __init__(out self):
        self.input_tokens = 0
        self.output_tokens = 0

    def total_tokens(self) -> Int:
        return self.input_tokens + self.output_tokens

    def add(mut self, other: Self):
        self.input_tokens += other.input_tokens
        self.output_tokens += other.output_tokens


@fieldwise_init
struct ProviderEvent(Copyable, Movable):
    """A streaming provider event without a dependency on a JSON value type."""

    var kind: String
    var text: String
    var tool_call: Optional[ToolCall]
    var usage: Usage
    var stop_reason: String

    @staticmethod
    def text_delta(text: String) -> Self:
        return Self("text_delta", text, None, Usage(), "")

    @staticmethod
    def tool_call_delta(var call: ToolCall) -> Self:
        return Self("tool_call_delta", "", Optional(call^), Usage(), "")

    @staticmethod
    def usage_event(usage: Usage) -> Self:
        return Self("usage", "", None, usage.copy(), "")

    @staticmethod
    def done(reason: String) -> Self:
        return Self("done", "", None, Usage(), reason)


struct CancellationToken(Copyable, Movable):
    """A shared, thread-safe hierarchical cooperative cancellation token."""

    var _handle: _CancellationHandle

    def __init__(out self):
        self._handle = external_call[
            "mochi_cancellation_new", _CancellationHandle
        ]()

    def __init__(out self, *, copy: Self):
        self._handle = copy._handle
        external_call["mochi_cancellation_retain", NoneType](self._handle)

    def __deinit__(deinit self):
        external_call["mochi_cancellation_release", NoneType](self._handle)

    def cancel(self):
        external_call["mochi_cancellation_cancel", NoneType](self._handle)

    def is_cancelled(self) -> Bool:
        return Bool(
            external_call["mochi_cancellation_is_cancelled", c_int](
                self._handle
            )
        )

    def check(self) raises:
        if self.is_cancelled():
            raise Error("operation cancelled")

    def cancel_after(self, milliseconds: Int) raises:
        if milliseconds < 0:
            raise Error("cancellation delay must not be negative")
        var result = external_call[
            "mochi_cancellation_cancel_after", c_int
        ](self._handle, c_int(milliseconds))
        if result != 0:
            raise Error("unable to schedule cancellation")

    def child(self) -> Self:
        return Self(
            _child_handle=external_call[
                "mochi_cancellation_child", _CancellationHandle
            ](self._handle)
        )

    def __init__(out self, *, _child_handle: _CancellationHandle):
        self._handle = _child_handle
