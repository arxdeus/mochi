from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from mochi.domain import (
    DomainMessage,
    DomainProviderEvent,
    MochiError,
    Model,
    ModelFamily,
    ModelInfo,
    ModelPricing,
    ModelTier,
    StopReason,
    StreamResponse,
    ThinkingSupport,
    TokenUsage,
)
from mochi.json import JsonValue
from mochi.provider_contract import (
    FakeProvider,
    FakeProviderStep,
    ProviderEventSink,
    ProviderRequest,
    RequestOptions,
    ThinkingConfig,
    ThinkingEffort,
    provider_event_to_json,
    provider_request_to_json,
)
from mochi.types import CancellationToken


struct RecordingSink(ProviderEventSink, Copyable, Movable):
    var events: List[DomainProviderEvent]

    def __init__(out self):
        self.events = List[DomainProviderEvent]()

    def emit(mut self, event: DomainProviderEvent) raises:
        self.events.append(event.copy())


def _model(thinking: ThinkingSupport = ThinkingSupport.yes()) -> Model:
    return Model(
        "test-model",
        "test-provider",
        ModelTier.medium(),
        ModelFamily.generic(),
        thinking.copy(),
        None,
        ModelPricing(),
        Optional(4096),
        32768,
    )


def _response(text: String = "done") -> StreamResponse:
    return StreamResponse(
        DomainMessage.assistant(text), TokenUsage(), Optional(StopReason.end_turn())
    )


def test_request_capture_ordered_events_and_response() raises:
    var events: List[DomainProviderEvent] = [
        DomainProviderEvent.text_delta("a"),
        DomainProviderEvent.thinking_delta("b"),
        DomainProviderEvent.tool_use_start("call-1", "read"),
        DomainProviderEvent.prompt_progress(2, 3, 1),
    ]
    var fake = FakeProvider()
    fake.enqueue(FakeProviderStep.success(_response("complete"), events^))
    var messages: List[DomainMessage] = [DomainMessage.user("hello")]
    var tools = JsonValue.array()
    tools.append(JsonValue.string("read"))
    var options = RequestOptions(ThinkingConfig.adaptive(), True)
    var request = ProviderRequest(
        _model(),
        CancellationToken(),
        messages^,
        "system",
        tools^,
        options^,
        Optional("session-1"),
    )
    var sink = RecordingSink()
    var response = fake.stream_message(request, sink)

    assert_equal(response.message.content[0].text, "complete")
    assert_equal(len(sink.events), 4)
    assert_true(sink.events[0].is_text_delta())
    assert_true(sink.events[1].is_thinking_delta())
    assert_true(sink.events[2].is_tool_use_start())
    assert_true(sink.events[3].is_prompt_progress())
    assert_equal(len(fake.requests), 1)
    assert_equal(fake.requests[0].model.spec(), "test-provider/test-model")
    assert_equal(fake.requests[0].messages[0].content[0].text, "hello")
    assert_equal(fake.requests[0].system, "system")
    assert_equal(fake.requests[0].session_id.value(), "session-1")
    assert_false(fake.requests[0].cancelled_at_entry)


def test_fifo_exhaustion_and_typed_error() raises:
    var fake = FakeProvider()
    fake.enqueue(FakeProviderStep.success(_response("first")))
    fake.enqueue(FakeProviderStep.failure(MochiError.api(429, "slow")))
    var sink = RecordingSink()
    assert_equal(
        fake.stream_message(ProviderRequest(_model(), CancellationToken()), sink).message.content[0].text,
        "first",
    )
    with assert_raises():
        _ = fake.stream_message(ProviderRequest(_model(), CancellationToken()), sink)
    assert_true(fake.last_error)
    assert_equal(fake.last_error.value().status, 429)
    assert_true(fake.last_error.value().is_retryable())
    with assert_raises():
        _ = fake.stream_message(ProviderRequest(_model(), CancellationToken()), sink)
    assert_true(fake.last_error)
    assert_equal(fake.last_error.value().message, "fake provider: no scripted step")


def test_pre_cancel_and_midstream_cancel() raises:
    var fake = FakeProvider()
    fake.enqueue(FakeProviderStep.success(_response()))
    var cancelled = CancellationToken()
    cancelled.cancel()
    var sink = RecordingSink()
    with assert_raises():
        _ = fake.stream_message(
            ProviderRequest(_model(), cancelled.copy()), sink
        )
    assert_equal(len(sink.events), 0)
    assert_equal(fake.last_error.value().tag, MochiError.CANCELLED)

    var mid = FakeProvider()
    var events: List[DomainProviderEvent] = [
        DomainProviderEvent.text_delta("first"),
        DomainProviderEvent.text_delta("second"),
    ]
    mid.enqueue(
        FakeProviderStep.success(_response(), events^, Optional(1))
    )
    var mid_sink = RecordingSink()
    with assert_raises():
        _ = mid.stream_message(ProviderRequest(_model(), CancellationToken()), mid_sink)
    assert_equal(len(mid_sink.events), 1)
    assert_equal(mid_sink.events[0].text, "first")
    assert_equal(mid.last_error.value().tag, MochiError.CANCELLED)


def test_option_clamping_and_model_listing() raises:
    var requested = RequestOptions(ThinkingConfig.adaptive(), True)
    var unsupported = requested.clamped(_model(ThinkingSupport.no()))
    assert_true(unsupported.thinking.is_off())
    assert_false(unsupported.fast)
    var fast_model = _model()
    fast_model.provider = "anthropic"
    fast_model.id = "claude-opus-4-6"
    assert_true(requested.clamped(fast_model).fast)
    var required = RequestOptions().clamped(
        _model(ThinkingSupport.required())
    )
    assert_equal(required.thinking.tag, ThinkingConfig.EFFORT)
    assert_equal(required.thinking.effort.tag, ThinkingEffort.MINIMAL)

    var current = ThinkingConfig.off()
    assert_equal(ThinkingConfig.parse("", current).value().display(), "adaptive")
    assert_equal(
        ThinkingConfig.parse("high", current).value().display(), "high"
    )
    assert_equal(
        ThinkingConfig.parse("8192", current).value().display(), "8192"
    )
    assert_false(ThinkingConfig.parse("0", current))
    assert_false(ThinkingConfig.parse("garbage", current))

    var fake = FakeProvider()
    var listed: List[ModelInfo] = [
        ModelInfo.id_only("one"), ModelInfo.id_only("two")
    ]
    fake.set_models(listed)
    var models = fake.list_models()
    assert_equal(len(models), 2)
    assert_equal(models[1].id, "two")


def test_fake_step_requires_one_outcome() raises:
    with assert_raises():
        _ = FakeProviderStep()
    with assert_raises():
        _ = FakeProviderStep(
            response=Optional(_response()),
            error=Optional(MochiError.internal("both")),
        )


def test_provider_contract_golden_codecs() raises:
    var request = ProviderRequest(
        _model(), CancellationToken(), system="system", session_id=Optional("s")
    )
    assert_equal(
        provider_request_to_json(request).serialize(),
        '{"model":"test-provider/test-model","system":"system","tools":[],"thinking":0,"fast":false,"session_id":"s"}',
    )
    assert_equal(
        provider_event_to_json(
            DomainProviderEvent.prompt_progress(2, 3, 1)
        ).serialize(),
        '{"tag":3,"text":"","id":"","name":"","processed":2,"total":3,"cache":1}',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
