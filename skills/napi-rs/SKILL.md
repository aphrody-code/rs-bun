---
name: napi-rs
description: >-
  Build production Rust native addons (`.node`) with napi-rs (v3) for Bun and
  Node: the `#[napi]` macro surface (functions, objects, classes, getters,
  async), errors-as-thrown-exceptions, Buffer/typed-array values,
  ThreadsafeFunction for cross-thread callbacks, the `@napi-rs/cli` build, and the
  multi-platform prebuild/publish model. Use this skill whenever the user wants a
  Rust native module for Bun/Node that needs rich JS values, async, classes, or
  thrown errors, says "use napi-rs", "build a .node addon in Rust", "Rust addon
  for Bun", wants the stable/production alternative to bun:ffi, needs to
  cross-compile and publish a native package, or is debugging a napi-rs build or a
  napi addon under Bun — even if they just say "make my Rust into a fast Node/Bun
  module".
metadata:
  version: "1.0.0"
  keywords: [napi-rs, napi, n-api, rust, native-addon, node, bun, threadsafe-function, prebuild, cdylib]
---

# napi-rs — Rust native addons for Bun and Node

napi-rs builds an ABI‑stable N‑API addon (`.node`) from Rust with ergonomic
macros. The same artifact loads in **Bun** and **Node**. This is the
**production** path for native code: rich JS types, async, classes, errors that
become thrown JS `Error`s, and an automatic `.d.ts`. Bun has a deep N‑API
implementation and tests napi‑rs modules (e.g. `@napi-rs/canvas`) in its own CI.

Reach for **`bun:ffi`** (the `bun-ffi` skill) instead when the surface is just
scalars/pointers/buffers and you want zero codegen and the lowest per‑call
overhead. For choosing between the two, see the `rust-bun` skill. Verified current
versions (mid‑2026): `napi` **3.x**, `napi-derive` **3.x**, `napi-build` **2.x**,
`@napi-rs/cli` **3.x**.

## Fastest start: scaffold with the CLI

```sh
bun add -g @napi-rs/cli       # or: bunx @napi-rs/cli@latest new
napi new                      # interactive: name, targets, package manager
```

This generates a ready crate + `package.json` + CI. If you'd rather wire it by
hand, use the layout below.

## Manual setup (verified against the official template)

```toml
# Cargo.toml
[package]
name = "my-addon"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
napi = "3"
napi-derive = "3"

[build-dependencies]
napi-build = "2"

[profile.release]
lto = true
strip = "symbols"
```

```rust
// build.rs
fn main() { napi_build::setup(); }
```

```rust
// src/lib.rs
#![deny(clippy::all)]
use napi_derive::napi;

#[napi]
pub fn plus_100(input: u32) -> u32 { input + 100 }
```

```json
// package.json — the `napi` block drives the build + prebuilds
{
  "name": "my-addon",
  "version": "0.1.0",
  "napi": {
    "binaryName": "my-addon",
    "targets": ["x86_64-unknown-linux-gnu", "aarch64-apple-darwin", "x86_64-pc-windows-msvc"]
  },
  "scripts": {
    "build": "napi build --platform --release",
    "build:debug": "napi build --platform",
    "prepublishOnly": "napi prepublish -t npm",
    "version": "napi version"
  },
  "devDependencies": { "@napi-rs/cli": "^3.2.0" }
}
```

> `napi = "3"` pulls a broad default N‑API level; the template no longer pins a
> `napiN` feature for the common case. Only add a `napiN` feature if you must cap
> the N‑API version for an older host. Confirm against `references/macros.md`.

## Build, load, iterate

```sh
bun run build           # → my-addon.<platform>.node + index.js + index.d.ts
```

```ts
// napi-rs generates index.js/.d.ts that load the right .node per platform.
import { plus100 } from "./index.js";   // snake_case → camelCase
console.log(plus100(1)); // 101
```

`napi build --platform` emits a native binary tagged with the platform triple, a
JS loader (`index.js`) that picks the correct `.node`, and a TypeScript `.d.ts`.
Re‑run on change; use `build:debug` (no `--release`) for a faster loop.

## The macro surface (the 80%)

Detail and current v3 signatures in `references/macros.md`. The shape:

- **Functions:** `#[napi] pub fn f(a: u32) -> String`. Snake→camel rename is
  automatic; override with `#[napi(js_name = "...")]`.
- **Plain objects:** `#[napi(object)] pub struct P { pub x: f64, pub y: f64 }` ⇄ a
  JS object `{ x, y }`.
- **Classes:** `#[napi] impl Counter { #[napi(constructor)] pub fn new()…;
  #[napi] pub fn inc(&mut self)…; #[napi(getter)] pub fn value(&self)… }` ⇄ a real
  JS class with methods/getters.
- **Errors:** return `napi::Result<T>`; a returned `Err` becomes a **thrown** JS
  `Error` (with `.code` from the `Status`). No sentinel return codes.
- **Async:** `#[napi] pub async fn work(...) -> Result<T>` resolves a JS `Promise`
  and runs off the JS thread. Requires the tokio runtime feature — see
  `references/macros.md` for the exact feature flag and `AsyncTask` for
  CPU‑bound work.
- **Values:** numbers, `String`, `bool`, `Option<T>` (→ null/undefined),
  `Either<A,B>`, `Vec<T>`/`HashMap`, `Buffer`, and typed arrays (`Uint8Array`,
  `Float64Array`, …). Exact import paths in `references/macros.md`.

## Cross‑thread callbacks: ThreadsafeFunction

When Rust must call a JS function from another thread (a worker, a native
callback, a stream), use a **`ThreadsafeFunction`**. Its generics changed in v3,
so copy the current signature from `references/macros.md` rather than guessing.
This is the napi‑rs answer to bun:ffi's threadsafe callbacks and is far more
ergonomic for concurrent work.

## Distribute across platforms

napi‑rs has the prebuild/publish model built in — list `targets` in the `napi`
block, build each in CI, and `napi prepublish` assembles one npm package per
platform with the main package selecting the right binary. Full recipe (CI matrix,
the per‑platform packages, the generated loader, Bun specifics) in
`references/build-and-distribute.md`.

## Bun specifics & honesty

- Bun loads napi‑rs `.node` addons directly (`import`/`require` the generated
  `index.js`); no flag. Async N‑API integrates with Bun's event loop.
- Bun's N‑API surface is large and CI‑guarded but **not bit‑for‑bit identical to
  Node**. On Bun **canary**, an exotic or brand‑new N‑API symbol can have a gap or
  bug — stay on the common API surface, and verify on your actual Bun build rather
  than assuming. The common path (what `@napi-rs/canvas` exercises) is solid.
- napi‑rs can also target `wasm32-wasip1-threads` (via emnapi) for a portable
  build — relevant if you want one artifact without per‑platform native binaries.

## Reference files

- `references/macros.md` — the full v3 `#[napi]` surface with current signatures:
  functions, objects, classes, getters/setters/factory, async + tokio feature,
  errors/`Status`, value/Buffer/typed‑array mapping, and `ThreadsafeFunction`.
- `references/build-and-distribute.md` — `@napi-rs/cli` commands, the `napi`
  package.json block, the cross‑platform prebuild + npm publish model, the
  generated loader, CI matrix, and loading under Bun.
