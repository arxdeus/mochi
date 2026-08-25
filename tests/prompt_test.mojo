from std.os import listdir, makedirs, remove, rmdir
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.prompt import (
    build_system_prompt,
    is_instruction_file,
    load_instruction_text_from,
)


comptime ROOT = "/tmp/mochi-prompt-test"


def _clean() raises:
    try:
        for path in [
            ROOT + "/project/src/AGENTS.local.md",
            ROOT + "/project/AGENTS.md",
            ROOT + "/config/AGENTS.md",
        ]:
            try:
                remove(path)
            except:
                pass
        for path in [
            ROOT + "/project/src",
            ROOT + "/project/.git",
            ROOT + "/project",
            ROOT + "/config",
            ROOT,
        ]:
            try:
                rmdir(path)
            except:
                pass
    except:
        pass
    makedirs(ROOT + "/project/src", exist_ok=True)
    makedirs(ROOT + "/project/.git", exist_ok=True)
    makedirs(ROOT + "/config", exist_ok=True)


def test_instruction_file_names() raises:
    assert_true(is_instruction_file("AGENTS.md"))
    assert_true(is_instruction_file("CLAUDE.md"))
    assert_true(is_instruction_file("copilot-instructions.md"))
    assert_true(is_instruction_file("AGENTS.local.md"))
    assert_false(is_instruction_file("random.md"))


def test_instruction_order_and_system_prompt() raises:
    _clean()
    with open(ROOT + "/project/AGENTS.md", "w") as file:
        file.write("root")
    with open(ROOT + "/project/src/AGENTS.local.md", "w") as file:
        file.write("local")
    with open(ROOT + "/config/AGENTS.md", "w") as file:
        file.write("global")
    var loaded = load_instruction_text_from(
        ROOT + "/project/src", ROOT + "/config"
    )
    assert_true(loaded.find("root").value() < loaded.find("local").value())
    assert_true(loaded.find("local").value() < loaded.find("global").value())
    var prompt = build_system_prompt(
        ROOT + "/project/src",
        "openai/gpt-test",
        "macos",
        "2026-08-26",
        loaded,
    )
    assert_true("Working directory: " + ROOT + "/project/src" in prompt)
    assert_true("Model: openai/gpt-test" in prompt)
    assert_true("Project instructions" in prompt)
    assert_true("Global instructions" in prompt)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
