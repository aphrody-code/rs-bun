---
name: rust-bun
description: >-
  The reference and decision guide for connecting Rust and Bun in ANY project:
  every integration path (bun:ffi cdylib, N-API via napi-rs, Bun.spawn
  subprocess, WebAssembly, stdio IPC), how to choose between them, the complete
  cross-boundary type-marshalling rules, and how Bun itself bridges Rust↔JS
  internally (the canonical reference patterns from the official oven-sh/bun
  repo: the FFI JIT trampoline, bun_jsc/host_fn, the .classes.ts codegen,
  bun_sys/bun_core). Use this skill whenever the user asks "how do Rust and Bun
  fit together", "what's the best way to call Rust from Bun", "should I use FFI
  or N-API", needs the Rust↔JS type mapping, is architecting a native module for
  Bun, or wants to understand how Bun's own Rust internals talk to JavaScript —
  even if they don't name a specific mechanism.
metadata:
  version: "1.0.0"
  keywords: [rust, bun, ffi, napi, napi-rs, n-api, wasm, bun.spawn, jsc, bun_jsc, native-addon]
---

# rust-bun — how Rust and Bun connect

Use this as the map: pick the right integration path, get the type‑marshalling
rules right, and—when you want to see how the pros do it—understand how Bun
itself bridges Rust and JavaScript internally.

This skill is the **decision + reference** layer. For the hands‑on FFI binding
mechanics use **`bun-ffi`**; for packaging a crate into a shippable Bun package
use **`rs-to-ts`**.

## The five ways Rust talks to Bun

| Path | Shape | Latency | Best for | Skill |
| --- | --- | --- | --- | --- |
| **bun:ffi** | Rust `cdylib` + `extern "C"` symbols, loaded with `dlopen` | very low (JIT'd trampoline) | numeric/buffer APIs, prototyping, no build codegen | `bun-ffi` |
| **N‑API (napi-rs)** | Rust `cdylib` → `.node`, `#[napi]` macros | low | production addons, rich JS objects, async, errors‑as‑exceptions, Node+Bun portability | `napi-rs` (deep) · `references/napi.md` (decision) |
| **Bun.spawn** | Rust **binary** as a subprocess, talk over stdio/JSON/protocol | high (process + serialize) | coarse‑grained work, isolation, reuse an existing CLI, crash containment | `references/subprocess.md` |
| **WebAssembly** | Rust → `wasm32`, `WebAssembly.instantiate` | low‑med | sandboxed, portable, browser‑shareable, no native build per‑platform | `wasm-bun` (deep) · `references/wasm.md` |
| **stdio / socket IPC** | long‑lived Rust daemon, framed messages | med | streaming, many calls, language‑agnostic boundary | `references/subprocess.md` |

## Choosing — decide by what crosses the boundary

- **Just numbers, pointers, buffers; want it working in minutes** → **bun:ffi**.
  No codegen, `cargo build` is the whole build. Caveat: Bun marks it
  *experimental*; you hand‑manage memory; rich types don't cross.
- **You need JS objects/arrays/promises/exceptions, or the same addon must run on
  Node too, or it's going to production** → **N‑API (napi-rs)**. More setup
  (codegen, `.node`), but stable, ergonomic, async‑aware. Bun's own docs
  recommend N‑API as the stable way to use native code.
- **You already have a Rust CLI, or want hard isolation / crash containment, or
  calls are coarse and infrequent** → **Bun.spawn** a subprocess.
- **You want one artifact that runs everywhere with no per‑platform native
  build, and a sandbox** → **WASM** (accepting the wasm ABI limits: numbers,
  linear memory, no threads by default).
- **Streaming or a persistent service boundary** → a **Rust daemon + IPC**.

Full trade‑offs, gotchas, and a worked example per path live in `references/`.
Read the one that matches the chosen path before implementing.

## Cross‑boundary type marshalling (the rules that bite)

These hold for `bun:ffi`; N‑API does richer conversions for you, but the
representation facts still explain its edge cases. Full table in
`references/type-marshalling.md`.

- **Pointers are JS `number`s**, not BigInt — Bun packs a 64‑bit address into the
  52 usable mantissa bits of a double. (Windows `HANDLE` ≠ address → use `u64`.)
- **64‑bit ints** surface as `bigint` (`i64`/`u64`) or as `number`‑when‑small
  (`i64_fast`/`u64_fast`). JS numbers are exact only to 2^53.
- **Strings are asymmetric:** Rust→JS via `cstring` (UTF‑8→UTF‑16, NUL‑scanned);
  JS→Rust needs explicit byte encoding (`Buffer.from(s+"\0")`). JSC strings may be
  **Latin‑1**, never reinterpret raw bytes as UTF‑8.
- **TypedArray/DataView → `ptr`/`buffer` passes the data pointer with zero copy**;
  the view must outlive the call and match alignment.
- **No Rust `String`/`Vec`/`Option`/enum/`#[repr(Rust)]` struct crosses FFI** —
  flatten to scalars or pass `#[repr(C)]` by pointer + length.
- **Memory is unmanaged in FFI:** every cross‑boundary allocation needs one owner
  and a matching `free_*`. (`references/type-marshalling.md` + the `bun-ffi`
  memory reference.)

## How Bun itself bridges Rust ↔ JavaScript (canonical reference)

Bun's own runtime is the best worked example of Rust↔JS integration, and the
patterns there are the "blessed" way. Read `references/how-bun-does-it.md` for the
detail; the shape:

- **Bun is Rust + C++ (JavaScriptCore).** Rust compiles to `libbun_rust.a`; C++
  hosts JSC. (Many `.zig` files remain as a *porting reference only* — Bun is
  mid Zig→Rust port; new code is Rust. Don't cargo‑cult the `.zig`.)
- **`bun_jsc`** is the Rust↔JSC glue: `JSValue`, `Strong`/`Weak` GC handles,
  `JSGlobalObject`, `CallFrame`, and the `#[host_fn]` macro that exposes a Rust
  fn as a JS‑callable function.
- **`.classes.ts` codegen** (`generate-classes.ts`) generates Rust + C++ bindings
  for JS classes from a declarative spec — how a Rust struct becomes a JS object
  with prototype methods, getters, and a finalizer.
- **Foundation crates:** `bun_core` (strings/`String`, fmt, env, allocator),
  `bun_sys` (syscalls, `File`/`Fd`), `bun_paths` (path ops) — the runtime uses
  these instead of `std` to preserve OS error info and use pools.
- **The FFI subsystem itself** (`src/runtime/ffi/`) is a masterclass: it
  JIT‑compiles a per‑symbol C trampoline (embedded TinyCC) that reads JSValues
  straight from the JSC call frame and NaN‑box‑decodes them. That's the engine
  under `bun:ffi`, and `references/how-bun-does-it.md` walks it.

You won't copy Bun's internal machinery into your project, but understanding it
tells you *why* the type rules are what they are and how a high‑performance
Rust↔JS boundary is designed.

## Reference files

- `references/napi.md` — N‑API via `napi-rs`: setup, `#[napi]`, async, errors,
  objects, when to prefer it over FFI, Bun specifics.
- `references/subprocess.md` — `Bun.spawn` and long‑lived daemon/IPC patterns,
  framing, backpressure, lifecycle.
- `references/wasm.md` — Rust→`wasm32` for Bun: build, instantiate, memory,
  `wasm-bindgen` vs raw, limits.
- `references/type-marshalling.md` — the full cross‑boundary type table and the
  representation facts (NaN‑boxing, BigInt thresholds, Latin‑1, alignment).
- `references/how-bun-does-it.md` — the canonical oven-sh/bun internals:
  `bun_jsc`/`host_fn`, `.classes.ts` codegen, `bun_core`/`bun_sys`, and the FFI
  JIT trampoline, with file pointers.
