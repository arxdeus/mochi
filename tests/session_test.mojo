from std.os import listdir, makedirs, remove, rmdir
from std.testing import TestSuite, assert_equal, assert_true
from mochi.json import JsonValue, parse_json
from mochi.session import Session, SessionStore


comptime TEST_DIR = "/tmp/mochi-session-test"


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


def message(role: String, text: String) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("role", JsonValue.string(role))
    value.set("content", JsonValue.string(text))
    return value^


def test_maki_v2_roundtrip() raises:
    clean()
    var store = SessionStore(TEST_DIR)
    var session = Session("01965087-4c71-7f00-8000-000000000000", "model", "/project", 10)
    session.title = "Saved"
    session.updated_at = 20
    session.add_message(message("user", "hello"))
    session.set_output("tool-1", JsonValue.string("done"))
    session.add_subagent_message("sub-1", message("assistant", "child"))
    session.meta.set("fast", JsonValue.boolean(True))
    store.save(session)

    var loaded = store.load(session.id)
    assert_equal(loaded.id, session.id)
    assert_equal(loaded.title, "Saved")
    assert_equal(len(loaded.messages), 1)
    assert_equal(loaded.outputs[0].string_value, "done")
    assert_true(loaded.meta.get("fast").bool_value)
    var first = parse_json(String(open(store.path(session.id), "r").read().split("\n")[0]))
    assert_equal(first.get("t").string_value, "header")
    assert_equal(first.get("v").int_value, 2)


def test_truncated_tail_recovery() raises:
    clean()
    var store = SessionStore(TEST_DIR)
    var session = Session("tail", "model", "/project", 1)
    session.title = "Before tail"
    session.updated_at = 5
    session.add_message(message("user", "kept"))
    store.save(session)
    with open(store.path(session.id), "a") as file:
        file.write("{\"t\":\"msg\",\"d\":{\"role\":\"assistant\"")

    var loaded = store.load(session.id)
    assert_equal(loaded.title, "Before tail")
    assert_equal(len(loaded.messages), 1)
    assert_equal(loaded.messages[0].get("content").string_value, "kept")


def test_list_and_latest_cwd_index() raises:
    clean()
    var store = SessionStore(TEST_DIR)
    var old = Session("old", "m", "/project", 1)
    old.title = "Old"
    old.updated_at = 10
    store.save(old)
    var other = Session("other", "m", "/other", 2)
    other.updated_at = 30
    store.save(other)
    var new = Session("new", "m", "/project", 3)
    new.title = "New"
    new.updated_at = 20
    store.save(new)

    var summaries = store.list("/project")
    assert_equal(len(summaries), 2)
    assert_equal(summaries[0].id, "new")
    var latest = store.latest("/project")
    assert_true(latest)
    assert_equal(latest.value().id, "new")

    with open(TEST_DIR + "/cwd_latest.json", "w") as file:
        file.write("{\"/project\":\"missing\"}")
    latest = store.latest("/project")
    assert_true(latest)
    assert_equal(latest.value().id, "new")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
