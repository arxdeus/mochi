# Mochi

Pure Mojo port of the Maki coding agent.

## Build

```bash
pixi run build
```

Requires stable Mojo 1.0. `pixi.toml` pins `mojo-curl` v0.4.2; Mochi vendors only a minimal Mojo-1.0-compatible, MIT-derived Floki `Session` adapter because Floki v0.3.4 is beta-pinned. Provider and MCP code depend on Mochi's `HttpTransport`, not curl.

## Run

```bash
dist/mochi --provider-key "$OPENAI_API_KEY" "Explain this repository"
```

Use `dist/mochi --help` for custom providers, MCP transports, executable Mojo plugins, permissions, and output modes.

## Test

```bash
pixi run test
```
