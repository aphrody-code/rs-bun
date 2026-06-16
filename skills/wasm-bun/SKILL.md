---
name: wasm-bun
description: >-
  Build and run Rust→WebAssembly modules from Bun with wasm-bindgen: the setup,
  the `#[wasm_bindgen]` macro surface (functions, classes, Result→throw, async,
  importing JS, js-sys), the `wasm-pack` build, and — critically — which target
  actually loads under Bun (`nodejs`, NOT `bundler`). Use this skill whenever the
  user wants to call Rust from Bun via WASM, "use wasm-bindgen", "wasm-pack with
  Bun", run a `.wasm` from a Rust crate in Bun, wants a portable sandboxed Rust
  artifact instead of a native addon, or is debugging why a wasm-bindgen module
  won't load in Bun (`__wbindgen_start is not a function`, wasm import resolving
  to a string) — even if they just say "compile my Rust to WASM for Bun".
metadata:
  version: "1.0.0"
  keywords: [wasm, webassembly, wasm-bindgen, wasm-pack, rust, bun, js-sys, wasm32, nodejs-target]
---

# wasm-bun — Rust → WebAssembly from Bun (wasm-bindgen)

Run a Rust crate inside Bun's JS VM as WebAssembly, with rich types
auto‑marshalled by **wasm-bindgen**. One portable, sandboxed artifact — no
per‑platform native build. The trade‑off vs native (`bun:ffi`/`napi-rs`): you run
in the WASM sandbox (no direct fs/net/threads except through imported JS), and
data crosses an FFI copy boundary.

> Choosing between WASM, `bun:ffi`, and `napi-rs`? See the `rust-bun` skill's
> decision matrix. Short version: **WASM** for portability + sandbox; **napi-rs**
> for native speed + full OS access; **bun:ffi** for the lowest‑overhead native
> calls on a C ABI.

## ⚠️ The one rule that saves you an hour: use `--target nodejs`

This is the headline Bun fact, **verified on Bun 1.3.14**:

- **`wasm-pack build --target nodejs` → loads in Bun with zero glue.** Use this.
- **`--target web`** also works, but you must init manually by feeding bytes.
- **`--target bundler` does NOT work under Bun.** You get
  `TypeError: wasm.__wbindgen_start is not a function` (or a `bun build` warning
  that `__wbindgen_start` is undefined). **Root cause:** Bun's `.wasm` loader
  resolves an imported `.wasm` to its **file‑path string**, not an instantiated
  module namespace — Bun does not implement the WebAssembly ESM‑integration
  proposal the bundler target assumes. `import x from "./m.wasm"` gives you
  `"/abs/path/m.wasm"` (a string), so the bundler glue's `import * as wasm from
  "..._bg.wasm"` has no exports.

If a wasm-bindgen module won't load in Bun, the cause is almost always the wrong
target. Rebuild with `--target nodejs`.

## Verified versions (2026‑06)

`wasm-bindgen` **0.2.125** · `wasm-bindgen-futures` **0.4.75** · `js-sys`/`web-sys`
**0.3.102** · `wasm-pack` **0.15.0**. Pin loosely (`wasm-bindgen = "0.2"`); the
wasm-bindgen **CLI version must match the crate** — wasm-pack handles that
automatically.

## Quick start

```toml
# Cargo.toml
[lib]
crate-type = ["cdylib"]      # add "rlib" too if other Rust code links it
[dependencies]
wasm-bindgen = "0.2"
```

```rust
// src/lib.rs
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn greet(name: &str) -> String { format!("Hello, {name}!") }
```

```sh
rustup target add wasm32-unknown-unknown
cargo install wasm-pack          # once
wasm-pack build --target nodejs  # → pkg/<name>.js + <name>_bg.wasm + .d.ts
```

```ts
// VERIFIED working in Bun (nodejs target self-initializes on import):
import mod from "./pkg/bunwasm.js";
console.log(mod.greet("Bun")); // "Hello, Bun!"
```

## The `#[wasm_bindgen]` surface (the 80%)

Detail + current signatures in `references/macros.md`. The shape:

- **Functions:** `&str`/`String`/`Vec<T>`/`Option<T>`/numbers/`bool` cross
  automatically. Snake→camel rename is automatic.
- **Classes:** `#[wasm_bindgen] impl Counter { #[wasm_bindgen(constructor)] …;
  #[wasm_bindgen(getter)] … }` ⇒ a real JS class. Instances own a Rust pointer,
  released by a `FinalizationRegistry` and an explicit `.free()`.
- **Errors:** return `Result<T, JsError>` (or any `E: Into<JsValue>`) → a thrown
  JS `Error`. (Verified: `1/0` throws under Bun.)
- **Import JS into Rust:** `#[wasm_bindgen] extern "C" { … }` with `js_namespace`,
  `js_name`, `catch`, `method`.
- **Async:** `async fn` → a JS `Promise` via `wasm-bindgen-futures`; `JsFuture`
  awaits a `js_sys::Promise`. *(Mechanism is standard Promise/microtask — works in
  principle under Bun but not independently run; verify your async path.)*
- **js-sys** (ECMAScript builtins: `Array`, `Object`, `Promise`, `JSON`, …) is
  useful under Bun. **web-sys** is browser DOM and **mostly useless under Bun** —
  no `window`/`document`; prefer `extern "C"` imports of Bun globals or `js-sys`.

## Loading under Bun — the robust recipes

`references/build-and-load.md` has all targets and the verified load code. The
two you'll use:

```ts
// A) nodejs target — simplest, self-initializing:
import mod from "./pkg/bunwasm.js";

// B) target-agnostic / raw .wasm — the most robust, works for any module:
const bytes = await Bun.file(new URL("./pkg/bunwasm_bg.wasm", import.meta.url)).arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, imports);
```

Bun fully implements the `WebAssembly` global (`instantiate`,
`instantiateStreaming`, `compileStreaming`, `Module`, `Instance`, `Memory`) and
can run WASI modules directly (`bun ./file.wasm`). `bun build --compile` embeds an
imported `.wasm` as an asset.

## Limits to state honestly

- **Sandbox:** no direct filesystem/network/threads on bare
  `wasm32-unknown-unknown`; reach the outside only through imported JS, or use
  WASI (`wasm32-wasip1`) for fs/clock/env.
- **Threads** (`+atomics,+bulk-memory` + shared memory + `wasm-bindgen-rayon`) and
  **SIMD** (`+simd128`) are off by default; both are *unverified under Bun* —
  test before relying on them.
- **Per‑call copy overhead:** strings/Vecs cross by copy. For hot loops keep data
  in wasm linear memory and call coarsely.
- Bun has **no wasm-bindgen tests of its own** (its WASM CI covers the standard
  `WebAssembly` API + WASI). The results above were verified by hand on Bun
  1.3.14 — re‑verify on your build if behavior looks off.

## Reference files

- `references/macros.md` — the full `#[wasm_bindgen]` surface: functions, classes,
  `Result`/`JsError`, `extern "C"` JS imports, closures, async +
  `wasm-bindgen-futures`, and js-sys vs web-sys.
- `references/build-and-load.md` — every `wasm-pack` target (what each emits, which
  work under Bun), the raw `cargo + wasm-bindgen` path, the verified Bun load
  recipes, `bun build --compile` embedding, and the threads/SIMD/std limits.
