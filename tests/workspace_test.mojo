from std.os import makedirs, remove
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from mochi.json import JsonValue
from mochi.workspace import InputHistory, NoteStore, PreferenceStore, project_id


comptime ROOT = "/tmp/mochi-workspace-test"


def test_input_history_dedup_and_bound() raises:
    var path = ROOT + "/history"
    try:
        remove(path)
    except:
        pass
    var history = InputHistory(path, 2)
    history.add("one")
    history.add("one")
    history.add("two")
    history.add("three")
    assert_equal(len(history.entries), 2)
    assert_equal(history.entries[0], "two")
    var loaded = InputHistory(path, 2)
    loaded.load()
    assert_equal(loaded.entries[1], "three")


def test_note_and_plan_store() raises:
    var notes = NoteStore(ROOT + "/notes")
    notes.write("architecture", "content")
    notes.write("plan", "steps")
    assert_equal(notes.read("architecture"), "content")
    var names = notes.list()
    assert_equal(names[0], "architecture")
    assert_equal(names[1], "plan")
    notes.delete("architecture")
    with assert_raises():
        _ = notes.write("../escape", "bad")


def test_preferences_and_project_id() raises:
    var path = ROOT + "/preferences.json"
    try:
        remove(path)
    except:
        pass
    var preferences = PreferenceStore(path)
    preferences.set("theme", JsonValue.string("dracula"))
    var loaded = PreferenceStore(path)
    loaded.load()
    assert_equal(loaded.get("theme").value().string_value, "dracula")
    assert_false(loaded.get("missing"))
    assert_equal(project_id("/project"), project_id("/project"))
    assert_true(project_id("/project") != project_id("/other"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
