from std.os.path import exists

from mochi.json import JsonValue, parse_json


struct AppConfig(Copyable, Movable):
    var model: Optional[String]
    var provider: Optional[String]
    var provider_url: Optional[String]
    var output_format: Optional[String]
    var yolo: Optional[Bool]
    var max_turns: Optional[Int]
    var raw: JsonValue

    def __init__(out self):
        self.model = None
        self.provider = None
        self.provider_url = None
        self.output_format = None
        self.yolo = None
        self.max_turns = None
        self.raw = JsonValue.object()

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        if value.kind != JsonValue.OBJECT:
            raise Error("configuration must be an object")
        var result = Self()
        result.raw = value.copy()
        result.model = _optional_string(value, "model")
        if value.contains("provider") and value.get("provider").kind == JsonValue.STRING:
            result.provider = _optional_string(value, "provider")
        result.provider_url = _optional_string(value, "provider_url")
        result.output_format = _optional_string(value, "output_format")
        result.yolo = _optional_bool(value, "yolo")
        result.max_turns = _optional_int(value, "max_turns")
        if result.provider and result.provider.value() != "openai" and result.provider.value() != "anthropic" and result.provider.value() != "gemini":
            raise Error("invalid configured provider")
        if result.output_format and (
            result.output_format.value() != "text"
            and result.output_format.value() != "json"
            and result.output_format.value() != "stream-json"
        ):
            raise Error("invalid configured output_format")
        if result.max_turns and result.max_turns.value() < 1:
            raise Error("configured max_turns must be positive")
        return result^

    def merged(self, project: Self) raises -> Self:
        var value = _merge_objects(self.raw, project.raw)
        return Self.from_json(value^)


def load_layered_config(global_path: String, project_path: String) raises -> AppConfig:
    var base = AppConfig()
    if exists(global_path):
        base = AppConfig.from_json(parse_json(open(global_path, "r").read()))
    var project = AppConfig()
    if exists(project_path):
        project = AppConfig.from_json(parse_json(open(project_path, "r").read()))
    return base.merged(project)


def _merge_objects(base: JsonValue, overlay: JsonValue) raises -> JsonValue:
    var result = base.copy()
    if result.kind != JsonValue.OBJECT:
        result = JsonValue.object()
    if overlay.kind != JsonValue.OBJECT:
        return result^
    for index in range(len(overlay.object_keys)):
        var key = overlay.object_keys[index]
        var value = overlay.object_values[index].copy()
        if value.kind == JsonValue.OBJECT and result.contains(key):
            var current = result.get(key)
            if current.kind == JsonValue.OBJECT:
                value = _merge_objects(current, value^)
        result.set(key, value^)
    return result^


def _optional_string(value: JsonValue, key: String) raises -> Optional[String]:
    if not value.contains(key) or value.get(key).is_null():
        return None
    if value.get(key).kind != JsonValue.STRING:
        raise Error("configuration field must be a string: " + key)
    return Optional(value.get(key).string_value)


def _optional_bool(value: JsonValue, key: String) raises -> Optional[Bool]:
    if not value.contains(key) or value.get(key).is_null():
        return None
    if value.get(key).kind != JsonValue.BOOL:
        raise Error("configuration field must be a boolean: " + key)
    return Optional(value.get(key).bool_value)


def _optional_int(value: JsonValue, key: String) raises -> Optional[Int]:
    if not value.contains(key) or value.get(key).is_null():
        return None
    if value.get(key).kind != JsonValue.INT:
        raise Error("configuration field must be an integer: " + key)
    return Optional(value.get(key).int_value)
