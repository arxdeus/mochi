from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.permissions import (
    PermissionAnswer,
    PermissionEffect,
    PermissionManager,
    PermissionRule,
    glob_matches,
    scope_matches,
)


def test_scope_matching() raises:
    assert_true(scope_matches("*", "anything"))
    assert_true(scope_matches("/workspace/**", "/workspace"))
    assert_true(scope_matches("/workspace/**", "/workspace/src/main.mojo"))
    assert_false(scope_matches("/workspace/**", "/workspace-other/file"))
    assert_true(scope_matches("git *", "git status"))
    assert_true(scope_matches("git *", "git"))
    assert_true(scope_matches("https://api/*", "https://api/models"))
    assert_false(scope_matches("exact", "exactly"))


def test_tool_glob_matching() raises:
    assert_true(glob_matches("*", "bash"))
    assert_true(glob_matches("mcp_*_read", "mcp_files_read"))
    assert_false(glob_matches("read_*", "write_file"))


def test_allow_and_prompt_scopes() raises:
    var manager = PermissionManager()
    manager.add_rule(PermissionRule("read", PermissionEffect.allow(), "/safe/**"))
    var decision = manager.check("read", ["/safe/a", "/other/b"])
    assert_true(decision.effect == PermissionEffect.prompt())
    assert_equal(len(decision.scopes), 1)
    assert_equal(decision.scopes[0], "/other/b")


def test_deny_precedes_allow_and_yolo() raises:
    var manager = PermissionManager(yolo=True)
    manager.add_rule(PermissionRule("*", PermissionEffect.allow(), "*"))
    manager.add_rule(PermissionRule("bash", PermissionEffect.deny(), "rm *"))
    var decision = manager.check("bash", ["echo ok", "rm file"])
    assert_true(decision.effect == PermissionEffect.deny())


def test_force_prompt_and_default_deny() raises:
    var prompt_manager = PermissionManager()
    prompt_manager.add_rule(PermissionRule("read", PermissionEffect.allow(), "*"))
    var prompted = prompt_manager.check("read", ["file"], force_prompt=True)
    assert_true(prompted.effect == PermissionEffect.prompt())
    assert_equal(len(prompted.scopes), 1)

    var deny_manager = PermissionManager(PermissionEffect.deny())
    var denied = deny_manager.check("write", ["file"])
    assert_true(denied.effect == PermissionEffect.deny())


def test_permission_answers_and_session_rules() raises:
    var manager = PermissionManager()
    var scopes: List[String] = ["cargo test --all"]
    manager.apply_decision("bash", scopes, PermissionAnswer.allow_once())
    assert_equal(len(manager.rules), 0)
    manager.apply_decision("bash", scopes, PermissionAnswer.allow_session())
    assert_equal(len(manager.rules), 1)
    assert_equal(manager.rules[0].scope, "cargo *")
    assert_true(
        manager.check("bash", ["cargo build"]).effect
        == PermissionEffect.allow()
    )
    manager.apply_decision("bash", scopes, PermissionAnswer.allow_session())
    assert_equal(len(manager.rules), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
