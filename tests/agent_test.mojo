from std.os import listdir, makedirs, remove, rmdir
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.agent import Agent, ScriptedProvider
from mochi.permissions import PermissionEffect, PermissionManager, PermissionRule
from mochi.tools import ToolRegistry
from mochi.types import CancellationToken, Message, ProviderEvent, ToolCall, Usage


comptime TEST_DIR = "/tmp/mochi-agent-test"


def clean() raises:
    try:
        for name in listdir(TEST_DIR):
            try:
                remove(TEST_DIR + "/" + name)
            except:
                pass
        rmdir(TEST_DIR)
    except:
        pass
    makedirs(TEST_DIR, exist_ok=True)


def allowed() -> PermissionManager:
    var permissions = PermissionManager()
    permissions.add_rule(PermissionRule("*", PermissionEffect.allow(), "*"))
    return permissions^


def test_streamed_partial_call_and_multi_turn_usage() raises:
    clean()
    with open(TEST_DIR + "/input.txt", "w") as file:
        file.write("hello")
    var provider = ScriptedProvider()
    provider.add_turn([
        ProviderEvent.text_delta("checking "),
        ProviderEvent.tool_call_delta(ToolCall("call-1", "re", "{\"path\":\"input")),
        ProviderEvent.tool_call_delta(ToolCall("call-1", "ad", ".txt\"}")),
        ProviderEvent.usage_event(Usage(3, 2)),
        ProviderEvent.done("tool_calls"),
    ])
    provider.add_turn([
        ProviderEvent.text_delta("done"),
        ProviderEvent.usage_event(Usage(4, 1)),
        ProviderEvent.done("stop"),
    ])
    var agent = Agent(provider^, ToolRegistry(TEST_DIR), allowed())
    var result = agent.run("inspect", CancellationToken())
    assert_equal(result.text, "done")
    assert_equal(result.turns, 2)
    assert_equal(result.stop_reason, "end_turn")
    assert_equal(result.usage.input_tokens, 7)
    assert_equal(result.usage.output_tokens, 3)
    assert_equal(len(result.messages), 4)
    assert_equal(result.messages[2].role, "tool")
    assert_equal(result.messages[2].content, "hello")


def test_prepare_authorize_execute_and_practical_builtins() raises:
    clean()
    var registry = ToolRegistry(TEST_DIR)
    var permissions = allowed()
    var write = registry.prepare("write", "{\"path\":\"a.txt\",\"content\":\"one\"}")
    assert_equal(write.scopes[0], TEST_DIR + "/a.txt")
    assert_true(registry.authorize(write, permissions).effect == PermissionEffect.allow())
    assert_true(registry.execute(write).ok)
    assert_equal(open(TEST_DIR + "/a.txt", "r").read(), "one")
    var edit = registry.prepare("edit", "{\"path\":\"a.txt\",\"old_string\":\"one\",\"new_string\":\"two\"}")
    assert_true(registry.execute(edit).ok)
    assert_equal(open(TEST_DIR + "/a.txt", "r").read(), "two")
    var listing = registry.execute(registry.prepare("list", "{\"path\":\".\"}"))
    assert_true("a.txt" in listing.content)
    var shell = registry.execute(registry.prepare("bash", "{\"command\":\"printf mojo\"}"))
    assert_true(shell.ok)
    assert_true("mojo" in shell.content)
    var cwd = registry.execute(
        registry.prepare("bash", "{\"command\":\"pwd\"}")
    )
    assert_true(TEST_DIR in cwd.content)
    var failed = registry.execute(
        registry.prepare("bash", "{\"command\":\"printf bad; exit 7\"}")
    )
    assert_false(failed.ok)
    assert_true('"exit_code":7' in failed.content)
    assert_true("bad" in failed.content)


def test_permission_denial_does_not_execute() raises:
    clean()
    var provider = ScriptedProvider()
    provider.add_turn([
        ProviderEvent.tool_call_delta(ToolCall("w", "write", "{\"path\":\"blocked\",\"content\":\"x\"}")),
        ProviderEvent.done("tool_calls"),
    ])
    provider.add_turn([ProviderEvent.text_delta("ok"), ProviderEvent.done("stop")])
    var permissions = PermissionManager(PermissionEffect.deny())
    var agent = Agent(provider^, ToolRegistry(TEST_DIR), permissions^)
    var result = agent.run("try", CancellationToken())
    assert_true("Permission denied" in result.messages[2].content)
    assert_false(exists(TEST_DIR + "/blocked"))


def test_code_execution_mini_interpreter_subagent_bound() raises:
    var registry = ToolRegistry(TEST_DIR, max_subagents=2)
    registry.add_subagent_response("first", "A")
    registry.add_subagent_response("second", "B")
    var disabled = registry.execute(
        registry.prepare(
            "code_execution", '{"code":"SUBAGENT first"}'
        )
    )
    assert_false(disabled.ok)
    assert_true("workflow mode" in disabled.content)
    var task_disabled = registry.execute(
        registry.prepare("task", '{"description":"research","prompt":"first"}')
    )
    assert_false(task_disabled.ok)
    registry.set_workflow(True)
    var task_result = registry.execute(
        registry.prepare("task", '{"description":"research","prompt":"first"}')
    )
    assert_true(task_result.ok)
    assert_equal(task_result.content, "A")
    var prepared = registry.prepare("code_execution", "{\"code\":\"ECHO start\\nSUBAGENT second\"}")
    var result = registry.execute(prepared)
    assert_true(result.ok)
    assert_true("start" in result.content)
    assert_true("B" in result.content)
    var exceeded = registry.execute(registry.prepare("code_execution", "{\"code\":\"SUBAGENT first\"}"))
    assert_false(exceeded.ok)
    assert_true("limit exceeded" in exceeded.content)


def test_cancellation_max_turns_and_compaction() raises:
    var cancelled_provider = ScriptedProvider()
    var cancelled_agent = Agent(cancelled_provider^, ToolRegistry(TEST_DIR), allowed())
    var token = CancellationToken()
    token.cancel()
    var cancelled = cancelled_agent.run("stop", token)
    assert_equal(cancelled.stop_reason, "cancelled")
    assert_equal(cancelled.turns, 0)

    var provider = ScriptedProvider()
    provider.add_turn([ProviderEvent.tool_call_delta(ToolCall("1", "code_execution", "{\"code\":\"ECHO x\"}")), ProviderEvent.done("tool_calls")])
    var limited = Agent(provider^, ToolRegistry(TEST_DIR), allowed(), max_turns=1)
    var maxed = limited.run("go", CancellationToken())
    assert_equal(maxed.stop_reason, "max_turns")
    assert_equal(maxed.turns, 1)

    var compact_provider = ScriptedProvider()
    compact_provider.add_turn([ProviderEvent.text_delta("final"), ProviderEvent.done("stop")])
    var compact = Agent(compact_provider^, ToolRegistry(TEST_DIR), allowed(), max_context_chars=5, compact_keep=1)
    compact.messages.append(Message("old", "long old content"))
    var compacted = compact.run("new long prompt", CancellationToken())
    assert_true(compacted.compactions > 0)
    assert_equal(compacted.messages[0].role, "system")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
