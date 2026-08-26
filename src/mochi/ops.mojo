from std.ffi import CStringSlice, c_int, external_call
from std.os import makedirs, remove
from std.os.path import exists

from mochi.json import JsonValue


struct StructuredLogger(Copyable, Movable):
    var path: String
    var max_bytes: Int
    var backups: Int

    def __init__(out self, path: String, max_bytes: Int = 10485760, backups: Int = 3):
        self.path = path
        self.max_bytes = max_bytes
        self.backups = backups

    def log(
        mut self,
        level: String,
        event: String,
        message: String,
        var fields: JsonValue = JsonValue.object(),
    ) raises:
        self._rotate_if_needed()
        _ensure_parent(self.path)
        var value = JsonValue.object()
        value.set("level", JsonValue.string(level))
        value.set("event", JsonValue.string(event))
        value.set("message", JsonValue.string(message))
        value.set("fields", fields^)
        with open(self.path, "a") as file:
            file.write(value.serialize() + "\n")

    def _rotate_if_needed(mut self) raises:
        if not exists(self.path):
            return
        var content = open(self.path, "r").read()
        if content.byte_length() < self.max_bytes:
            return
        if self.backups <= 0:
            remove(self.path)
            return
        for reverse in range(self.backups):
            var index = self.backups - reverse
            var destination = self.path + "." + String(index)
            var source = self.path if index == 1 else self.path + "." + String(index - 1)
            if exists(destination):
                remove(destination)
            if exists(source):
                _rename(source, destination)


@fieldwise_init
struct TelemetryEvent(Copyable, Movable):
    var name: String
    var attributes: JsonValue

    def to_json(self) raises -> JsonValue:
        var value = JsonValue.object()
        value.set("name", JsonValue.string(self.name))
        value.set("attributes", self.attributes.copy())
        return value^


def compare_versions(left: String, right: String) -> Int:
    var left_parts = String(left.removeprefix("v")).split(".")
    var right_parts = String(right.removeprefix("v")).split(".")
    var count = max(len(left_parts), len(right_parts))
    for i in range(count):
        var left_value = 0 if i >= len(left_parts) else _version_part(String(left_parts[i]))
        var right_value = 0 if i >= len(right_parts) else _version_part(String(right_parts[i]))
        if left_value < right_value:
            return -1
        if left_value > right_value:
            return 1
    return 0


def is_newer_version(candidate: String, current: String) -> Bool:
    if not _valid_release_version(candidate) or not _valid_release_version(current):
        return False
    return compare_versions(candidate, current) > 0


def _valid_release_version(value: String) -> Bool:
    var parts = value.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if String(part) == "":
            return False
        for cp in String(part).codepoints():
            var digit = Int(cp.to_u32()) - 48
            if digit < 0 or digit > 9:
                return False
    return True


@fieldwise_init
struct UpdatePlan(Copyable, Movable):
    var current: String
    var latest: String
    var executable: String
    var backup: String
    var update_available: Bool


def plan_update(current: String, latest: String, executable: String) -> UpdatePlan:
    var separator = -1
    for i in range(executable.byte_length()):
        if String(executable[byte=i]) == "/":
            separator = i
    var directory = String(".")
    if separator >= 0:
        directory = _prefix(executable, separator)
    return UpdatePlan(
        current,
        latest,
        executable,
        directory + "/mochi_backup",
        is_newer_version(latest, current),
    )


def backup_binary(executable: String, backup: String) raises:
    if not exists(executable):
        raise Error("executable does not exist: " + executable)
    _ensure_parent(backup)
    _copy_file(executable, backup)


def restore_backup(backup: String, executable: String) raises:
    if not exists(backup):
        raise Error("no backup found at " + backup)
    var temporary = executable + ".mochi_tmp"
    _copy_file(backup, temporary)
    _rename(temporary, executable)


def replace_from_download(
    downloaded: String, executable: String, backup: String
) raises:
    if not exists(downloaded):
        raise Error("downloaded binary does not exist: " + downloaded)
    backup_binary(executable, backup)
    var temporary = executable + ".mochi_tmp"
    _copy_file(downloaded, temporary)
    try:
        _rename(temporary, executable)
    except error:
        if exists(temporary):
            remove(temporary)
        raise error


def _copy_file(source: String, destination: String) raises:
    var owned_source = source
    var owned_destination = destination
    var status = external_call[
        "mochi_copy_file", c_int, CStringSlice[ImmutAnyOrigin], CStringSlice[ImmutAnyOrigin]
    ](
        rebind[CStringSlice[ImmutAnyOrigin]](owned_source.as_c_string_slice()),
        rebind[CStringSlice[ImmutAnyOrigin]](owned_destination.as_c_string_slice()),
    )
    if status != 0:
        raise Error("binary copy failed with status " + String(status))


def _prefix(value: String, count: Int) -> String:
    var output = String("")
    for i in range(count):
        output += String(value[byte=i])
    return output^


def _version_part(part: String) -> Int:
    var result = 0
    for cp in part.codepoints():
        var digit = Int(cp.to_u32()) - 48
        if digit < 0 or digit > 9:
            break
        result = result * 10 + digit
    return result


def _rename(source: String, destination: String) raises:
    var source_copy = source
    var destination_copy = destination
    var status = external_call["rename", c_int](
        source_copy.as_c_string_slice().unsafe_ptr(),
        destination_copy.as_c_string_slice().unsafe_ptr(),
    )
    if status != 0:
        raise Error("log rotation rename failed")


def _ensure_parent(path: String) raises:
    for reverse in range(path.byte_length()):
        var index = path.byte_length() - 1 - reverse
        if String(path[byte=index]) == "/":
            var parent = String("")
            for i in range(index):
                parent += String(path[byte=i])
            if parent != "":
                makedirs(parent, exist_ok=True)
            return
