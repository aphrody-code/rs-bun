# rs-bun

Everything to connect **Rust** and **Bun**, packaged as one Claude Code plugin:
four skills + a specialist sub-agent.

## What's inside

### Skills

| Skill | What it does |
| --- | --- |
| **bun-ffi** | The FFI *mechanics* — build a complete, correct Rust↔Bun bridge via `bun:ffi` (`dlopen`/`cc`/`JSCallback`): the type table, strings, buffers, structs, callbacks, memory ownership. Includes a tested `scaffold.sh`. |
| **napi-rs** | Build Rust native addons (`.node`) with **napi-rs** for Bun and Node: `#[napi]` macros, async, classes, errors-as-exceptions, ThreadsafeFunction, the build CLI and prebuild model. |
| **wasm-bun** | Run Rust→WebAssembly from Bun with **wasm-bindgen**: the macro surface, `wasm-pack`, and the Bun‑verified loading rule (`--target nodejs`, not `bundler`). |
| **rust-bun** | The *decision + reference* layer — every integration path (bun:ffi, N-API, `Bun.spawn`, WASM, IPC), how to choose, the cross-boundary type rules, and how Bun bridges Rust↔JS internally. |
| **rs-to-ts** | The *workflow* — turn a crate into a distributable Bun package: build automation, a manifest→bindings generator, a prototyping loop, and multi-platform distribution. |

### Agent

- **bun-rs** — a Rust↔Bun integration specialist that picks the right path,
  implements against the skills' templates, and **proves the round trip** with
  `cargo build` + `bun test` instead of guessing.

## Install (local)

```sh
# add this directory as a local plugin marketplace, then install
/plugin marketplace add /home/aphrody/rs-bun
/plugin install rs-bun@rs-bun
```

Or point your Claude Code plugin config at this folder. The four skills are
auto-discovered from `skills/`; the agent is registered via `plugin.json`.

## Proven, not just documented

The runnable artifacts are tested against a real Rust cdylib + Bun:

- `bun-ffi/scripts/scaffold.sh` → `cargo build` + `bun test` green, UTF-8 round trip.
- `rs-to-ts/scripts/gen-bindings.ts` → generates a typed `dlopen` wrapper from a
  symbol manifest (auto string-encoding + `CString`/free), verified end-to-end.

## Layout

```
rs-bun/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── skills/{bun-ffi,napi-rs,wasm-bun,rust-bun,rs-to-ts}/
└── agents/bun-rs.md
```

## Choosing a path (quick)

- Scalars/buffers, prototype fast → **bun:ffi** (`bun-ffi`).
- Rich values, async, production, Node+Bun → **napi-rs** (`napi-rs`).
- Coarse/isolated work, existing CLI → **Bun.spawn** (`rust-bun`).
- One portable sandboxed artifact → **WASM / wasm-bindgen** (`wasm-bun`).
- Ship it as a package → **rs-to-ts**.

`bun:ffi` is officially experimental; for production native code, prefer N-API.
