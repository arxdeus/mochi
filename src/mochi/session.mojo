from std.ffi import c_int, external_call, get_errno
from std.os import listdir, makedirs, remove
from std.os.path import exists
from mochi.json import JsonValue, parse_json, serialize_json
from mochi.types import Message, ToolCall, Usage


comptime LOG_FORMAT_VERSION = 2
comptime CWD_INDEX_FILE = "cwd_latest.json"
comptime DEFAULT_TITLE = "New session"


struct SessionSummary(Copyable, Movable):
    var id: String
    var title: String
    var updated_at: Int

    def __init__(out self, var id: String, var title: String, updated_at: Int):
        self.id = id^
        self.title = title^
        self.updated_at = updated_at


struct Session(Copyable, Movable):
    var id: String
    var model: String
    var cwd: String
    var created_at: Int
    var title: String
    var token_usage: JsonValue
    var updated_at: Int
    var messages: List[JsonValue]
    var output_ids: List[String]
    var outputs: List[JsonValue]
    var subagent_ids: List[String]
    var subagent_messages: List[JsonValue]
    var subagents: JsonValue
    var usage_by_model: JsonValue
    var meta: JsonValue

    def __init__(
        out self,
        var id: String,
        var model: String,
        var cwd: String,
        created_at: Int,
    ):
        self.id = id^
        self.model = model^
        self.cwd = cwd^
        self.created_at = created_at
        self.title = DEFAULT_TITLE
        self.token_usage = JsonValue.null()
        self.updated_at = 0
        self.messages = List[JsonValue]()
        self.output_ids = List[String]()
        self.outputs = List[JsonValue]()
        self.subagent_ids = List[String]()
        self.subagent_messages = List[JsonValue]()
        self.subagents = JsonValue.array()
        self.usage_by_model = JsonValue.object()
        self.meta = JsonValue.object()

    def add_message(mut self, var message: JsonValue):
        self.messages.append(message^)

    def replace_runtime_messages(mut self, messages: List[Message]) raises:
        self.messages.clear()
        for message in messages:
            self.messages.append(message_to_json(message))

    def runtime_messages(self) raises -> List[Message]:
        var result = List[Message]()
        for message in self.messages:
            result.append(message_from_json(message))
        return result^

    def update_from_result(
        mut self,
        messages: List[Message],
        usage: Usage,
        model: String,
        updated_at: Int,
    ) raises:
        self.replace_runtime_messages(messages)
        self.model = model
        self.updated_at = updated_at
        var token_usage = JsonValue.object()
        token_usage.set("input_tokens", JsonValue.integer(usage.input_tokens))
        token_usage.set("output_tokens", JsonValue.integer(usage.output_tokens))
        self.token_usage = token_usage^
        if self.title == DEFAULT_TITLE:
            for message in messages:
                if message.role == "user" and message.content != "":
                    self.title = _title(message.content)
                    break

    def set_output(mut self, var id: String, var output: JsonValue):
        for i in range(len(self.output_ids)):
            if self.output_ids[i] == id:
                self.outputs[i] = output^
                return
        self.output_ids.append(id^)
        self.outputs.append(output^)

    def add_subagent_message(mut self, var id: String, var message: JsonValue):
        self.subagent_ids.append(id^)
        self.subagent_messages.append(message^)

    def task_names(self) -> List[String]:
        var names = List[String]()
        names.append("Main")
        if self.subagents.kind != JsonValue.ARRAY:
            return names^
        for item in self.subagents.array_value:
            var name = String("task")
            if item.kind == JsonValue.OBJECT and item.contains("name"):
                try:
                    name = item.get("name").string_value
                except:
                    pass
            names.append(name^)
        return names^

    def task_messages(self, task_index: Int) raises -> List[Message]:
        if task_index == 0:
            return self.runtime_messages()
        if self.subagents.kind != JsonValue.ARRAY or task_index > len(
            self.subagents.array_value
        ):
            raise Error("task index is out of range")
        var item = self.subagents.array_value[task_index - 1].copy()
        if item.kind != JsonValue.OBJECT:
            raise Error("task metadata is invalid")
        var id = String("")
        if item.contains("tool_use_id"):
            id = item.get("tool_use_id").string_value
        elif item.contains("id"):
            id = item.get("id").string_value
        var messages = List[Message]()
        for i in range(len(self.subagent_ids)):
            if self.subagent_ids[i] == id:
                messages.append(message_from_json(self.subagent_messages[i]))
        return messages^

    def records(self) raises -> List[JsonValue]:
        var records = List[JsonValue]()
        var header = JsonValue.object()
        header.set("t", JsonValue.string("header"))
        header.set("v", JsonValue.integer(LOG_FORMAT_VERSION))
        header.set("id", JsonValue.string(self.id))
        header.set("model", JsonValue.string(self.model))
        header.set("cwd", JsonValue.string(self.cwd))
        header.set("created_at", JsonValue.integer(self.created_at))
        records.append(header^)
        for message in self.messages:
            var record = JsonValue.object()
            record.set("t", JsonValue.string("msg"))
            record.set("d", message.copy())
            records.append(record^)
        for i in range(len(self.output_ids)):
            var record = JsonValue.object()
            record.set("t", JsonValue.string("out"))
            record.set("id", JsonValue.string(self.output_ids[i]))
            record.set("d", self.outputs[i].copy())
            records.append(record^)
        for i in range(len(self.subagent_ids)):
            var record = JsonValue.object()
            record.set("t", JsonValue.string("sub_msg"))
            record.set("sub", JsonValue.string(self.subagent_ids[i]))
            record.set("d", self.subagent_messages[i].copy())
            records.append(record^)
        var meta = self.meta.copy()
        if meta.kind != JsonValue.OBJECT:
            meta = JsonValue.object()
        meta.set("t", JsonValue.string("meta"))
        meta.set("title", JsonValue.string(self.title))
        meta.set("token_usage", self.token_usage.copy())
        meta.set("updated_at", JsonValue.integer(self.updated_at))
        meta.set("subagents", self.subagents.copy())
        meta.set("usage_by_model", self.usage_by_model.copy())
        records.append(meta^)
        return records^

    @staticmethod
    def load(path: String) raises -> Session:
        var text = open(path, "r").read()
        var got_header = False
        var result = Session("", "", "", 0)
        for line_slice in text.split("\n"):
            var line = String(line_slice)
            if not line.strip():
                continue
            var record: JsonValue
            try:
                record = parse_json(line)
            except:
                continue
            if record.kind != JsonValue.OBJECT or not record.contains("t"):
                continue
            var tag_value = record.get("t")
            if tag_value.kind != JsonValue.STRING:
                continue
            var tag = tag_value.string_value
            if tag == "header":
                var version = _required_int(record, "v")
                if version != LOG_FORMAT_VERSION:
                    raise Error(
                        "unsupported session log version: " + String(version)
                    )
                result.id = _required_string(record, "id")
                result.model = _required_string(record, "model")
                result.cwd = _required_string(record, "cwd")
                result.created_at = _required_int(record, "created_at")
                got_header = True
            elif tag == "msg" and record.contains("d"):
                result.messages.append(record.get("d"))
            elif (
                tag == "out" and record.contains("id") and record.contains("d")
            ):
                result.set_output(
                    _required_string(record, "id"), record.get("d")
                )
            elif (
                tag == "sub_msg"
                and record.contains("sub")
                and record.contains("d")
            ):
                result.add_subagent_message(
                    _required_string(record, "sub"), record.get("d")
                )
            elif tag == "meta":
                if record.contains("title"):
                    result.title = _required_string(record, "title")
                if record.contains("token_usage"):
                    result.token_usage = record.get("token_usage")
                if record.contains("updated_at"):
                    result.updated_at = _required_int(record, "updated_at")
                if record.contains("subagents"):
                    result.subagents = record.get("subagents")
                if record.contains("usage_by_model"):
                    result.usage_by_model = record.get("usage_by_model")
                result.meta = record.copy()
                _ = result.meta.remove("t")
                _ = result.meta.remove("title")
                _ = result.meta.remove("token_usage")
                _ = result.meta.remove("updated_at")
                _ = result.meta.remove("subagents")
                _ = result.meta.remove("usage_by_model")
        if not got_header:
            raise Error("session has no valid header: " + path)
        return result^


def message_to_json(message: Message) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("role", JsonValue.string(message.role))
    value.set("content", JsonValue.string(message.content))
    if message.name != "":
        value.set("name", JsonValue.string(message.name))
    if message.tool_call_id != "":
        value.set("tool_call_id", JsonValue.string(message.tool_call_id))
    if message.is_error:
        value.set("is_error", JsonValue.boolean(True))
    if not message.tool_result.is_null():
        value.set("tool_result", message.tool_result.copy())
    if len(message.tool_calls) > 0:
        var calls = JsonValue.array()
        for call in message.tool_calls:
            var item = JsonValue.object()
            item.set("id", JsonValue.string(call.id))
            item.set("name", JsonValue.string(call.name))
            item.set("arguments", JsonValue.string(call.arguments))
            calls.append(item^)
        value.set("tool_calls", calls^)
    return value^


def message_from_json(value: JsonValue) raises -> Message:
    if value.kind != JsonValue.OBJECT:
        raise Error("session message must be an object")
    var message = Message(
        _required_string(value, "role"), _required_string(value, "content")
    )
    if value.contains("name") and not value.get("name").is_null():
        message.name = _required_string(value, "name")
    if (
        value.contains("tool_call_id")
        and not value.get("tool_call_id").is_null()
    ):
        message.tool_call_id = _required_string(value, "tool_call_id")
    if value.contains("is_error"):
        if value.get("is_error").kind != JsonValue.BOOL:
            raise Error("session message is_error must be a boolean")
        message.is_error = value.get("is_error").bool_value
    if value.contains("tool_result"):
        var tool_result = value.get("tool_result")
        if tool_result.kind != JsonValue.OBJECT:
            raise Error("session message tool_result must be an object")
        message.tool_result = tool_result^
    if value.contains("tool_calls"):
        var calls = value.get("tool_calls")
        if calls.kind != JsonValue.ARRAY:
            raise Error("session tool_calls must be an array")
        for call in calls.array_value:
            message.tool_calls.append(
                ToolCall(
                    _required_string(call, "id"),
                    _required_string(call, "name"),
                    _required_string(call, "arguments"),
                )
            )
    return message^


struct SessionStore(Copyable, Movable):
    var directory: String

    def __init__(out self, var directory: String):
        self.directory = directory^

    def path(self, session_id: String) raises -> String:
        _validate_session_id(session_id)
        return self.directory + "/" + session_id + ".jsonl"

    def save(self, session: Session) raises:
        var path = self.path(session.id)
        makedirs(self.directory, exist_ok=True)
        var body = String("")
        var records = session.records()
        for record in records:
            body += serialize_json(record) + "\n"
        _atomic_write(path, body)
        var index = self._load_index()
        index.set(session.cwd, JsonValue.string(session.id))
        self._save_index(index)

    def load(self, session_id: String) raises -> Session:
        var session = Session.load(self.path(session_id))
        _validate_session_id(session.id)
        if session.id != session_id:
            raise Error("session id does not match its filename")
        return session^

    def list(self, cwd: Optional[String] = None) raises -> List[SessionSummary]:
        var summaries = List[SessionSummary]()
        if not exists(self.directory):
            return summaries^
        for name in listdir(self.directory):
            if not name.endswith(".jsonl"):
                continue
            try:
                var session = Session.load(self.directory + "/" + name)
                _validate_session_id(session.id)
                var file_id = String(name.removesuffix(".jsonl"))
                _validate_session_id(file_id)
                if session.id != file_id:
                    continue
                if cwd and session.cwd != cwd.value():
                    continue
                summaries.append(
                    SessionSummary(
                        session.id, session.title, session.updated_at
                    )
                )
            except:
                continue
        for i in range(len(summaries)):
            for j in range(i + 1, len(summaries)):
                if summaries[j].updated_at > summaries[i].updated_at:
                    var swap = summaries[i].copy()
                    summaries[i] = summaries[j].copy()
                    summaries[j] = swap^
        return summaries^

    def latest(self, cwd: String) raises -> Optional[Session]:
        var index = self._load_index()
        if index.contains(cwd):
            var indexed = index.get(cwd)
            if indexed.kind == JsonValue.STRING:
                try:
                    var indexed_path = self.path(indexed.string_value)
                    if exists(indexed_path):
                        var loaded = self.load(indexed.string_value)
                        if loaded.cwd == cwd:
                            return loaded^
                except:
                    pass
        var summaries = self.list(cwd)
        if len(summaries) == 0:
            return None
        var latest = self.load(summaries[0].id)
        index.set(cwd, JsonValue.string(latest.id))
        self._save_index(index)
        return latest^

    def _load_index(self) -> JsonValue:
        var path = self.directory + "/" + CWD_INDEX_FILE
        if not exists(path):
            return JsonValue.object()
        try:
            var value = parse_json(open(path, "r").read())
            if value.kind == JsonValue.OBJECT:
                return value^
        except:
            pass
        return JsonValue.object()

    def _save_index(self, index: JsonValue) raises:
        makedirs(self.directory, exist_ok=True)
        _atomic_write(
            self.directory + "/" + CWD_INDEX_FILE, serialize_json(index)
        )


def _validate_session_id(session_id: String) raises:
    if session_id == "" or session_id == "." or session_id == "..":
        raise Error("invalid session id")
    for byte in session_id.as_bytes():
        var code = Int(byte)
        var allowed = (
            (code >= 48 and code <= 57)
            or (code >= 65 and code <= 90)
            or (code >= 97 and code <= 122)
            or code == 45
            or code == 95
        )
        if not allowed:
            raise Error("invalid session id")


def _title(text: String) -> String:
    var result = String("")
    for cp in text.codepoint_slices():
        if result.count_codepoints() >= 80:
            break
        if String(cp) == "\n" or String(cp) == "\r":
            break
        result += String(cp)
    return String(result.strip())


def _required_string(value: JsonValue, key: String) raises -> String:
    var field = value.get(key)
    if field.kind != JsonValue.STRING:
        raise Error("session field is not a string: " + key)
    return field.string_value


def _required_int(value: JsonValue, key: String) raises -> Int:
    var field = value.get(key)
    if field.kind != JsonValue.INT:
        raise Error("session field is not an integer: " + key)
    return field.int_value


def _atomic_write(path: String, content: String) raises:
    var temporary = path + ".tmp"
    try:
        with open(temporary, "w") as file:
            file.write(content)
        var destination = String(path)
        var temporary_c = temporary.as_c_string_slice()
        var path_c = destination.as_c_string_slice()
        var status = external_call["rename", c_int](
            temporary_c.unsafe_ptr(), path_c.unsafe_ptr()
        )
        if status != 0:
            raise Error("atomic rename failed: " + String(get_errno()))
    except error:
        try:
            remove(temporary)
        except:
            pass
        raise error
