from std.ffi import c_int, external_call
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
