from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mochi.invocation import (
    FakeInvocationAdapter,
    InvocationAudience,
    InvocationDefinition,
    InvocationEvent,
    InvocationRequest,
    InvocationResult,
    InvocationSource,
    InvocationTrace,
    invocation_definition_to_json,
    invocation_result_to_json,
)
from mochi.json import JsonValue, parse_json
from mochi.tools import ToolResult
from mochi.types import CancellationToken


def test_audience_flags_and_sources() raises:
    var combined = InvocationAudience.main().combined(
        InvocationAudience.interpreter()
    )
    assert_true(combined.contains(InvocationAudience.main()))
    assert_true(combined.contains(InvocationAudience.interpreter()))
    assert_false(
        InvocationAudience.main().intersects(InvocationAudience.workflow())
    )
    assert_true(InvocationAudience(255) == InvocationAudience.all())

    assert_true(InvocationSource.builtin().is_builtin())
    var mcp = InvocationSource.mcp("files")
    assert_true(mcp.is_mcp())
    assert_equal(mcp.owner, "files")
    assert_true(InvocationSource.plugin("formatter").is_plugin())
    assert_true(InvocationSource.host("ui").is_host())
    assert_true(InvocationSource.subagent("task").is_subagent())


def test_definition_request_and_tool_result_adapters() raises:
    var schema = JsonValue.object()
    schema.set("type", JsonValue.string("object"))
    var definition = InvocationDefinition(
        "search",
        "Search files",
        schema^,
        InvocationAudience.main(),
        InvocationSource.plugin("search-plugin"),
    )
    assert_equal(definition.name, "search")
    assert_equal(definition.input_schema.get("type").string_value, "object")
    assert_true(definition.source.is_plugin())

    var arguments = JsonValue.object()
    arguments.set("query", JsonValue.string("mojo"))
    var request = InvocationRequest(
        "call-1", "search", CancellationToken(), arguments^
    )
    assert_equal(request.arguments.get("query").string_value, "mojo")
    assert_true(request.audience == InvocationAudience.main())

    var invocation_result = InvocationResult.from_tool_result(
        ToolResult.success("found")
    )
    assert_true(invocation_result.ok)
    assert_equal(invocation_result.content, "found")
    var tool_result = InvocationResult.failure("bad").to_tool_result()
    assert_false(tool_result.ok)
    assert_equal(tool_result.content, "bad")


def test_trace_factories_and_bound() raises:
    var request = InvocationRequest("call-1", "search", CancellationToken())
    var success = InvocationResult.success("done")
    var failure = InvocationResult.failure("failed")
    assert_true(InvocationEvent.started(request).is_started())
    assert_true(InvocationEvent.completed(request, success).is_completed())
    assert_true(InvocationEvent.failed(request, failure).is_failed())

    var trace = InvocationTrace(1)
    trace.append(InvocationEvent.started(request))
    trace.append(InvocationEvent.completed(request, success))
    assert_equal(len(trace.events), 1)
    assert_true(trace.events[0].is_completed())
    assert_equal(trace.dropped_events, 1)
    trace.clear()
    assert_equal(len(trace.events), 0)
    assert_equal(trace.dropped_events, 0)
    with assert_raises():
        _ = InvocationTrace(-1)


def test_fake_adapter_fifo_trace_and_missing_fixture() raises:
    var adapter = FakeInvocationAdapter()
    adapter.register(
        InvocationDefinition("search", audience=InvocationAudience.main())
    )
    adapter.enqueue("search", InvocationResult.success("first"))
    adapter.enqueue("search", InvocationResult.failure("second"))

    var first = adapter.invoke(InvocationRequest("call-1", "search", CancellationToken()))
    var second = adapter.invoke(InvocationRequest("call-2", "search", CancellationToken()))
    var missing = adapter.invoke(InvocationRequest("call-3", "search", CancellationToken()))
    assert_true(first.ok)
    assert_equal(first.content, "first")
    assert_false(second.ok)
    assert_equal(second.content, "second")
    assert_false(missing.ok)
    assert_equal(missing.content, "no invocation result queued: search")
    assert_equal(len(adapter.trace.events), 6)
    assert_true(adapter.trace.events[0].is_started())
    assert_true(adapter.trace.events[1].is_completed())
    assert_true(adapter.trace.events[3].is_failed())
    assert_equal(adapter.trace.events[4].request_id, "call-3")


def test_fake_adapter_validation_and_bounds() raises:
    var adapter = FakeInvocationAdapter(1, 1, 2)
    adapter.register(
        InvocationDefinition(
            "workflow-only", audience=InvocationAudience.workflow()
        )
    )
    with assert_raises():
        adapter.register(InvocationDefinition("workflow-only"))
    with assert_raises():
        adapter.register(InvocationDefinition("other"))
    with assert_raises():
        adapter.enqueue("missing", InvocationResult.success("x"))

    adapter.enqueue("workflow-only", InvocationResult.success("ok"))
    with assert_raises():
        adapter.enqueue("workflow-only", InvocationResult.success("overflow"))
    var denied = adapter.invoke(
        InvocationRequest("call-main", "workflow-only", CancellationToken())
    )
    assert_false(denied.ok)
    assert_equal(denied.status, InvocationResult.REJECTED)
    var result = adapter.invoke(
        InvocationRequest(
            "call-workflow",
            "workflow-only",
            CancellationToken(),
            audience=InvocationAudience.workflow(),
        )
    )
    assert_true(result.ok)
    var missing = adapter.invoke(
        InvocationRequest("call-missing", "missing", CancellationToken())
    )
    assert_false(missing.ok)
    assert_equal(missing.status, InvocationResult.REJECTED)


def test_invocation_golden_codecs() raises:
    var definition = InvocationDefinition(
        "search",
        "Search",
        source=InvocationSource.mcp("files"),
    )
    assert_equal(
        invocation_definition_to_json(definition).serialize(),
        '{"name":"search","description":"Search","input_schema":{},"audience":31,"source":1,"owner":"files"}',
    )
    assert_equal(
        invocation_result_to_json(InvocationResult.cancelled()).serialize(),
        '{"ok":false,"status":3,"content":"cancelled","output_kind":"plain","structured":null,"instructions":[],"state":null,"image":null}',
    )


def test_maki_compatible_plugin_result_decode() raises:
    var decoded = InvocationResult.from_json(
        parse_json(
            '{"llm_output":"failed safely","is_error":true,"ok":true,"format":"markdown","annotation":"warning","instructions":[{"path":"AGENTS.md","content":"retry"},"ignored"],"state":{"attempt":2},"written_path":"out.txt","image":{"media_type":"image/png","data":"aGVsbG8="}}'
        )
    )
    assert_false(decoded.ok)
    assert_equal(decoded.content, "failed safely")
    assert_equal(decoded.output_kind, "markdown")
    assert_equal(decoded.annotation.value(), "warning")
    assert_equal(
        decoded.instructions.array_value[0].get("content").string_value,
        "retry",
    )
    assert_equal(decoded.state.get("attempt").int_value, 2)
    assert_equal(decoded.written_path.value(), "out.txt")
    assert_equal(decoded.image.get("media_type").string_value, "image/png")
    assert_true(InvocationResult.from_json(JsonValue.string("plain")).ok)
    with assert_raises():
        _ = InvocationResult.from_json(parse_json('{"is_error":false}'))
    assert_equal(
        len(
            InvocationResult.from_json(
                parse_json('{"llm_output":"x","instructions":"bad"}')
            ).instructions.array_value
        ),
        0,
    )
    with assert_raises():
        _ = InvocationResult.from_json(
            parse_json(
                '{"llm_output":"x","image":{"media_type":"image/png","data":"bad"}}'
            )
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
