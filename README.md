# Mochi

Mochi is a work in progress toward behavioral parity with the
[Maki coding agent](https://github.com/tontinton/maki). It is not yet a 1:1 port.
The parity baseline is Maki commit
`f6847451b96dc9722c9ad4ba088e6af1e27b5c6a`.

The application core is written in Mojo. The runnable binary also requires the
small C cancellation shim in `src/mochi/cancellation.c` and the libcurl-backed
`mojo-curl`/Floki transport adapter; "Mojo core" does not mean a dependency-free
or Mojo-only final binary.

## Verified subset

The current tests cover a narrow subset of Maki behavior:

- typed domain and provider contract fixtures;
- deterministic OpenAI-compatible, Anthropic, and Gemini streaming parser
  fixtures, including streamed-error classification and response-scoped
  OpenRouter reported-cost parsing;
- selected Maki v2 session codec and truncated-tail recovery behavior;
- MCP stdio/streamable-HTTP protocol and OAuth primitives;
- the basic runtime/tool loop and ACP session lifecycle;
- Mojo source-plugin compilation, bounded process RPC, cache, shadow reload,
  and synchronous bounded `SessionEnd` delivery on the currently implemented
  teardown paths; and
- selected UI reducer, command, picker, search, mouse, and emoji-sequence
  display-cell cursor behaviors.

Those claims remain deliberately narrow. Reported OpenRouter cost is not yet
persisted or displayed end to end; `SessionEnd` is not an async callback and
does not cover Maki's absent tab/job lifecycle; and cursor width does not yet
implement the non-emoji branches of `unicode-width`'s reverse string-width
automaton (including CRLF handling) or a shared PTY/IME coordinate oracle.

`tests/parity.sh` runs matching upstream and Mochi assertions independently. It
does not yet feed shared fixtures to both programs or compare their output, so a
passing run is paired-test coverage rather than proof of whole-product parity.
The explicit missing and partial behaviors are tracked in
`tests/parity_matrix.json`.

## Build and test

Requires stable Mojo 1.0 and a C compiler. `pixi.toml` pins `mojo-curl` v0.4.4
and vendors a minimal Mojo-1.0-compatible, MIT-derived Floki `Session` adapter.

```bash
pixi run build
pixi run test
MAKI_UPSTREAM=/path/to/maki pixi run parity
```

`MAKI_UPSTREAM` must be a checkout at the pinned commit above. The parity
harness prints safe clone/checkout commands when the oracle is absent or at the
wrong revision, and never modifies that checkout.

## Run

```bash
dist/mochi --provider-key "$OPENAI_API_KEY" "Explain this repository"
```

Use `dist/mochi --help` for the currently implemented providers, MCP transports,
executable extensions, permissions, and output modes. Those interfaces are not
all compatible with Maki yet; consult the parity matrix before relying on them
as replacements.

## Mojo plugins

`--plugin` accepts a prebuilt executable, a direct `.mojo` entry point, or a
directory containing `mochi-plugin.json`. Source plugins are compiled with the
Mojo compiler into a SHA-256-addressed cache keyed by the toolchain identity,
effective target/CPU/features, SDK/include inputs, manifest, flags, and plugin
sources. A build is published by atomic rename only after the compiler succeeds.
`.mojo`, `.mojoc`, and `.mojopkg` inputs below the plugin and explicit `-I`
roots are first copied into a private read-only snapshot, and the cache key is
derived from those staged bytes. Compiler flags are restricted to documented
value-only build options plus staged `-I` roots; linker paths, response files,
and other external file inputs are rejected. Compile-time reads initiated by
plugin code outside those roots are unsupported. Reload starts and validates a
shadow generation before replacing live routes, commands, and prompt hints, so
a bad build or registration leaves the last known-good process live.

The bundled plugin SDK is imported as `mochi.plugin_sdk`. Point the runtime
compiler at its package root when it is not otherwise installed:

```bash
MOCHI_PLUGIN_SDK_PATH="$PWD/src" \
  dist/mochi --plugin examples/hello_plugin.mojo
```

A directory plugin uses this manifest shape:

```json
{
  "manifest_version": 1,
  "name": "hello",
  "version": "1.0.0",
  "min_mochi_version": "0.1.0",
  "entry": "plugin.mojo",
  "sources": ["plugin.mojo", "src/helpers.mojo"],
  "include_paths": ["src"]
}
```

The manifest version floor is checked before compile or spawn, and manifest
name/version must equal the live registration. `MOCHI_MOJO_COMPILER` can select
the compiler executable; it defaults to `mojo`. The default cache identity uses
that configured compiler path plus `mojo --version`; the compiler installation
itself is trusted and is not copied into the build snapshot.

Native Mojo plugins are currently **trusted code**. A separate process enables
generation replacement and crash cleanup, but it is not a security boundary: a
plugin can call libc, signal or fork processes, read the environment, access
files, or use the network directly. Maki's Luau VM is
sandboxed, so permission/security parity remains open until Mochi adds OS-level
containment. Unchanged Luau source compatibility also remains explicitly
missing; the Mojo-first effort targets observable behavior through the SDK.
