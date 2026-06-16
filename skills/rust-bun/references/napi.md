# N‑API with napi-rs — when and why (decision)

N‑API (Node‑API) is the ABI‑stable native addon interface. Bun implements it, so a
Rust `.node` addon built with **napi-rs** loads in Bun *and* Node. Prefer it over
`bun:ffi` for anything production‑grade, anything with rich JS values, and anything
async.

> **For the full how‑to** (setup, `#[napi]` macros, async, classes,
> ThreadsafeFunction, the build CLI, prebuilds, Bun gotchas), use the **`napi-rs`
> skill** — it's the hands‑on reference. This page is just the choice.

## Why N‑API over bun:ffi

| | bun:ffi | N‑API (napi-rs) |
| --- | --- | --- |
| Setup | `cargo build`, no codegen | codegen + `.node`, build CLI |
| Types that cross | scalars, pointers, buffers | numbers, strings, objects, arrays, typed arrays, `Buffer`, classes, functions |
| Async | manual / threadsafe callbacks | first‑class (`async fn` + `tokio_rt`, `AsyncTask`) |
| Errors | return codes / sentinels | Rust `Result<T>` → thrown JS `Error` |
| Memory | you hand‑manage | handled by the framework + GC |
| Stability | Bun marks experimental | ABI‑stable, Node‑portable |
| Speed | fastest per‑call (JIT trampoline) | slightly more per‑call overhead |

Rule of thumb: **prototype with bun:ffi, ship with N‑API** — unless the API is
genuinely just numbers/buffers, in which case bun:ffi is fine to keep.

## Minimal shape (current = napi v3)

```toml
# Cargo.toml — verified current versions
[lib]
crate-type = ["cdylib"]
[dependencies]
napi = "3"
napi-derive = "3"
[build-dependencies]
napi-build = "2"
```

```rust
// build.rs
fn main() { napi_build::setup(); }
```

```rust
// src/lib.rs
use napi_derive::napi;
#[napi]
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

Build with `@napi-rs/cli` (`napi build --platform --release`) → emits the `.node`,
a JS loader, and a `.d.ts`. (Full workflow in the `napi-rs` skill.)

## Bun specifics

- Bun loads napi‑rs `.node` addons directly (`import`/`require` the generated
  `index.js`); no flag. Async N‑API integrates with Bun's event loop.
- **Event‑loop caveat:** on Linux/macOS Bun is **not** libuv‑backed, so native code
  must use `napi_get_uv_event_loop` rather than `uv_default_loop()`. napi‑rs's own
  async/TSFN paths go through Node‑API and work; raw libuv usage in a dependency is
  the risk.
- Bun's N‑API surface is broad and CI‑guarded (Bun tests `@napi-rs/canvas`) but not
  bit‑for‑bit Node — on **canary**, verify exotic APIs on your actual build.

## When N‑API is overkill

If the surface is "call this Rust math/codec on a buffer and get bytes back," the
codegen + `.node` machinery may not be worth it — `bun:ffi` (the `bun-ffi` skill)
is fewer moving parts. Choose by how rich the values crossing the boundary are.
