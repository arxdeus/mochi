"""Discovery and cached compilation for trusted native Mojo plugins.

Source plugins are compiled to standalone executables and then use the same
``mochi.plugin`` JSON-RPC transport as prebuilt plugins.  They are trusted
native code: lexical path validation and an isolated build cache prevent
accidental traversal or partial artifacts, but do not sandbox plugin behavior.
"""

from std.ffi import CStringSlice, c_int, c_long, c_pid_t, c_size_t, external_call, get_errno
from std.os import listdir, makedirs, remove
from std.os.path import exists, isdir, isfile
from std.sys._libc import exit

from mochi.json import JsonValue, parse_json
from mochi.plugin import PLUGIN_PROTOCOL_VERSION, PluginExecutable


comptime PLUGIN_MANIFEST_FILE = "mochi-plugin.json"
comptime PLUGIN_MANIFEST_VERSION = 1
comptime DEFAULT_MOCHI_VERSION = "0.1.0"
comptime PLUGIN_COMPILE_TIMEOUT_SECONDS = 120
comptime PLUGIN_IDENTITY_TIMEOUT_SECONDS = 10


struct SemanticVersion(Copyable, Movable):
    """A strict SemVer 2.0 value with unbounded numeric identifiers."""

    var major: String
    var minor: String
    var patch: String
    var prerelease: List[String]
    var build: List[String]

    def __init__(
        out self,
        var major: String,
        var minor: String,
        var patch: String,
        var prerelease: List[String],
        var build: List[String],
    ):
        self.major = major^
        self.minor = minor^
        self.patch = patch^
        self.prerelease = prerelease^
        self.build = build^


struct PluginSourceSpec(Copyable, Movable):
    """Validated source inputs, rooted at a user-selected plugin directory."""

    var root: String
    var name: String
    var version: String
    var min_mochi_version: String
    var entry: String
    var sources: List[String]
    var include_paths: List[String]
    var manifest_path: Optional[String]

    def __init__(
        out self,
        var root: String,
        var name: String,
        var version: String,
        var min_mochi_version: String,
        var entry: String,
        var sources: List[String],
        var include_paths: List[String],
        var manifest_path: Optional[String] = None,
    ):
        self.root = root^
        self.name = name^
        self.version = version^
        self.min_mochi_version = min_mochi_version^
        self.entry = entry^
        self.sources = sources^
        self.include_paths = include_paths^
        self.manifest_path = manifest_path^


struct PluginSourceMetadata(Copyable, Movable):
    """Source provenance retained alongside a prepared executable."""

    var root: String
    var name: String
    var version: String
    var min_mochi_version: String
    var entry: String
    var sources: List[String]
    var include_paths: List[String]
    var manifest_path: Optional[String]
    var build_hash: String
    var cache_hit: Bool

    def __init__(
        out self,
        spec: PluginSourceSpec,
        var build_hash: String,
        cache_hit: Bool,
    ):
        self.root = spec.root
        self.name = spec.name
        self.version = spec.version
        self.min_mochi_version = spec.min_mochi_version
        self.entry = spec.entry
        self.sources = spec.sources.copy()
        self.include_paths = spec.include_paths.copy()
        self.manifest_path = spec.manifest_path.copy()
        self.build_hash = build_hash^
        self.cache_hit = cache_hit

    def to_spec(self) -> PluginSourceSpec:
        """Reconstruct build inputs for direct-source reloads."""
        return PluginSourceSpec(
            self.root,
            self.name,
            self.version,
            self.min_mochi_version,
            self.entry,
            self.sources.copy(),
            self.include_paths.copy(),
            self.manifest_path.copy(),
        )

    def validate_registration(
        self, registered_name: String, registered_version: String
    ) raises:
        """Require manifest identity to match the plugin's live registration."""
        # A directly selected source has no declaration to compare. A manifest
        # is authoritative and prevents one cached binary impersonating another.
        if not self.manifest_path:
            return
        _ = parse_semver(registered_version)
        if registered_name != self.name:
            raise Error(
                "plugin registration name "
                + registered_name
                + " does not match manifest name "
                + self.name
            )
        if registered_version != self.version:
            raise Error(
                "plugin registration version "
                + registered_version
                + " does not match manifest version "
                + self.version
            )


struct PreparedPlugin(Copyable, Movable):
    """A launchable plugin plus source metadata when compilation was required.
    """

    var executable: PluginExecutable
    var source: Optional[PluginSourceMetadata]

    def __init__(
        out self,
        var executable: PluginExecutable,
        var source: Optional[PluginSourceMetadata] = None,
    ):
        self.executable = executable^
        self.source = source^


struct PluginBuildOptions(Copyable, Movable):
    """Compiler and cache settings included in the deterministic build key."""

    var cache_directory: String
    var compiler: String
    var mochi_version: String
    var compiler_arguments: List[String]
    var toolchain_identity: String
    var target_identity: String

    def __init__(
        out self,
        var cache_directory: String,
        var compiler: String = "mojo",
        var mochi_version: String = DEFAULT_MOCHI_VERSION,
    ):
        self.cache_directory = cache_directory^
        self.compiler = compiler^
        self.mochi_version = mochi_version^
        self.compiler_arguments = List[String]()
        self.toolchain_identity = ""
        self.target_identity = ""

    def add_compiler_argument(mut self, var argument: String):
        self.compiler_arguments.append(argument^)

    def set_toolchain_identity(mut self, var identity: String):
        """Override compiler and target discovery for hermetic builds/tests."""
        self.toolchain_identity = identity.copy()
        self.target_identity = identity^

    def set_target_identity(mut self, var identity: String):
        """Override only the effective target triple, CPU, and features."""
        self.target_identity = identity^


struct PluginBuildSnapshot(Copyable, Movable):
    """Private, read-only compiler inputs and their exact build digest."""

    var stage_root: String
    var plugin_root: String
    var compiler_arguments: List[String]
    var compiler_include_roots: List[String]
    var digest: String

    def __init__(
        out self,
        var stage_root: String,
        var plugin_root: String,
        var compiler_arguments: List[String],
        var compiler_include_roots: List[String],
        var digest: String,
    ):
        self.stage_root = stage_root^
        self.plugin_root = plugin_root^
        self.compiler_arguments = compiler_arguments^
        self.compiler_include_roots = compiler_include_roots^
        self.digest = digest^


def parse_semver(value: String) raises -> SemanticVersion:
    """Parse strict SemVer 2.0 without imposing machine-integer bounds."""
    if value == "" or String(value.strip()) != value:
        raise Error("semantic version must not be empty or padded")
    var plus = _find_byte(value, UInt8(43))
    var core_and_pre = value
    var build = List[String]()
    if plus >= 0:
        core_and_pre = _byte_prefix(value, plus)
        var build_text = _byte_suffix(value, plus + 1)
        if _find_byte(build_text, UInt8(43)) >= 0:
            raise Error("semantic version has more than one build separator")
        build = _parse_identifiers(build_text, False, "build metadata")
    var dash = _find_byte(core_and_pre, UInt8(45))
    var core = core_and_pre
    var prerelease = List[String]()
    if dash >= 0:
        core = _byte_prefix(core_and_pre, dash)
        prerelease = _parse_identifiers(
            _byte_suffix(core_and_pre, dash + 1), True, "prerelease"
        )
    var parts = core.split(".")
    if len(parts) != 3:
        raise Error("semantic version core must be major.minor.patch")
    var major = String(parts[0])
    var minor = String(parts[1])
    var patch = String(parts[2])
    _validate_core_number(major)
    _validate_core_number(minor)
    _validate_core_number(patch)
    return SemanticVersion(major^, minor^, patch^, prerelease^, build^)


def compare_semver(left: String, right: String) raises -> Int:
    """Return -1, 0, or 1 using SemVer precedence (build metadata ignored)."""
    var lhs = parse_semver(left)
    var rhs = parse_semver(right)
    var result = _compare_numeric(lhs.major, rhs.major)
    if result != 0:
        return result
    result = _compare_numeric(lhs.minor, rhs.minor)
    if result != 0:
        return result
    result = _compare_numeric(lhs.patch, rhs.patch)
    if result != 0:
        return result
    if len(lhs.prerelease) == 0 and len(rhs.prerelease) == 0:
        return 0
    if len(lhs.prerelease) == 0:
        return 1
    if len(rhs.prerelease) == 0:
        return -1
    var count = min(len(lhs.prerelease), len(rhs.prerelease))
    for index in range(count):
        var left_id = lhs.prerelease[index]
        var right_id = rhs.prerelease[index]
        var left_numeric = _all_digits(left_id)
        var right_numeric = _all_digits(right_id)
        if left_numeric and right_numeric:
            result = _compare_numeric(left_id, right_id)
        elif left_numeric:
            result = -1
        elif right_numeric:
            result = 1
        elif left_id < right_id:
            result = -1
        elif left_id > right_id:
            result = 1
        else:
            result = 0
        if result != 0:
            return result
    if len(lhs.prerelease) < len(rhs.prerelease):
        return -1
    if len(lhs.prerelease) > len(rhs.prerelease):
        return 1
    return 0


def version_satisfies_floor(current: String, required: String) raises -> Bool:
    return compare_semver(current, required) >= 0


def require_version_floor(current: String, required: String) raises:
    if not version_satisfies_floor(current, required):
        raise Error(
            "plugin requires Mochi "
            + required
            + " or newer; host is "
            + current
        )


def load_plugin_manifest(directory: String) raises -> PluginSourceSpec:
    """Load and validate ``DIRECTORY/mochi-plugin.json`` schema version 1.

    ``min_mochi_version`` is optional and defaults to ``0.0.0``. ``sources``
    defaults to the entry file, and ``include_paths`` defaults to an empty list.
    Every manifest-controlled path is a strict relative path.
    """
    var root = _normalized_root(directory)
    var path = _join(root, PLUGIN_MANIFEST_FILE)
    if not isfile(path):
        raise Error(
            "plugin directory has no " + PLUGIN_MANIFEST_FILE + ": " + root
        )
    var value = parse_json(open(path, "r").read())
    if value.kind != JsonValue.OBJECT:
        raise Error("plugin manifest must be a JSON object")
    for key in value.object_keys:
        if not _known_manifest_key(key):
            raise Error("unknown plugin manifest field: " + key)
    var manifest_version = _required_int(value, "manifest_version")
    if manifest_version != PLUGIN_MANIFEST_VERSION:
        raise Error(
            "unsupported plugin manifest version: " + String(manifest_version)
        )
    var name = _required_string(value, "name")
    _validate_plugin_name(name)
    var version = _required_string(value, "version")
    _ = parse_semver(version)
    var minimum = "0.0.0"
    if value.contains("min_mochi_version"):
        minimum = _required_string(value, "min_mochi_version")
    _ = parse_semver(minimum)
    var entry = _required_string(value, "entry")
    _validate_source_path(entry, "entry")
    var sources = List[String]()
    if value.contains("sources"):
        sources = _string_array(value, "sources")
    if len(sources) == 0:
        sources.append(entry)
    elif not _contains(sources, entry):
        sources.insert(0, entry)
    _validate_unique_paths(sources, "source", True)
    var includes = List[String]()
    if value.contains("include_paths"):
        includes = _string_array(value, "include_paths")
    _validate_unique_paths(includes, "include path", False)
    var spec = PluginSourceSpec(
        root,
        name^,
        version^,
        minimum^,
        entry^,
        sources^,
        includes^,
        Optional(path),
    )
    _validate_source_files(spec)
    return spec^


def discover_plugin_source(path: String) raises -> Optional[PluginSourceSpec]:
    """Discover a directory manifest or a directly selected ``.mojo`` file."""
    if isdir(path):
        return Optional(load_plugin_manifest(path))
    if path.endswith(".mojo"):
        if not isfile(path):
            raise Error("Mojo plugin source does not exist: " + path)
        var root = _dirname(path)
        var entry = _basename(path)
        _validate_source_path(entry, "direct source")
        var name = _source_stem(entry)
        _validate_plugin_name(name)
        var sources = List[String]()
        sources.append(entry)
        var spec = PluginSourceSpec(
            root,
            name^,
            "0.0.0",
            "0.0.0",
            entry,
            sources^,
            List[String](),
        )
        return Optional(spec^)
    return None


def plugin_build_hash(
    spec: PluginSourceSpec, options: PluginBuildOptions
) raises -> String:
    """Hash every declared source plus all compiler inputs affecting the binary.
    """
    _validate_compiler_arguments(options.compiler_arguments)
    return _plugin_build_hash_from_snapshot(
        spec,
        options,
        spec.root,
        _compiler_include_roots(options.compiler_arguments),
    )


def _plugin_build_hash_from_snapshot(
    spec: PluginSourceSpec,
    options: PluginBuildOptions,
    plugin_root: String,
    compiler_include_roots: List[String],
) raises -> String:
    """Hash staged bytes while preserving their original logical identities."""
    var material = String("")
    # Schema 3 adds the effective host target and binary package digests to the
    # immutable-input scheme introduced by schema 2.
    _hash_field(material, "cache_schema", "3")
    _hash_field(material, "protocol", String(PLUGIN_PROTOCOL_VERSION))
    _hash_field(material, "compiler", options.compiler)
    _hash_field(material, "toolchain", _compiler_identity(options))
    _hash_field(
        material,
        "effective_target",
        _effective_target_identity(spec, options, plugin_root),
    )
    _hash_field(material, "mochi_version", options.mochi_version)
    _hash_field(material, "name", spec.name)
    _hash_field(material, "version", spec.version)
    _hash_field(material, "minimum", spec.min_mochi_version)
    _hash_field(material, "entry", spec.entry)
    for argument in options.compiler_arguments:
        _hash_field(material, "compiler_argument", argument)
    for include_path in spec.include_paths:
        _hash_field(material, "include_path", include_path)
    for source in spec.sources:
        _hash_field(material, "source_path", source)
        _hash_field(
            material,
            "source_content",
            open(_join(plugin_root, source), "r").read(),
        )
    # Hash every Mojo dependency below the plugin root and every explicit
    # compiler include. This catches imported helpers and the Mochi SDK even
    # when they are not repeated in a manifest's `sources` list.
    _hash_mojo_tree(
        material, plugin_root, "", 0, options.cache_directory
    )
    for include_root in compiler_include_roots:
        _hash_mojo_tree(
            material, include_root, "", 0, options.cache_directory
        )
    return sha256_hex(material)


def compiler_command(
    spec: PluginSourceSpec, options: PluginBuildOptions, output_path: String
) raises -> PluginExecutable:
    """Construct the argv-safe Mojo compiler command used by the cache builder.
    """
    _validate_compiler_arguments(options.compiler_arguments)
    return _compiler_command_for_snapshot(
        spec,
        options,
        spec.root,
        options.compiler_arguments,
        output_path,
    )


def _compiler_command_for_snapshot(
    spec: PluginSourceSpec,
    options: PluginBuildOptions,
    plugin_root: String,
    compiler_arguments: List[String],
    output_path: String,
) raises -> PluginExecutable:
    if options.compiler == "":
        raise Error("Mojo compiler path is empty")
    var command = PluginExecutable(options.compiler)
    command.add_argument("build")
    for argument in compiler_arguments:
        command.add_argument(argument)
    command.add_argument("-I")
    command.add_argument(plugin_root)
    for include_path in spec.include_paths:
        command.add_argument("-I")
        command.add_argument(_join(plugin_root, include_path))
    command.add_argument(_join(plugin_root, spec.entry))
    command.add_argument("-o")
    command.add_argument(output_path)
    return command^


def build_source_plugin(
    spec: PluginSourceSpec, options: PluginBuildOptions
) raises -> PreparedPlugin:
    """Build on cache miss and atomically publish a complete native executable.
    """
    if options.cache_directory == "":
        raise Error("plugin build cache directory is empty")
    _validate_compiler_arguments(options.compiler_arguments)
    _ = parse_semver(options.mochi_version)
    require_version_floor(options.mochi_version, spec.min_mochi_version)
    _validate_source_files(spec)
    makedirs(options.cache_directory, exist_ok=True)
    var snapshot = _stage_build_inputs(spec, options)
    try:
        var prepared = _build_source_plugin_from_snapshot(
            spec, options, snapshot
        )
        _remove_build_stage(snapshot.stage_root)
        return prepared^
    except error:
        try:
            _remove_build_stage(snapshot.stage_root)
        except cleanup_error:
            raise Error(
                String(error)
                + "; unable to remove plugin build snapshot: "
                + String(cleanup_error)
            )
        raise error


def _build_source_plugin_from_snapshot(
    spec: PluginSourceSpec,
    options: PluginBuildOptions,
    snapshot: PluginBuildSnapshot,
) raises -> PreparedPlugin:
    var digest = snapshot.digest
    var build_directory = _join(options.cache_directory, digest)
    var output = _join(build_directory, spec.name)
    if _is_executable(output):
        var hit = PluginSourceMetadata(spec, digest^, True)
        return PreparedPlugin(PluginExecutable(output), Optional(hit^))
    makedirs(build_directory, exist_ok=True)
    var temporary = output + ".tmp." + String(external_call["getpid", c_int]())
    if exists(temporary):
        try:
            remove(temporary)
        except:
            pass
    try:
        _run_compiler(
            _compiler_command_for_snapshot(
                spec,
                options,
                snapshot.plugin_root,
                snapshot.compiler_arguments,
                temporary,
            )
        )
        if not _is_executable(temporary):
            raise Error(
                "Mojo compiler succeeded without creating an executable: "
                + temporary
            )
        var status = external_call["rename", c_int](
            temporary.as_c_string_slice().unsafe_ptr(),
            output.as_c_string_slice().unsafe_ptr(),
        )
        if status != 0:
            raise Error(
                "unable to atomically publish plugin build: "
                + String(get_errno())
            )
    except error:
        if exists(temporary):
            try:
                remove(temporary)
            except:
                pass
        raise error
    var metadata = PluginSourceMetadata(spec, digest^, False)
    return PreparedPlugin(PluginExecutable(output), Optional(metadata^))


def prepare_plugin(
    path: String, options: PluginBuildOptions
) raises -> PreparedPlugin:
    """Prepare source inputs, or preserve a prebuilt executable unchanged."""
    var source = discover_plugin_source(path)
    if not source:
        return PreparedPlugin(PluginExecutable(path))
    return build_source_plugin(source.value().copy(), options)


def rebuild_source_plugin(
    metadata: PluginSourceMetadata, options: PluginBuildOptions
) raises -> PreparedPlugin:
    """Rediscover a manifest (if present), then build or reuse its new hash."""
    if metadata.manifest_path:
        return build_source_plugin(load_plugin_manifest(metadata.root), options)
    return build_source_plugin(metadata.to_spec(), options)


def _run_compiler(executable: PluginExecutable) raises:
    var command = executable.command()
    if len(command) == 0 or command[0] == "":
        raise Error("compiler command is empty")
    var pid = external_call["fork", c_pid_t]()
    if pid < 0:
        raise Error("unable to fork Mojo compiler")
    if pid == 0:
        if external_call["setpgid", c_int](c_int(0), c_int(0)) != 0:
            exit(c_int(126))
        # Compiler diagnostics belong on the host's diagnostic stream, never on
        # the JSON-RPC/stdout channel used by a surrounding Mochi process.
        _ = external_call["dup2", c_int](c_int(2), c_int(1))
        var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
            length=len(command) + 1, fill={}
        )
        for index in range(len(command)):
            argv[index] = rebind[CStringSlice[ImmutAnyOrigin]](
                command[index].as_c_string_slice()
            )
        _ = external_call["execvp", c_int](
            command[0].as_c_string_slice(), argv.unsafe_ptr()
        )
        exit(c_int(127))
    _ = external_call["setpgid", c_int](c_int(pid), c_int(pid))
    var deadline = external_call[
        "mochi_deadline_after_millis", c_long, c_long
    ](
        c_long(PLUGIN_COMPILE_TIMEOUT_SECONDS * 1000)
    )
    if deadline < 0:
        var cleanup_status = List[c_int](length=1, fill=0)
        _ = external_call[
            "mochi_kill_process_group_and_wait",
            c_int,
            c_int,
            Pointer[mut=True, c_int, MutAnyOrigin],
        ](
            c_int(pid),
            rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
                cleanup_status.unsafe_ptr()
            ),
        )
        raise Error("unable to create Mojo compiler deadline")
    var status = List[c_int](length=1, fill=0)
    var waited = external_call[
        "mochi_wait_process_until",
        c_int,
        c_int,
        c_long,
        Pointer[mut=True, c_int, MutAnyOrigin],
    ](
        c_int(pid),
        deadline,
        rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
            status.unsafe_ptr()
        ),
    )
    if waited == 1:
        raise Error("Mojo compiler exceeded the 120 second deadline")
    if waited != 0:
        raise Error("unable to wait for Mojo compiler")
    if status[0] != 0:
        raise Error(
            "Mojo compiler failed with wait status " + String(status[0])
        )


def _compiler_identity(options: PluginBuildOptions) raises -> String:
    if options.toolchain_identity != "":
        return options.toolchain_identity
    var command = List[String]()
    command.append(options.compiler)
    command.append("--version")
    var output = _capture_command(command^)
    var identity = String(output.strip())
    if identity == "":
        raise Error("Mojo compiler returned an empty version identity")
    return identity^


def _effective_target_identity(
    spec: PluginSourceSpec,
    options: PluginBuildOptions,
    plugin_root: String,
) raises -> String:
    if options.target_identity != "":
        return options.target_identity
    var command = List[String]()
    command.append(options.compiler)
    command.append("build")
    for argument in options.compiler_arguments:
        command.append(argument)
    command.append("--print-effective-target")
    command.append(_join(plugin_root, spec.entry))
    var output = String(_capture_command(command^).strip())
    if output == "":
        raise Error("Mojo compiler returned an empty effective target")
    return output^


def _capture_command(var command: List[String]) raises -> String:
    if len(command) == 0 or command[0] == "":
        raise Error("identity command is empty")
    var output_fds = List[c_int](length=2, fill=0)
    if external_call["pipe", c_int](output_fds.unsafe_ptr()) != 0:
        raise Error("unable to create compiler identity pipe")
    var pid = external_call["fork", c_pid_t]()
    if pid < 0:
        _ = external_call["close", c_int](output_fds[0])
        _ = external_call["close", c_int](output_fds[1])
        raise Error("unable to fork compiler identity command")
    if pid == 0:
        if external_call["setpgid", c_int](c_int(0), c_int(0)) != 0:
            exit(c_int(126))
        _ = external_call["dup2", c_int](output_fds[1], c_int(1))
        _ = external_call["close", c_int](output_fds[0])
        _ = external_call["close", c_int](output_fds[1])
        var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
            length=len(command) + 1, fill={}
        )
        for index in range(len(command)):
            argv[index] = rebind[CStringSlice[ImmutAnyOrigin]](
                command[index].as_c_string_slice()
            )
        _ = external_call["execvp", c_int](
            command[0].as_c_string_slice(), argv.unsafe_ptr()
        )
        exit(c_int(127))
    _ = external_call["setpgid", c_int](c_int(pid), c_int(pid))
    _ = external_call["close", c_int](output_fds[1])
    var deadline = external_call[
        "mochi_deadline_after_millis", c_long, c_long
    ](
        c_long(PLUGIN_IDENTITY_TIMEOUT_SECONDS * 1000)
    )
    if deadline < 0:
        _ = external_call["close", c_int](output_fds[0])
        var cleanup_status = List[c_int](length=1, fill=0)
        _ = external_call[
            "mochi_kill_process_group_and_wait",
            c_int,
            c_int,
            Pointer[mut=True, c_int, MutAnyOrigin],
        ](
            c_int(pid),
            rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
                cleanup_status.unsafe_ptr()
            ),
        )
        raise Error("unable to create compiler identity deadline")
    var bytes = List[UInt8]()
    while True:
        var buffer = List[UInt8](length=4096, fill=0)
        var count = external_call[
            "mochi_fd_read_some_until",
            c_int,
            c_int,
            Pointer[mut=True, UInt8, MutAnyOrigin],
            c_size_t,
            c_long,
        ](
            output_fds[0],
            rebind[Pointer[mut=True, UInt8, MutAnyOrigin]](
                buffer.unsafe_ptr()
            ),
            c_size_t(len(buffer)),
            deadline,
        )
        if count == -2:
            _ = external_call["close", c_int](output_fds[0])
            var timeout_status = List[c_int](length=1, fill=0)
            _ = external_call[
                "mochi_kill_process_group_and_wait",
                c_int,
                c_int,
                Pointer[mut=True, c_int, MutAnyOrigin],
            ](
                c_int(pid),
                rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
                    timeout_status.unsafe_ptr()
                ),
            )
            raise Error(
                "compiler identity command exceeded the 10 second deadline"
            )
        if count < 0:
            _ = external_call["close", c_int](output_fds[0])
            var read_status = List[c_int](length=1, fill=0)
            _ = external_call[
                "mochi_kill_process_group_and_wait",
                c_int,
                c_int,
                Pointer[mut=True, c_int, MutAnyOrigin],
            ](
                c_int(pid),
                rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
                    read_status.unsafe_ptr()
                ),
            )
            raise Error("unable to read compiler identity command output")
        if count == 0:
            break
        if len(bytes) + Int(count) > 1024 * 1024:
            _ = external_call["close", c_int](output_fds[0])
            var killed_status = List[c_int](length=1, fill=0)
            _ = external_call[
                "mochi_kill_process_group_and_wait",
                c_int,
                c_int,
                Pointer[mut=True, c_int, MutAnyOrigin],
            ](
                c_int(pid),
                rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
                    killed_status.unsafe_ptr()
                ),
            )
            raise Error("compiler identity output exceeds 1 MiB")
        for index in range(Int(count)):
            bytes.append(UInt8(buffer[index]))
    _ = external_call["close", c_int](output_fds[0])
    var status = List[c_int](length=1, fill=0)
    var waited = external_call[
        "mochi_wait_process_until",
        c_int,
        c_int,
        c_long,
        Pointer[mut=True, c_int, MutAnyOrigin],
    ](
        c_int(pid),
        deadline,
        rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
            status.unsafe_ptr()
        ),
    )
    if waited == 1:
        raise Error("compiler identity command exceeded the 10 second deadline")
    if waited != 0:
        raise Error("unable to wait for compiler identity command")
    if status[0] != 0:
        raise Error(
            "compiler identity command failed with wait status "
            + String(status[0])
        )
    return String(from_utf8=Span(bytes))

def _compiler_include_roots(arguments: List[String]) raises -> List[String]:
    """Extract logical compiler include roots in argv order."""
    var roots = List[String]()
    var index = 0
    while index < len(arguments):
        var argument = arguments[index]
        if argument == "-I":
            if index + 1 >= len(arguments) or arguments[index + 1] == "":
                raise Error("compiler -I argument is missing its path")
            roots.append(arguments[index + 1])
            index += 2
            continue
        if argument.startswith("-I") and argument.byte_length() > 2:
            roots.append(_byte_suffix(argument, 2))
        index += 1
    return roots^


def _validate_compiler_arguments(arguments: List[String]) raises:
    """Allow only build flags whose inputs are values or staged include roots."""
    var index = 0
    while index < len(arguments):
        var argument = arguments[index]
        if argument == "-I":
            if index + 1 >= len(arguments) or arguments[index + 1] == "":
                raise Error("compiler -I argument is missing its path")
            index += 2
            continue
        if argument.startswith("-I") and argument.byte_length() > 2:
            index += 1
            continue
        if _safe_compiler_flag(argument) or _safe_attached_compiler_option(
            argument
        ):
            index += 1
            continue
        if _safe_compiler_value_option(argument):
            if index + 1 >= len(arguments) or arguments[index + 1] == "":
                raise Error(
                    "plugin compiler option is missing its value: "
                    + argument
                )
            index += 2
            continue
        raise Error("unsupported plugin compiler argument: " + argument)


def _safe_compiler_flag(argument: String) -> Bool:
    return (
        argument == "--no-optimization"
        or argument == "-g"
        or argument == "-g0"
        or argument == "-g1"
        or argument == "-g2"
        or argument == "--elaboration-error-include-prelude"
        or argument == "--diagnose-missing-doc-strings"
        or argument == "--disable-builtins"
        or argument == "--disable-warnings"
        or argument == "--Werror"
        or argument == "--Wno-error"
        or argument == "--warn-on-unstable-apis"
        or argument == "--ignore-incompatible-precompiled-file-errors"
        or argument == "--shared-libasan"
    )


def _safe_compiler_value_option(argument: String) -> Bool:
    return (
        argument == "--emit"
        or argument == "--optimization-level"
        or argument == "-O"
        or argument == "-D"
        or argument == "--debug-level"
        or argument == "--num-threads"
        or argument == "-j"
        or argument == "--fp-mode"
        or argument == "--target-triple"
        or argument == "--target-cpu"
        or argument == "--target-features"
        or argument == "--march"
        or argument == "--mcpu"
        or argument == "--mtune"
        or argument == "--target-accelerator"
        or argument == "--max-notes-per-diagnostic"
        or argument == "--ignore-deprecated"
        or argument == "--sanitize"
        or argument == "--debug-info-language"
        or argument == "--diagnostic-format"
    )


def _safe_attached_compiler_option(argument: String) -> Bool:
    return (
        (argument.startswith("-O") and argument.byte_length() > 2)
        or (argument.startswith("-D") and argument.byte_length() > 2)
        or (argument.startswith("-j") and argument.byte_length() > 2)
        or argument.startswith("--emit=")
        or argument.startswith("--optimization-level=")
        or argument.startswith("--debug-level=")
        or argument.startswith("--num-threads=")
        or argument.startswith("--fp-mode=")
        or argument.startswith("--target-triple=")
        or argument.startswith("--target-cpu=")
        or argument.startswith("--target-features=")
        or argument.startswith("--march=")
        or argument.startswith("--mcpu=")
        or argument.startswith("--mtune=")
        or argument.startswith("--target-accelerator=")
        or argument.startswith("--max-notes-per-diagnostic=")
        or argument.startswith("--ignore-deprecated=")
        or argument.startswith("--sanitize=")
        or argument.startswith("--debug-info-language=")
        or argument.startswith("--diagnostic-format=")
    )


def _stage_build_inputs(
    spec: PluginSourceSpec, options: PluginBuildOptions
) raises -> PluginBuildSnapshot:
    """Copy all compiler-visible Mojo sources into a private snapshot."""
    var random = List[UInt8](length=16, fill=0)
    var random_status = external_call[
        "mochi_secure_random",
        c_int,
        Pointer[mut=True, UInt8, MutAnyOrigin],
        c_size_t,
    ](
        rebind[Pointer[mut=True, UInt8, MutAnyOrigin]](random.unsafe_ptr()),
        c_size_t(len(random)),
    )
    if random_status != 0:
        raise Error("unable to create a unique plugin build snapshot")
    var stage_root = _join(
        options.cache_directory,
        ".mochi-plugin-stage-"
        + String(external_call["getpid", c_int]())
        + "-"
        + _hex_bytes(random),
    )
    makedirs(stage_root, exist_ok=False)
    try:
        var plugin_root = _join(stage_root, "plugin")
        _stage_mojo_tree(
            spec.root,
            plugin_root,
            "",
            0,
            options.cache_directory,
        )

        var rewritten = List[String]()
        var staged_includes = List[String]()
        var include_index = 0
        var index = 0
        while index < len(options.compiler_arguments):
            var argument = options.compiler_arguments[index]
            if argument == "-I":
                if (
                    index + 1 >= len(options.compiler_arguments)
                    or options.compiler_arguments[index + 1] == ""
                ):
                    raise Error("compiler -I argument is missing its path")
                var staged = _join(
                    stage_root, "compiler-include-" + String(include_index)
                )
                _stage_mojo_tree(
                    options.compiler_arguments[index + 1],
                    staged,
                    "",
                    0,
                    options.cache_directory,
                )
                rewritten.append("-I")
                rewritten.append(staged)
                staged_includes.append(staged)
                include_index += 1
                index += 2
                continue
            if argument.startswith("-I") and argument.byte_length() > 2:
                var staged = _join(
                    stage_root, "compiler-include-" + String(include_index)
                )
                _stage_mojo_tree(
                    _byte_suffix(argument, 2),
                    staged,
                    "",
                    0,
                    options.cache_directory,
                )
                rewritten.append("-I" + staged)
                staged_includes.append(staged)
                include_index += 1
            else:
                rewritten.append(argument)
            index += 1

        # Freeze before hashing, so the digest and compiler observe the same
        # bytes. The trusted compiler only needs read/execute access.
        _freeze_stage_tree(stage_root, "", 0)
        var digest = _plugin_build_hash_from_snapshot(
            spec, options, plugin_root, staged_includes
        )
        return PluginBuildSnapshot(
            stage_root^,
            plugin_root^,
            rewritten^,
            staged_includes^,
            digest^,
        )
    except error:
        try:
            _remove_build_stage(stage_root)
        except cleanup_error:
            raise Error(
                String(error)
                + "; unable to remove incomplete plugin snapshot: "
                + String(cleanup_error)
            )
        raise error


def _stage_mojo_tree(
    source_root: String,
    destination_root: String,
    relative: String,
    depth: Int,
    excluded_cache_root: String,
) raises:
    if depth > 64:
        raise Error("plugin include tree exceeds 64 directory levels")
    var source_directory = (
        source_root if relative == "" else _join(source_root, relative)
    )
    var destination_directory = (
        destination_root
        if relative == ""
        else _join(destination_root, relative)
    )
    if not isdir(source_directory):
        raise Error(
            "plugin compiler include path is not a directory: " + source_root
        )
    if _same_file(source_directory, excluded_cache_root):
        if depth == 0:
            raise Error(
                "plugin source or include root must not be the build cache"
            )
        return
    makedirs(destination_directory, exist_ok=True)
    var entries = listdir(source_directory)
    _sort_strings(entries)
    for entry in entries:
        var child_relative = (
            entry if relative == "" else relative + "/" + entry
        )
        var source = _join(source_root, child_relative)
        if isdir(source):
            _stage_mojo_tree(
                source_root,
                destination_root,
                child_relative,
                depth + 1,
                excluded_cache_root,
            )
        elif isfile(source) and _is_mojo_build_input(source):
            var destination = _join(destination_root, child_relative)
            var copy_status = external_call[
                "mochi_copy_file",
                c_int,
                CStringSlice[ImmutAnyOrigin],
                CStringSlice[ImmutAnyOrigin],
            ](
                rebind[CStringSlice[ImmutAnyOrigin]](
                    source.as_c_string_slice()
                ),
                rebind[CStringSlice[ImmutAnyOrigin]](
                    destination.as_c_string_slice()
                ),
            )
            if copy_status != 0:
                raise Error(
                    "unable to stage Mojo source "
                    + child_relative
                    + ": "
                    + String(copy_status)
                )


def _freeze_stage_tree(root: String, relative: String, depth: Int) raises:
    if depth > 66:
        raise Error("plugin build snapshot exceeds 66 directory levels")
    var directory = root if relative == "" else _join(root, relative)
    var entries = listdir(directory)
    for entry in entries:
        var child_relative = (
            entry if relative == "" else relative + "/" + entry
        )
        var child = _join(root, child_relative)
        if isdir(child):
            _freeze_stage_tree(root, child_relative, depth + 1)
        else:
            var status = external_call["chmod", c_int](
                child.as_c_string_slice(), UInt32(0o400)
            )
            if status != 0:
                raise Error("unable to freeze staged Mojo source: " + child)
    var status = external_call["chmod", c_int](
        directory.as_c_string_slice(), UInt32(0o500)
    )
    if status != 0:
        raise Error("unable to freeze plugin build snapshot: " + directory)


def _remove_build_stage(path: String) raises:
    var owned_path = path
    var status = external_call[
        "mochi_remove_plugin_stage", c_int, CStringSlice[ImmutAnyOrigin]
    ](
        rebind[CStringSlice[ImmutAnyOrigin]](owned_path.as_c_string_slice())
    )
    if status != 0:
        raise Error("snapshot cleanup failed with status " + String(status))


def _hash_mojo_tree(
    mut material: String,
    root: String,
    relative: String,
    depth: Int,
    excluded_cache_root: String,
) raises:
    if depth > 64:
        raise Error("plugin include tree exceeds 64 directory levels")
    var directory = root if relative == "" else _join(root, relative)
    if not isdir(directory):
        raise Error("plugin compiler include path is not a directory: " + root)
    if _same_file(directory, excluded_cache_root):
        if depth == 0:
            raise Error(
                "plugin source or include root must not be the build cache"
            )
        return
    var entries = listdir(directory)
    _sort_strings(entries)
    for entry in entries:
        var child_relative = (
            entry if relative == "" else relative + "/" + entry
        )
        var child = _join(root, child_relative)
        if isdir(child):
            _hash_mojo_tree(
                material,
                root,
                child_relative,
                depth + 1,
                excluded_cache_root,
            )
        elif isfile(child) and _is_mojo_build_input(child):
            _hash_field(material, "include_source_path", child_relative)
            _hash_field(
                material, "include_source_digest", _file_sha256(child)
            )


def _sort_strings(mut values: List[String]):
    for index in range(1, len(values)):
        var current = index
        while current > 0 and values[current] < values[current - 1]:
            var left = values[current - 1].copy()
            values[current - 1] = values[current]
            values[current] = left^
            current -= 1


def _validate_source_files(spec: PluginSourceSpec) raises:
    for source in spec.sources:
        var path = _join(spec.root, source)
        if not isfile(path):
            raise Error("plugin source is not a regular file: " + source)
    for include_path in spec.include_paths:
        var path = _join(spec.root, include_path)
        if not isdir(path):
            raise Error(
                "plugin include path is not a directory: " + include_path
            )


def _is_executable(path: String) -> Bool:
    if not isfile(path):
        return False
    var owned = path
    return external_call["access", c_int](
        owned.as_c_string_slice(), c_int(1)
    ) == 0


def _is_mojo_build_input(path: String) -> Bool:
    return (
        path.endswith(".mojo")
        or path.endswith(".mojoc")
        or path.endswith(".mojopkg")
    )


def _file_sha256(path: String) raises -> String:
    var owned_path = path
    var fd = external_call["mochi_open_readonly", c_int](
        owned_path.as_c_string_slice()
    )
    if fd < 0:
        raise Error("unable to open Mojo build input: " + path)
    var bytes = List[UInt8]()
    var reader = FileDescriptor(Int(fd))
    try:
        while True:
            var buffer = Array[Byte, 65536](fill=0)
            var count = reader.read_bytes(buffer)
            if count < 0:
                raise Error("unable to read Mojo build input: " + path)
            if count == 0:
                break
            for index in range(count):
                bytes.append(UInt8(buffer[index]))
    except error:
        _ = external_call["close", c_int](fd)
        raise error
    _ = external_call["close", c_int](fd)
    return _hex_bytes(_sha256_bytes(bytes^))


def _same_file(left: String, right: String) raises -> Bool:
    var owned_left = left
    var owned_right = right
    var status = external_call[
        "mochi_same_file",
        c_int,
        CStringSlice[ImmutAnyOrigin],
        CStringSlice[ImmutAnyOrigin],
    ](
        rebind[CStringSlice[ImmutAnyOrigin]](
            owned_left.as_c_string_slice()
        ),
        rebind[CStringSlice[ImmutAnyOrigin]](
            owned_right.as_c_string_slice()
        ),
    )
    if status < 0:
        raise Error(
            "unable to compare plugin build paths: " + String(-status)
        )
    return status == 1


def _validate_unique_paths(
    mut values: List[String], label: String, source: Bool
) raises:
    for index in range(len(values)):
        if source:
            _validate_source_path(values[index], label)
        else:
            _validate_relative_path(values[index], label)
        for previous in range(index):
            if values[previous] == values[index]:
                raise Error("duplicate plugin " + label + ": " + values[index])


def _validate_source_path(value: String, label: String) raises:
    _validate_relative_path(value, label)
    if not value.endswith(".mojo"):
        raise Error("plugin " + label + " must end in .mojo: " + value)


def _validate_relative_path(value: String, label: String) raises:
    if value == "" or value.startswith("/") or value.startswith("\\"):
        raise Error("plugin " + label + " must be a non-empty relative path")
    if "\\" in value or ":" in value:
        raise Error(
            "plugin " + label + " uses a forbidden path separator or drive"
        )
    var parts = value.split("/")
    for part in parts:
        var owned = String(part)
        if owned == "" or owned == "." or owned == "..":
            raise Error("plugin " + label + " contains an unsafe path segment")
        for byte in owned.as_bytes():
            if byte < 32 or byte == 127:
                raise Error("plugin " + label + " contains a control character")


def _validate_plugin_name(value: String) raises:
    if value == "" or value == "." or value == "..":
        raise Error("plugin name is empty or unsafe")
    for index in range(value.byte_length()):
        var byte = UInt8(ord(value[byte=index]))
        var valid = (
            (byte >= 48 and byte <= 57)
            or (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
            or byte == 45
            or byte == 95
        )
        if not valid:
            raise Error(
                "plugin name must use ASCII letters, digits, '-' or '_'"
            )


def _known_manifest_key(key: String) -> Bool:
    return (
        key == "manifest_version"
        or key == "name"
        or key == "version"
        or key == "min_mochi_version"
        or key == "entry"
        or key == "sources"
        or key == "include_paths"
    )


def _required_string(value: JsonValue, key: String) raises -> String:
    if not value.contains(key):
        raise Error("plugin manifest is missing field: " + key)
    var field = value.get(key)
    if field.kind != JsonValue.STRING:
        raise Error("plugin manifest field must be a string: " + key)
    return field.string_value


def _required_int(value: JsonValue, key: String) raises -> Int:
    if not value.contains(key):
        raise Error("plugin manifest is missing field: " + key)
    var field = value.get(key)
    if field.kind != JsonValue.INT:
        raise Error("plugin manifest field must be an integer: " + key)
    return field.int_value


def _string_array(value: JsonValue, key: String) raises -> List[String]:
    var field = value.get(key)
    if field.kind != JsonValue.ARRAY:
        raise Error("plugin manifest field must be an array: " + key)
    var result = List[String]()
    for item in field.array_value:
        if item.kind != JsonValue.STRING:
            raise Error("plugin manifest array must contain strings: " + key)
        result.append(item.string_value)
    return result^


def _parse_identifiers(
    text: String, forbid_leading_zero: Bool, label: String
) raises -> List[String]:
    if text == "":
        raise Error("semantic version has empty " + label)
    var result = List[String]()
    for slice in text.split("."):
        var identifier = String(slice)
        if identifier == "":
            raise Error("semantic version has empty " + label + " identifier")
        for byte in identifier.as_bytes():
            var valid = (
                (byte >= 48 and byte <= 57)
                or (byte >= 65 and byte <= 90)
                or (byte >= 97 and byte <= 122)
                or byte == 45
            )
            if not valid:
                raise Error(
                    "semantic version has invalid " + label + " identifier"
                )
        if (
            forbid_leading_zero
            and _all_digits(identifier)
            and identifier.byte_length() > 1
            and identifier[byte=0] == "0"
        ):
            raise Error("numeric prerelease identifier has a leading zero")
        result.append(identifier^)
    return result^


def _validate_core_number(value: String) raises:
    if not _all_digits(value):
        raise Error("semantic version core contains a non-numeric identifier")
    if value.byte_length() > 1 and value[byte=0] == "0":
        raise Error("semantic version core identifier has a leading zero")


def _all_digits(value: String) -> Bool:
    if value == "":
        return False
    for byte in value.as_bytes():
        if byte < 48 or byte > 57:
            return False
    return True


def _compare_numeric(left: String, right: String) -> Int:
    if left.byte_length() < right.byte_length():
        return -1
    if left.byte_length() > right.byte_length():
        return 1
    if left < right:
        return -1
    if left > right:
        return 1
    return 0


def _contains(values: List[String], expected: String) -> Bool:
    for value in values:
        if value == expected:
            return True
    return False


def _normalized_root(path: String) raises -> String:
    if path == "":
        raise Error("plugin root is empty")
    var result = path
    while result.byte_length() > 1 and result.endswith("/"):
        result = _byte_prefix(result, result.byte_length() - 1)
    return result^


def _join(root: String, relative: String) -> String:
    if root == "/":
        return root + relative
    return root + "/" + relative


def _dirname(path: String) -> String:
    var separator = -1
    for index in range(path.byte_length()):
        if path[byte=index] == "/":
            separator = index
    if separator < 0:
        return "."
    if separator == 0:
        return "/"
    return _byte_prefix(path, separator)


def _basename(path: String) -> String:
    var separator = -1
    for index in range(path.byte_length()):
        if path[byte=index] == "/":
            separator = index
    return _byte_suffix(path, separator + 1)


def _source_stem(name: String) -> String:
    return _byte_prefix(name, name.byte_length() - 5)


def _find_byte(value: String, byte: UInt8) -> Int:
    for index in range(value.byte_length()):
        if UInt8(ord(value[byte=index])) == byte:
            return index
    return -1


def _byte_prefix(value: String, count: Int) -> String:
    var result = String("")
    for index in range(count):
        result += String(value[byte=index])
    return result^


def _byte_suffix(value: String, start: Int) -> String:
    var result = String("")
    for index in range(start, value.byte_length()):
        result += String(value[byte=index])
    return result^


def _hash_field(mut material: String, label: String, value: String):
    material += (
        String(label.byte_length())
        + ":"
        + label
        + String(value.byte_length())
        + ":"
        + value
    )


def _hex_bytes(bytes: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var output = String("")
    for byte in bytes:
        output += String(digits[byte=Int(byte >> 4)])
        output += String(digits[byte=Int(byte & 15)])
    return output^


def sha256_hex(value: String) -> String:
    """Return a lowercase SHA-256 digest for cache-key verification."""
    return _hex_bytes(_sha256(value))


def _sha256(value: String) -> List[UInt8]:
    var bytes = List[UInt8]()
    for byte in value.as_bytes():
        bytes.append(byte)
    return _sha256_bytes(bytes^)


def _sha256_bytes(var bytes: List[UInt8]) -> List[UInt8]:
    var bit_length = UInt64(len(bytes)) * 8
    bytes.append(0x80)
    while len(bytes) % 64 != 56:
        bytes.append(0)
    for reverse in range(8):
        bytes.append(UInt8((bit_length >> UInt64((7 - reverse) * 8)) & 255))
    var hash: List[UInt64] = [
        0x6A09E667,
        0xBB67AE85,
        0x3C6EF372,
        0xA54FF53A,
        0x510E527F,
        0x9B05688C,
        0x1F83D9AB,
        0x5BE0CD19,
    ]
    var constants: List[UInt64] = [
        0x428A2F98,
        0x71374491,
        0xB5C0FBCF,
        0xE9B5DBA5,
        0x3956C25B,
        0x59F111F1,
        0x923F82A4,
        0xAB1C5ED5,
        0xD807AA98,
        0x12835B01,
        0x243185BE,
        0x550C7DC3,
        0x72BE5D74,
        0x80DEB1FE,
        0x9BDC06A7,
        0xC19BF174,
        0xE49B69C1,
        0xEFBE4786,
        0x0FC19DC6,
        0x240CA1CC,
        0x2DE92C6F,
        0x4A7484AA,
        0x5CB0A9DC,
        0x76F988DA,
        0x983E5152,
        0xA831C66D,
        0xB00327C8,
        0xBF597FC7,
        0xC6E00BF3,
        0xD5A79147,
        0x06CA6351,
        0x14292967,
        0x27B70A85,
        0x2E1B2138,
        0x4D2C6DFC,
        0x53380D13,
        0x650A7354,
        0x766A0ABB,
        0x81C2C92E,
        0x92722C85,
        0xA2BFE8A1,
        0xA81A664B,
        0xC24B8B70,
        0xC76C51A3,
        0xD192E819,
        0xD6990624,
        0xF40E3585,
        0x106AA070,
        0x19A4C116,
        0x1E376C08,
        0x2748774C,
        0x34B0BCB5,
        0x391C0CB3,
        0x4ED8AA4A,
        0x5B9CCA4F,
        0x682E6FF3,
        0x748F82EE,
        0x78A5636F,
        0x84C87814,
        0x8CC70208,
        0x90BEFFFA,
        0xA4506CEB,
        0xBEF9A3F7,
        0xC67178F2,
    ]
    var offset = 0
    while offset < len(bytes):
        var words = List[UInt64](length=64, fill=0)
        for index in range(16):
            var base = offset + index * 4
            words[index] = (
                (UInt64(bytes[base]) << 24)
                | (UInt64(bytes[base + 1]) << 16)
                | (UInt64(bytes[base + 2]) << 8)
                | UInt64(bytes[base + 3])
            )
        for index in range(16, 64):
            var s0 = (
                _rotr(words[index - 15], 7)
                ^ _rotr(words[index - 15], 18)
                ^ (words[index - 15] >> 3)
            )
            var s1 = (
                _rotr(words[index - 2], 17)
                ^ _rotr(words[index - 2], 19)
                ^ (words[index - 2] >> 10)
            )
            words[index] = _u32(words[index - 16] + s0 + words[index - 7] + s1)
        var a = hash[0]
        var b = hash[1]
        var c = hash[2]
        var d = hash[3]
        var e = hash[4]
        var f = hash[5]
        var g = hash[6]
        var h = hash[7]
        for index in range(64):
            var sum1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            var choice = (e & f) ^ ((_u32(~e)) & g)
            var temp1 = _u32(
                h + sum1 + choice + constants[index] + words[index]
            )
            var sum0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            var majority = (a & b) ^ (a & c) ^ (b & c)
            var temp2 = _u32(sum0 + majority)
            h = g
            g = f
            f = e
            e = _u32(d + temp1)
            d = c
            c = b
            b = a
            a = _u32(temp1 + temp2)
        hash[0] = _u32(hash[0] + a)
        hash[1] = _u32(hash[1] + b)
        hash[2] = _u32(hash[2] + c)
        hash[3] = _u32(hash[3] + d)
        hash[4] = _u32(hash[4] + e)
        hash[5] = _u32(hash[5] + f)
        hash[6] = _u32(hash[6] + g)
        hash[7] = _u32(hash[7] + h)
        offset += 64
    var result = List[UInt8]()
    for word in hash:
        result.append(UInt8((word >> 24) & 255))
        result.append(UInt8((word >> 16) & 255))
        result.append(UInt8((word >> 8) & 255))
        result.append(UInt8(word & 255))
    return result^


def _u32(value: UInt64) -> UInt64:
    return value & 0xFFFFFFFF


def _rotr(value: UInt64, count: Int) -> UInt64:
    return _u32((value >> UInt64(count)) | (value << UInt64(32 - count)))
