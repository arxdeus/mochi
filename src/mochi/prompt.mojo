from std.os import getenv
from std.os.path import exists

from mochi.storage import StoragePaths


comptime SYSTEM_PROMPT = """You are Maki, an interactive coding agent. Work directly in the current project, inspect relevant code before editing, preserve existing behavior, use tools safely, and report completed work concisely."""


comptime INSTRUCTION_FILES = [
    "AGENTS.md",
    "CLAUDE.md",
    ".github/copilot-instructions.md",
    "COPILOT.md",
    ".cursorrules",
    ".windsurfrules",
    ".clinerules",
    "CONVENTIONS.md",
    "GEMINI.md",
    "CODING_AGENT.md",
]


def is_instruction_file(name: String) -> Bool:
    if name == "AGENTS.local.md":
        return True
    for path in materialize[INSTRUCTION_FILES]():
        if name == path or name == _basename(path):
            return True
    return False


def load_instruction_text(cwd: String) raises -> String:
    var paths = StoragePaths.resolve()
    return load_instruction_text_from(cwd, paths.config)


def load_instruction_text_from(cwd: String, config_dir: String) raises -> String:
    var dirs = _project_dirs(cwd)
    var output = String("")
    for reverse in range(len(dirs)):
        var dir = dirs[len(dirs) - 1 - reverse]
        for filename in materialize[INSTRUCTION_FILES]():
            var path = _join(dir, filename)
            if exists(path):
                output += "\n\nProject instructions (" + path + "):\n"
                output += open(path, "r").read()
                break
        var local = _join(dir, "AGENTS.local.md")
        if exists(local):
            output += "\n\nLocal instructions (" + local + "):\n"
            output += open(local, "r").read()
    var global_path = _join(config_dir, "AGENTS.md")
    if exists(global_path):
        output += "\n\nGlobal instructions (" + global_path + "):\n"
        output += open(global_path, "r").read()
    return output^


def build_system_prompt(
    cwd: String,
    model: String,
    platform: String,
    date: String,
    instructions: String,
) -> String:
    var result = SYSTEM_PROMPT
    result += "\n\nEnvironment:\n- Working directory: " + cwd
    result += "\n- Platform: " + platform
    result += "\n- Date: " + date
    result += "\n- Model: " + model
    result += instructions
    return result^


def _project_dirs(cwd: String) -> List[String]:
    var dirs = List[String]()
    var current = cwd
    while current != "":
        dirs.append(current)
        if exists(_join(current, ".git")):
            break
        var parent = _parent(current)
        if parent == current:
            break
        current = parent^
    return dirs^


def _parent(path: String) -> String:
    if path == "/":
        return "/"
    var end = path.byte_length()
    while end > 1 and String(path[byte=end - 1]) == "/":
        end -= 1
    for reverse in range(end):
        var index = end - 1 - reverse
        if String(path[byte=index]) == "/":
            if index == 0:
                return "/"
            return _range(path, 0, index)
    return ""


def _basename(path: String) -> String:
    for reverse in range(path.byte_length()):
        var index = path.byte_length() - 1 - reverse
        if String(path[byte=index]) == "/":
            return _range(path, index + 1, path.byte_length())
    return path


def _join(root: String, child: String) -> String:
    if root.endswith("/"):
        return root + child
    return root + "/" + child


def _range(value: String, start: Int, end: Int) -> String:
    var output = String("")
    for index in range(start, end):
        output += String(value[byte=index])
    return output^
