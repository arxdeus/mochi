from std.os import makedirs, remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from mochi.json import JsonValue, parse_json
from mochi.workspace import (
    InputHistory,
    MAX_ENTRIES,
    NoteStore,
    PreferenceStore,
    project_id,
)


comptime ROOT = "/tmp/mochi-workspace-test"


def clear_history(directory: String):
    try:
        remove(directory + "/input_history.json")
    except:
        pass
    try:
        remove(directory + "/input_history.json.tmp")
    except:
        pass


def test_input_history_json_roundtrip_trim_dedup_and_bound() raises:
    var directory = ROOT + "/history-roundtrip"
    clear_history(directory)
    var history = InputHistory(directory, 3)
    assert_equal(history.path, directory + "/input_history.json")
    history.add("")
    history.add(" \n\t ")
    history.add("  one  ")
    history.add("one")
    history.add("two")
    history.add("one")
    history.add("three")
    assert_equal(len(history.entries), 3)
    assert_equal(history.entries[0], "two")
    assert_equal(history.entries[1], "one")
    assert_equal(history.entries[2], "three")
    var encoded = open(history.path, "r").read()
    assert_equal(encoded, '["two","one","three"]')
    assert_equal(parse_json(encoded).kind, JsonValue.ARRAY)
    assert_false(exists(history.path + ".tmp"))
    var loaded = InputHistory(directory, 3)
    loaded.load()
    assert_equal(len(loaded.entries), 3)
    assert_equal(loaded.entries[0], "two")
    assert_equal(loaded.entries[2], "three")


def test_input_history_default_cap_and_load_trim_to_cap() raises:
    var directory = ROOT + "/history-cap"
    clear_history(directory)
    var history = InputHistory(directory)
    assert_equal(history.max_entries, MAX_ENTRIES)
    for index in range(150):
        history.push("entry" + String(index))
    assert_equal(len(history.entries), 100)
    assert_equal(history.entries[0], "entry50")
    assert_equal(history.entries[99], "entry149")
    history.save()
    var loaded = InputHistory(directory, 10)
    loaded.load()
    assert_equal(len(loaded.entries), 10)
    assert_equal(loaded.entries[0], "entry140")
    assert_equal(loaded.entries[9], "entry149")


def test_input_history_missing_or_corrupt_is_empty() raises:
    var directory = ROOT + "/history-bad-state"
    clear_history(directory)
    var history = InputHistory(directory)
    history.push("stale")
    history.load()
    assert_equal(len(history.entries), 0)
    makedirs(directory, exist_ok=True)
    with open(history.path, "w") as file:
        file.write("not json")
    history.push("stale")
    history.load()
    assert_equal(len(history.entries), 0)
    with open(history.path, "w") as file:
        file.write('["valid",1]')
    history.push("stale")
    history.load()
    assert_equal(len(history.entries), 0)


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
