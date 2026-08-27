# Mochi

Mochi is a work in progress toward behavioral parity with the
[Maki coding agent](https://github.com/tontinton/maki). It is not yet a 1:1 port.
The parity baseline is Maki commit
`57d1f90003a6948897c6185442a136da85fe5971`.

The application core is written in Mojo. The runnable binary also requires the
small C cancellation shim in `src/mochi/cancellation.c` and the libcurl-backed
`mojo-curl`/Floki transport adapter; "Mojo core" does not mean a dependency-free
or Mojo-only final binary.

## Verified subset

The current tests cover a narrow subset of Maki behavior:

- typed domain and provider contract fixtures;
- deterministic OpenAI-compatible, Anthropic, and Gemini streaming parser fixtures;
- selected Maki v2 session codec and truncated-tail recovery behavior;
- MCP stdio/streamable-HTTP protocol and OAuth primitives;
- the basic runtime/tool loop and ACP session lifecycle; and
- selected UI reducer, command, picker, search, and mouse behaviors.

`tests/parity.sh` runs matching upstream and Mochi assertions independently. It
does not yet feed shared fixtures to both programs or compare their output, so a
passing run is paired-test coverage rather than proof of whole-product parity.
The explicit missing and partial behaviors are tracked in
`tests/parity_matrix.json`.

## Build and test

Requires stable Mojo 1.0 and a C compiler. `pixi.toml` pins `mojo-curl` v0.4.2
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
