from std.ffi import c_int, external_call, get_errno
from std.os import listdir, makedirs, remove
from std.os.path import exists

from mochi.json import JsonValue, parse_json


comptime HISTORY_FILE = "input_history.json"
comptime MAX_ENTRIES = 100


struct InputHistory(Copyable, Movable):
    var path: String
    var entries: List[String]
    var max_entries: Int

    def __init__(out self, directory: String, max_entries: Int = MAX_ENTRIES):
        self.path = directory + "/" + HISTORY_FILE
        self.entries = List[String]()
        self.max_entries = max_entries if max_entries > 0 else 0

    def load(mut self):
        self.entries.clear()
        if not exists(self.path):
            return
        try:
            var value = parse_json(open(self.path, "r").read())
            if value.kind != JsonValue.ARRAY:
                return
            for entry in value.array_value:
                if entry.kind != JsonValue.STRING:
                    self.entries.clear()
                    return
            for entry in value.array_value:
                _ = self._push_inner(entry.string_value)
        except:
            self.entries.clear()

    def push(mut self, value: String):
        _ = self._push(value)

    def add(mut self, value: String) raises:
        if self._push(value):
            self.save()

    def save(self) raises:
        _ensure_parent(self.path)
        var value = JsonValue.array()
        for entry in self.entries:
            value.append(JsonValue.string(entry))
        _atomic_write(self.path, value.serialize())

    def _push(mut self, value: String) -> Bool:
        var trimmed = String(value.strip())
        if trimmed == "":
            return False
        return self._push_inner(trimmed)

    def _push_inner(mut self, value: String) -> Bool:
        if len(self.entries) > 0 and self.entries[len(self.entries) - 1] == value:
            return False
        self.entries.append(value)
        self._trim()
        return True

    def _trim(mut self):
        while len(self.entries) > self.max_entries:
            _ = self.entries.pop(0)


struct NoteStore(Copyable, Movable):
    var directory: String

    def __init__(out self, directory: String):
        self.directory = directory

    def write(mut self, name: String, content: String) raises:
        var safe = _safe_name(name)
        makedirs(self.directory, exist_ok=True)
        with open(self.directory + "/" + safe + ".md", "w") as file:
            file.write(content)

    def read(self, name: String) raises -> String:
        return open(self.directory + "/" + _safe_name(name) + ".md", "r").read()

    def delete(mut self, name: String) raises:
        remove(self.directory + "/" + _safe_name(name) + ".md")

    def list(self) raises -> List[String]:
        var result = List[String]()
        if not exists(self.directory):
            return result^
        for name in listdir(self.directory):
            if name.endswith(".md"):
                result.append(_strip_md(name))
        _sort(result)
        return result^


struct PreferenceStore(Copyable, Movable):
    var path: String
    var values: JsonValue

    def __init__(out self, path: String):
        self.path = path
        self.values = JsonValue.object()

    def load(mut self) raises:
        if not exists(self.path):
            return
        var value = parse_json(open(self.path, "r").read())
        if value.kind != JsonValue.OBJECT:
            raise Error("preferences must be an object")
        self.values = value^

    def set(mut self, key: String, var value: JsonValue) raises:
        self.values.set(key, value^)
        _ensure_parent(self.path)
        with open(self.path, "w") as file:
            file.write(self.values.serialize())

    def get(self, key: String) raises -> Optional[JsonValue]:
        if not self.values.contains(key):
            return None
        return Optional(self.values.get(key))


def project_id(cwd: String) -> String:
    var hash: UInt64 = 1469598103934665603
    for index in range(cwd.byte_length()):
        hash ^= UInt64(UInt8(ord(cwd[byte=index])))
        hash *= 1099511628211
    return _hex(hash)


def _safe_name(name: String) raises -> String:
    if name == "" or name == "." or name == ".." or "/" in name or "\\" in name:
        raise Error("invalid note name")
    return name


def _strip_md(name: String) -> String:
    var result = String("")
    for index in range(name.byte_length() - 3):
        result += String(name[byte=index])
    return result^


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


def _atomic_write(path: String, content: String) raises:
    var temporary = path + ".tmp"
    try:
        with open(temporary, "w") as file:
            file.write(content)
        var destination = String(path)
        var temporary_c = temporary.as_c_string_slice()
        var destination_c = destination.as_c_string_slice()
        var status = external_call["rename", c_int](
            temporary_c.unsafe_ptr(), destination_c.unsafe_ptr()
        )
        if status != 0:
            raise Error("atomic rename failed: " + String(get_errno()))
    except error:
        try:
            remove(temporary)
        except:
            pass
        raise error


def _sort(mut values: List[String]):
    for i in range(len(values)):
        for j in range(i + 1, len(values)):
            if values[j] < values[i]:
                var swap = values[i]
                values[i] = values[j]
                values[j] = swap


def _hex(value: UInt64) -> String:
    comptime digits = "0123456789abcdef"
    var output = String("")
    for reverse in range(16):
        var shift = (15 - reverse) * 4
        output += String(digits[byte=Int((value >> UInt64(shift)) & 15)])
    return output^
