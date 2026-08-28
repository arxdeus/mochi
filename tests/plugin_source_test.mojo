from std.ffi import c_int, external_call
from std.os import listdir, makedirs, remove
from std.os.path import exists, isfile
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mochi.plugin_source import (
    PLUGIN_MANIFEST_FILE,
    PluginBuildOptions,
    compare_semver,
    compiler_command,
    discover_plugin_source,
    load_plugin_manifest,
    plugin_build_hash,
    prepare_plugin,
    rebuild_source_plugin,
    require_version_floor,
    sha256_hex,
    version_satisfies_floor,
)


def _root() -> String:
    # A fresh process gets a fresh cache, so the suite is repeatable without
    # deleting another run's files or relying on test discovery order.
    return (
        "/tmp/mochi-plugin-source-test-"
        + String(external_call["getpid", c_int]())
    )


def _write(path: String, content: String) raises:
    with open(path, "w") as file:
        file.write(content)


def _remove(path: String):
    try:
        remove(path)
    except:
        pass


def _assert_no_build_stages(cache: String) raises:
    for name in listdir(cache):
        assert_false(String(name).startswith(".mochi-plugin-stage-"))


def _fixture(directory: String) raises:
    makedirs(directory + "/src", exist_ok=True)
    _write(directory + "/plugin.mojo", "def main():\n    pass\n")
    _write(
        directory + "/src/helper.mojo", "def answer() -> Int:\n    return 42\n"
    )
    _write(
        directory + "/" + PLUGIN_MANIFEST_FILE,
        '{"manifest_version":1,"name":"fixture","version":"1.2.3","min_mochi_version":"0.1.0","entry":"plugin.mojo","sources":["plugin.mojo","src/helper.mojo"],"include_paths":["src"]}',
    )


def test_strict_semver_and_floor() raises:
    assert_equal(
        sha256_hex("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )
    assert_equal(compare_semver("1.2.3", "1.2.3+build.9"), 0)
    assert_true(compare_semver("1.2.3", "1.2.3-rc.1") > 0)
    assert_true(compare_semver("1.2.3-rc.2", "1.2.3-rc.10") < 0)
    assert_true(compare_semver("100000000000000000000.0.0", "9.0.0") > 0)
    assert_true(version_satisfies_floor("0.2.0", "0.1.9"))
    require_version_floor("1.0.0", "1.0.0")
    with assert_raises():
        require_version_floor("0.9.9", "1.0.0")
    with assert_raises():
        _ = compare_semver("v1.2.3", "1.2.3")
    with assert_raises():
        _ = compare_semver("1.02.3", "1.2.3")
    with assert_raises():
        _ = compare_semver("1.2.3-01", "1.2.3-1")


def test_manifest_discovery_and_compiler_command() raises:
    var directory = _root() + "/manifest"
    _fixture(directory)
    var spec = load_plugin_manifest(directory + "/")
    assert_equal(spec.root, directory)
    assert_equal(spec.name, "fixture")
    assert_equal(spec.version, "1.2.3")
    assert_equal(spec.min_mochi_version, "0.1.0")
    assert_equal(spec.entry, "plugin.mojo")
    assert_equal(len(spec.sources), 2)
    assert_equal(spec.include_paths[0], "src")
    assert_true(spec.manifest_path)
    var discovered = discover_plugin_source(directory)
    assert_true(discovered)
    var options = PluginBuildOptions(_root() + "/cache", "/opt/mojo")
    options.add_compiler_argument("--target-cpu=generic")
    var command = compiler_command(spec, options, "/tmp/output").command()
    assert_equal(command[0], "/opt/mojo")
    assert_equal(command[1], "build")
    assert_equal(command[2], "--target-cpu=generic")
    assert_equal(command[3], "-I")
    assert_equal(command[4], directory)
    assert_equal(command[len(command) - 2], "-o")
    assert_equal(command[len(command) - 1], "/tmp/output")


def test_manifest_rejects_traversal_duplicates_and_version_typos() raises:
    var directory = _root() + "/unsafe"
    makedirs(directory, exist_ok=True)
    _write(directory + "/plugin.mojo", "def main():\n    pass\n")
    _write(
        directory + "/" + PLUGIN_MANIFEST_FILE,
        '{"manifest_version":1,"name":"bad","version":"1.0.0","entry":"../plugin.mojo"}',
    )
    with assert_raises():
        _ = load_plugin_manifest(directory)
    _write(
        directory + "/" + PLUGIN_MANIFEST_FILE,
        '{"manifest_version":1,"name":"bad","version":"1.0.0","entry":"plugin.mojo","sources":["plugin.mojo","plugin.mojo"]}',
    )
    with assert_raises():
        _ = load_plugin_manifest(directory)
    _write(
        directory + "/" + PLUGIN_MANIFEST_FILE,
        '{"manifest_version":1,"name":"bad","version":"1.0","entry":"plugin.mojo"}',
    )
    with assert_raises():
        _ = load_plugin_manifest(directory)
    _write(
        directory + "/" + PLUGIN_MANIFEST_FILE,
        '{"manifest_version":1,"name":"bad","version":"1.0.0","entry":"plugin.mojo","typo":true}',
    )
    with assert_raises():
        _ = load_plugin_manifest(directory)


def test_content_and_build_spec_hash_are_deterministic() raises:
    var directory = _root() + "/hash"
    _fixture(directory)
    var spec = load_plugin_manifest(directory)
    var options = PluginBuildOptions(_root() + "/cache-hash", "/opt/mojo")
    options.set_toolchain_identity("mojo-test-1")
    var first = plugin_build_hash(spec, options)
    assert_equal(first, plugin_build_hash(spec, options))
    assert_equal(first.byte_length(), 64)
    var newer_toolchain = PluginBuildOptions(
        _root() + "/cache-hash", "/opt/mojo"
    )
    newer_toolchain.set_toolchain_identity("mojo-test-2")
    assert_true(first != plugin_build_hash(spec, newer_toolchain))
    var newer_target = PluginBuildOptions(
        _root() + "/cache-hash", "/opt/mojo"
    )
    newer_target.set_toolchain_identity("mojo-test-1")
    newer_target.set_target_identity("different-target")
    assert_true(first != plugin_build_hash(spec, newer_target))
    options.add_compiler_argument("-O2")
    assert_true(first != plugin_build_hash(spec, options))
    var newer_host = PluginBuildOptions(
        _root() + "/cache-hash", "/opt/mojo", "0.2.0"
    )
    newer_host.set_toolchain_identity("mojo-test-1")
    assert_true(first != plugin_build_hash(spec, newer_host))
    var original = open(directory + "/src/helper.mojo", "r").read()
    _write(directory + "/src/helper.mojo", original + "\n")
    var changed_options = PluginBuildOptions(
        _root() + "/cache-hash", "/opt/mojo"
    )
    changed_options.set_toolchain_identity("mojo-test-1")
    assert_true(first != plugin_build_hash(spec, changed_options))
    var sdk = _root() + "/sdk"
    makedirs(sdk, exist_ok=True)
    _write(sdk + "/plugin_sdk.mojo", "def sdk() -> Int:\n    return 1\n")
    var sdk_options = PluginBuildOptions(
        _root() + "/cache-hash", "/opt/mojo"
    )
    sdk_options.set_toolchain_identity("mojo-test-1")
    sdk_options.add_compiler_argument("-I")
    sdk_options.add_compiler_argument(sdk)
    var sdk_hash = plugin_build_hash(spec, sdk_options)
    _write(sdk + "/plugin_sdk.mojo", "def sdk() -> Int:\n    return 2\n")
    assert_true(sdk_hash != plugin_build_hash(spec, sdk_options))
    _write(sdk + "/compiled.mojopkg", "package-one")
    var package_hash = plugin_build_hash(spec, sdk_options)
    _write(sdk + "/compiled.mojopkg", "package-two")
    assert_true(package_hash != plugin_build_hash(spec, sdk_options))
    var unsupported = PluginBuildOptions(
        _root() + "/cache-hash", "/opt/mojo"
    )
    unsupported.set_toolchain_identity("mojo-test-1")
    unsupported.add_compiler_argument("-Xlinker")
    unsupported.add_compiler_argument("/tmp/native.o")
    with assert_raises():
        _ = plugin_build_hash(spec, unsupported)


def test_build_cache_hit_and_atomic_output() raises:
    var directory = _root() + "/build"
    var cache = _root() + "/build-cache"
    var compiler = _root() + "/fake-mojo.sh"
    var log = _root() + "/compiler.log"
    var observed = _root() + "/compiler-source.mojo"
    var paths_log = _root() + "/compiler-paths.log"
    var live_entry = directory + "/plugin.mojo"
    var original = "def main():\n    pass\n"
    var changed = "def main():\n    print(\"changed live tree\")\n"
    makedirs(_root(), exist_ok=True)
    _fixture(directory)
    _remove(log)
    _remove(observed)
    _remove(paths_log)
    _write(
        compiler,
        "#!/bin/sh\nprintf 'run\\n' >> "
        + log
        + "\nprintf 'def main():\\n    print(\"changed live tree\")\\n' > "
        + live_entry
        + "\nout=''\nplugin_root=''\nentry=''\nwhile [ \"$#\" -gt 0 ]; do\n"
        + "  if [ \"$1\" = '-I' ]; then\n    shift\n    [ -n \"$plugin_root\" ] || plugin_root=$1\n"
        + "  elif [ \"$1\" = '-o' ]; then\n    shift\n    out=$1\n"
        + "  elif [ \"${1%.mojo}\" != \"$1\" ]; then\n    entry=$1\n  fi\n  shift\ndone\n"
        + "printf '%s\\n%s\\n' \"$plugin_root\" \"$entry\" > "
        + paths_log
        + "\ncat \"$entry\" > "
        + observed
        + "\n[ -n \"$out\" ] || exit"
        ' 2\nprintf \'#!/bin/sh\\nexit 0\\n\' > "$out"\nchmod 755 "$out"\n',
    )
    var chmod_status = external_call["chmod", c_int](
        compiler.as_c_string_slice(), UInt32(0o755)
    )
    assert_equal(Int(chmod_status), 0)
    var options = PluginBuildOptions(cache, compiler)
    options.set_toolchain_identity("fake-mojo-1")
    var expected_digest = plugin_build_hash(
        load_plugin_manifest(directory), options
    )
    var first = prepare_plugin(directory, options)
    assert_true(first.source)
    assert_false(first.source.value().cache_hit)
    assert_equal(first.source.value().build_hash, expected_digest)
    assert_true(isfile(first.executable.path))
    assert_equal(first.source.value().build_hash.byte_length(), 64)
    assert_equal(open(observed, "r").read(), original)
    assert_equal(open(live_entry, "r").read(), changed)
    var paths = open(paths_log, "r").read().split("\n")
    assert_equal(len(paths), 3)
    var staged_plugin_root = String(paths[0])
    var staged_entry = String(paths[1])
    assert_true(
        staged_plugin_root.startswith(cache + "/.mochi-plugin-stage-")
    )
    assert_true(staged_plugin_root.endswith("/plugin"))
    assert_equal(staged_entry, staged_plugin_root + "/plugin.mojo")
    assert_true(staged_entry != live_entry)
    assert_false(exists(staged_plugin_root))
    _assert_no_build_stages(cache)
    _write(live_entry, original)
    var second = prepare_plugin(directory, options)
    assert_true(second.source.value().cache_hit)
    assert_equal(second.source.value().build_hash, expected_digest)
    assert_equal(second.executable.path, first.executable.path)
    var lines = open(log, "r").read().split("\n")
    assert_equal(len(lines), 2)
    assert_equal(String(lines[0]), "run")
    _assert_no_build_stages(cache)
    assert_false(exists(first.executable.path + ".tmp"))
    first.source.value().validate_registration("fixture", "1.2.3")
    with assert_raises():
        first.source.value().validate_registration("impostor", "1.2.3")
    var rebuilt = rebuild_source_plugin(first.source.value().copy(), options)
    assert_true(rebuilt.source.value().cache_hit)
    _assert_no_build_stages(cache)


def test_failed_compiler_leaves_no_executable_or_temporary_artifact() raises:
    var directory = _root() + "/failed-build"
    var cache = _root() + "/failed-cache"
    var compiler = _root() + "/failed-mojo.sh"
    var paths_log = _root() + "/failed-paths.log"
    _fixture(directory)
    _write(
        compiler,
        "#!/bin/sh\nout=''\nplugin_root=''\nwhile [ \"$#\" -gt 0 ]; do\n"
        + "  if [ \"$1\" = '-I' ]; then\n    shift\n    [ -n \"$plugin_root\" ] || plugin_root=$1\n"
        + "  elif [ \"$1\" = '-o' ]; then\n    shift\n    out=$1\n  fi\n  shift\ndone\n"
        + "printf '%s\\n' \"$plugin_root\" > "
        + paths_log
        + "\nprintf '#!/bin/sh\\nexit 0\\n' > \"$out\"\nchmod 755 \"$out\"\nexit 7\n",
    )
    assert_equal(
        Int(
            external_call["chmod", c_int](
                compiler.as_c_string_slice(), UInt32(0o755)
            )
        ),
        0,
    )
    var spec = load_plugin_manifest(directory)
    var options = PluginBuildOptions(cache, compiler)
    options.set_toolchain_identity("false-1")
    var digest = plugin_build_hash(spec, options)
    var output = cache + "/" + digest + "/fixture"
    _remove(output)
    with assert_raises():
        _ = prepare_plugin(directory, options)
    assert_false(exists(output))
    var temporary = output + ".tmp." + String(external_call["getpid", c_int]())
    assert_false(exists(temporary))
    var failed_paths = open(paths_log, "r").read().split("\n")
    var staged_plugin_root = String(failed_paths[0])
    assert_true(
        staged_plugin_root.startswith(cache + "/.mochi-plugin-stage-")
    )
    assert_true(staged_plugin_root.endswith("/plugin"))
    assert_false(exists(staged_plugin_root))
    _assert_no_build_stages(cache)


def test_cache_nested_under_source_is_excluded_from_snapshot() raises:
    var directory = _root() + "/nested-cache"
    var cache = directory + "/.cache"
    var compiler = _root() + "/nested-cache-mojo.sh"
    _fixture(directory)
    _write(
        compiler,
        "#!/bin/sh\nout=''\nwhile [ \"$#\" -gt 0 ]; do\n"
        + "  if [ \"$1\" = '-o' ]; then\n    shift\n    out=$1\n  fi\n  shift\ndone\n"
        + "[ -n \"$out\" ] || exit 2\nprintf '#!/bin/sh\\nexit 0\\n' > \"$out\"\nchmod 755 \"$out\"\n",
    )
    assert_equal(
        Int(
            external_call["chmod", c_int](
                compiler.as_c_string_slice(), UInt32(0o755)
            )
        ),
        0,
    )
    var options = PluginBuildOptions(cache, compiler)
    options.set_toolchain_identity("nested-cache-test")
    var first = prepare_plugin(directory, options)
    assert_false(first.source.value().cache_hit)
    assert_equal(
        first.source.value().build_hash,
        plugin_build_hash(load_plugin_manifest(directory), options),
    )
    _assert_no_build_stages(cache)
    var second = prepare_plugin(directory, options)
    assert_true(second.source.value().cache_hit)
    assert_equal(first.executable.path, second.executable.path)
    _assert_no_build_stages(cache)


def test_direct_source_and_prebuilt_passthrough() raises:
    var directory = _root() + "/direct"
    var source = directory + "/hello.mojo"
    makedirs(directory, exist_ok=True)
    _write(source, "def main():\n    pass\n")
    var discovered = discover_plugin_source(source)
    assert_true(discovered)
    assert_equal(discovered.value().root, directory)
    assert_equal(discovered.value().entry, "hello.mojo")
    assert_equal(discovered.value().name, "hello")
    assert_false(discovered.value().manifest_path)
    var passthrough = prepare_plugin(
        "/usr/local/bin/native-plugin",
        PluginBuildOptions(_root() + "/unused"),
    )
    assert_equal(passthrough.executable.path, "/usr/local/bin/native-plugin")
    assert_false(passthrough.source)


def test_version_floor_fails_before_compiler_runs() raises:
    var directory = _root() + "/floor"
    var compiler = _root() + "/floor-compiler.sh"
    var marker = _root() + "/floor-compiler-ran"
    makedirs(_root(), exist_ok=True)
    _fixture(directory)
    _write(
        directory + "/" + PLUGIN_MANIFEST_FILE,
        '{"manifest_version":1,"name":"fixture","version":"1.2.3","min_mochi_version":"9.0.0","entry":"plugin.mojo"}',
    )
    _remove(marker)
    _write(
        compiler,
        "#!/bin/sh\nprintf ran > " + marker + "\nexit 1\n",
    )
    assert_equal(
        Int(
            external_call["chmod", c_int](
                compiler.as_c_string_slice(), UInt32(0o755)
            )
        ),
        0,
    )
    var options = PluginBuildOptions(_root() + "/floor-cache", compiler)
    options.set_toolchain_identity("floor-test")
    with assert_raises():
        _ = prepare_plugin(directory, options)
    assert_false(exists(marker))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
