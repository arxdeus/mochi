"""Pure Mojo permission rules and scope matching."""


struct PermissionEffect(ImplicitlyCopyable, Equatable):
    """The result requested by a permission rule."""

    var _code: UInt8

    def __init__(out self, code: UInt8):
        self._code = code

    @staticmethod
    def allow() -> Self:
        return Self(0)

    @staticmethod
    def deny() -> Self:
        return Self(1)

    @staticmethod
    def prompt() -> Self:
        return Self(2)

    def __eq__(self, other: Self) -> Bool:
        return self._code == other._code

    def __ne__(self, other: Self) -> Bool:
        return self._code != other._code


struct PermissionAnswer(ImplicitlyCopyable, Equatable):
    comptime ALLOW_ONCE = 0
    comptime ALLOW_SESSION = 1
    comptime DENY = 2
    var code: UInt8

    def __init__(out self, code: UInt8):
        self.code = code

    @staticmethod
    def allow_once() -> Self:
        return Self(Self.ALLOW_ONCE)

    @staticmethod
    def allow_session() -> Self:
        return Self(Self.ALLOW_SESSION)

    @staticmethod
    def deny() -> Self:
        return Self(Self.DENY)

    def is_allow(self) -> Bool:
        return self.code == Self.ALLOW_ONCE or self.code == Self.ALLOW_SESSION

    def __eq__(self, other: Self) -> Bool:
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        return self.code != other.code


@fieldwise_init
struct PermissionRule(Copyable, Movable):
    """A tool glob, effect, and optional scope pattern."""

    var tool: String
    var effect: PermissionEffect
    var scope: String

    def __init__(out self, tool: String, effect: PermissionEffect):
        self.tool = tool
        self.effect = effect
        self.scope = ""


@fieldwise_init
struct PermissionDecision(Copyable, Movable):
    """A permission effect plus scopes requiring confirmation."""

    var effect: PermissionEffect
    var scopes: List[String]

    def __init__(out self, effect: PermissionEffect):
        self.effect = effect
        self.scopes = List[String]()


def _starts_with(value: String, prefix: String) -> Bool:
    if prefix.byte_length() > value.byte_length():
        return False
    for i in range(prefix.byte_length()):
        if value[byte=i] != prefix[byte=i]:
            return False
    return True


def _ends_with(value: String, suffix: String) -> Bool:
    if suffix.byte_length() > value.byte_length():
        return False
    var offset = value.byte_length() - suffix.byte_length()
    for i in range(suffix.byte_length()):
        if value[byte=offset + i] != suffix[byte=i]:
            return False
    return True


def _drop_last_bytes(value: String, count: Int) -> String:
    var result = String()
    for i in range(value.byte_length() - count):
        result += String(value[byte=i])
    return result


def glob_matches(pattern: String, value: String) -> Bool:
    """Match a tool name with `*` as a zero-or-more wildcard."""
    var pattern_index = 0
    var value_index = 0
    var star_index = -1
    var star_value_index = 0
    while value_index < value.byte_length():
        if pattern_index < pattern.byte_length() and pattern[byte=pattern_index] == value[byte=value_index]:
            pattern_index += 1
            value_index += 1
        elif pattern_index < pattern.byte_length() and pattern[byte=pattern_index] == "*":
            star_index = pattern_index
            pattern_index += 1
            star_value_index = value_index
        elif star_index >= 0:
            pattern_index = star_index + 1
            star_value_index += 1
            value_index = star_value_index
        else:
            return False
    while pattern_index < pattern.byte_length() and pattern[byte=pattern_index] == "*":
        pattern_index += 1
    return pattern_index == pattern.byte_length()


def scope_matches(pattern: String, value: String) -> Bool:
    """Match exact, prefix, command-family, and recursive path scopes."""
    if pattern == "*" or pattern == "**":
        return True
    if _ends_with(pattern, "/**"):
        var parent = _drop_last_bytes(pattern, 3)
        if value == parent:
            return True
        return _starts_with(value, parent + "/")
    if _ends_with(pattern, " *"):
        var command = _drop_last_bytes(pattern, 2)
        return value == command or _starts_with(value, command + " ")
    if _ends_with(pattern, "*"):
        return _starts_with(value, _drop_last_bytes(pattern, 1))
    return pattern == value


struct PermissionManager(Copyable, Movable):
    """Evaluates rules per scope, with deny taking precedence."""

    var rules: List[PermissionRule]
    var default_effect: PermissionEffect
    var yolo: Bool

    def __init__(out self, default_effect: PermissionEffect = PermissionEffect.prompt(), yolo: Bool = False):
        self.rules = List[PermissionRule]()
        self.default_effect = default_effect
        self.yolo = yolo

    def add_rule(mut self, var rule: PermissionRule):
        self.rules.append(rule^)

    def apply_decision(
        mut self,
        tool: String,
        scopes: List[String],
        answer: PermissionAnswer,
    ):
        if answer != PermissionAnswer.allow_session():
            return
        for scope in scopes:
            var resolved = _generalize_allow_scope(tool, scope)
            var duplicate = False
            for rule in self.rules:
                if (
                    rule.tool == tool
                    and rule.scope == resolved
                    and rule.effect == PermissionEffect.allow()
                ):
                    duplicate = True
            if not duplicate:
                self.rules.append(
                    PermissionRule(tool, PermissionEffect.allow(), resolved^)
                )

    def check(self, tool: String, scopes: List[String], force_prompt: Bool = False) -> PermissionDecision:
        var pending = List[String]()
        for scope in scopes:
            var allowed = False
            for rule in self.rules:
                if not glob_matches(rule.tool, tool):
                    continue
                if rule.scope != "" and not scope_matches(rule.scope, scope):
                    continue
                if rule.effect == PermissionEffect.deny():
                    return PermissionDecision(PermissionEffect.deny())
                if rule.effect == PermissionEffect.allow():
                    allowed = True
            if force_prompt or not allowed:
                pending.append(scope)
        if self.yolo:
            return PermissionDecision(PermissionEffect.allow())
        if len(pending) == 0:
            return PermissionDecision(PermissionEffect.allow())
        if self.default_effect == PermissionEffect.prompt():
            return PermissionDecision(PermissionEffect.prompt(), pending^)
        return PermissionDecision(self.default_effect)


def _generalize_allow_scope(tool: String, scope: String) -> String:
    if tool != "bash":
        return scope
    var parts = scope.split(" ")
    if len(parts) == 0:
        return scope
    return String(parts[0]) + " *"
