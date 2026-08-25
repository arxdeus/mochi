"""Canonical provider request, streaming, and deterministic fake contracts."""

from mochi.domain import (
    DomainMessage,
    DomainProviderEvent,
    MochiError,
    Model,
    ModelInfo,
    StreamResponse,
)
from mochi.json import JsonValue
from mochi.types import CancellationToken


struct ThinkingEffort(Copyable, Movable):
    comptime MINIMAL = 0
    comptime LOW = 1
    comptime MEDIUM = 2
    comptime HIGH = 3
    comptime XHIGH = 4
    comptime MAX = 5

    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def minimal() -> Self:
        return Self(Self.MINIMAL)

    @staticmethod
    def low() -> Self:
        return Self(Self.LOW)

    @staticmethod
    def medium() -> Self:
        return Self(Self.MEDIUM)

    @staticmethod
    def high() -> Self:
        return Self(Self.HIGH)

    @staticmethod
    def xhigh() -> Self:
        return Self(Self.XHIGH)

    @staticmethod
    def maximum() -> Self:
        return Self(Self.MAX)


struct ThinkingConfig(Copyable, Movable):
    comptime OFF = 0
    comptime ADAPTIVE = 1
    comptime EFFORT = 2
    comptime BUDGET = 3

    var tag: Int
    var effort: ThinkingEffort
    var budget_tokens: Int

    def __init__(out self, tag: Int):
        self.tag = tag
        self.effort = ThinkingEffort.medium()
        self.budget_tokens = 0

    @staticmethod
    def off() -> Self:
        return Self(Self.OFF)

    @staticmethod
    def adaptive() -> Self:
        return Self(Self.ADAPTIVE)

    @staticmethod
    def with_effort(effort: ThinkingEffort) -> Self:
        var config = Self(Self.EFFORT)
        config.effort = effort.copy()
        return config^

    @staticmethod
    def with_budget(tokens: Int) -> Self:
        var config = Self(Self.BUDGET)
        config.budget_tokens = tokens
        return config^

    def is_off(self) -> Bool:
        return self.tag == Self.OFF


@fieldwise_init
struct RequestOptions(Copyable, Movable):
    var thinking: ThinkingConfig
    var fast: Bool

    def __init__(out self):
        self.thinking = ThinkingConfig.off()
        self.fast = False

    def clamped(self, model: Model) -> Self:
        var result = self.copy()
        result.fast = False
        if not model.supports_thinking():
            result.thinking = ThinkingConfig.off()
        elif model.requires_thinking() and result.thinking.is_off():
            result.thinking = ThinkingConfig.with_effort(
                ThinkingEffort.minimal()
            )
        return result^


struct ProviderRequest(Copyable, Movable):
    var model: Model
    var messages: List[DomainMessage]
    var system: String
    var tools: JsonValue
    var options: RequestOptions
    var session_id: Optional[String]
    var cancel: CancellationToken

    def __init__(
        out self,
        var model: Model,
        var cancel: CancellationToken,
        var messages: List[DomainMessage] = List[DomainMessage](),
        var system: String = "",
        var tools: JsonValue = JsonValue.array(),
        var options: RequestOptions = RequestOptions(),
        var session_id: Optional[String] = None,
    ):
        self.model = model^
        self.messages = messages^
        self.system = system^
        self.tools = tools^
        self.options = options^
        self.session_id = session_id^
        self.cancel = cancel^


trait ProviderEventSink:
    def emit(mut self, event: DomainProviderEvent) raises: ...


trait Provider:
    def stream_message[S: ProviderEventSink](
        mut self, request: ProviderRequest, mut sink: S
    ) raises -> StreamResponse: ...

    def list_models(mut self) raises -> List[ModelInfo]: ...


struct CapturedProviderRequest(Copyable, Movable):
    var model: Model
    var messages: List[DomainMessage]
    var system: String
    var tools: JsonValue
    var options: RequestOptions
    var session_id: Optional[String]
    var cancelled_at_entry: Bool

    def __init__(out self, request: ProviderRequest):
        self.model = request.model.copy()
        self.messages = request.messages.copy()
        self.system = request.system
        self.tools = request.tools.copy()
        self.options = request.options.copy()
        self.session_id = request.session_id.copy()
        self.cancelled_at_entry = request.cancel.is_cancelled()


struct FakeProviderStep(Copyable, Movable):
    var events: List[DomainProviderEvent]
    var response: Optional[StreamResponse]
    var error: Optional[MochiError]
    var cancel_after_events: Optional[Int]

    def __init__(
        out self,
        var events: List[DomainProviderEvent] = List[DomainProviderEvent](),
        var response: Optional[StreamResponse] = None,
        var error: Optional[MochiError] = None,
        var cancel_after_events: Optional[Int] = None,
    ) raises:
        if Bool(response) == Bool(error):
            raise Error("fake provider step requires exactly one response or error")
        if cancel_after_events and cancel_after_events.value() < 0:
            raise Error("fake provider cancellation index must not be negative")
        self.events = events^
        self.response = response^
        self.error = error^
        self.cancel_after_events = cancel_after_events^

    @staticmethod
    def success(
        var response: StreamResponse,
        var events: List[DomainProviderEvent] = List[DomainProviderEvent](),
        var cancel_after_events: Optional[Int] = None,
    ) raises -> Self:
        return Self(events^, Optional(response^), None, cancel_after_events^)

    @staticmethod
    def failure(
        var error: MochiError,
        var events: List[DomainProviderEvent] = List[DomainProviderEvent](),
        var cancel_after_events: Optional[Int] = None,
    ) raises -> Self:
        return Self(events^, None, Optional(error^), cancel_after_events^)


struct FakeProvider(Provider, Copyable, Movable):
    var steps: List[FakeProviderStep]
    var requests: List[CapturedProviderRequest]
    var models: List[ModelInfo]
    var last_error: Optional[MochiError]

    def __init__(out self):
        self.steps = List[FakeProviderStep]()
        self.requests = List[CapturedProviderRequest]()
        self.models = List[ModelInfo]()
        self.last_error = None

    def enqueue(mut self, var step: FakeProviderStep):
        self.steps.append(step^)

    def set_models(mut self, models: List[ModelInfo]):
        self.models = models.copy()

    def list_models(mut self) raises -> List[ModelInfo]:
        return self.models.copy()

    def _fail(mut self, error: MochiError) raises -> StreamResponse:
        self.last_error = Optional(error.copy())
        raise Error(provider_error_text(error))

    def stream_message[S: ProviderEventSink](
        mut self, request: ProviderRequest, mut sink: S
    ) raises -> StreamResponse:
        self.last_error = None
        self.requests.append(CapturedProviderRequest(request))
        if request.cancel.is_cancelled():
            return self._fail(MochiError.cancelled())
        if len(self.steps) == 0:
            return self._fail(
                MochiError.internal("fake provider: no scripted step")
            )
        var step = self.steps.pop(0)
        var emitted = 0
        if step.cancel_after_events and step.cancel_after_events.value() == 0:
            request.cancel.cancel()
        for event in step.events:
            if request.cancel.is_cancelled():
                return self._fail(MochiError.cancelled())
            sink.emit(event)
            emitted += 1
            if step.cancel_after_events and emitted == step.cancel_after_events.value():
                request.cancel.cancel()
        if request.cancel.is_cancelled():
            return self._fail(MochiError.cancelled())
        if step.error:
            return self._fail(step.error.value())
        return step.response.value().copy()


def provider_request_to_json(request: ProviderRequest) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("model", JsonValue.string(request.model.spec()))
    value.set("system", JsonValue.string(request.system))
    value.set("tools", request.tools.copy())
    value.set("thinking", JsonValue.integer(request.options.thinking.tag))
    value.set("fast", JsonValue.boolean(request.options.fast))
    if request.session_id:
        value.set("session_id", JsonValue.string(request.session_id.value()))
    return value^


def provider_event_to_json(event: DomainProviderEvent) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("tag", JsonValue.integer(event.tag))
    value.set("text", JsonValue.string(event.text))
    value.set("id", JsonValue.string(event.id))
    value.set("name", JsonValue.string(event.name))
    value.set("processed", JsonValue.integer(event.processed))
    value.set("total", JsonValue.integer(event.total))
    value.set("cache", JsonValue.integer(event.cache))
    return value^


def provider_error_text(error: MochiError) -> String:
    return (
        "provider:"
        + String(error.tag)
        + ":"
        + String(error.status)
        + ":"
        + error.tool
        + ":"
        + error.message
    )
