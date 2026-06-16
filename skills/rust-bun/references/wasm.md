# Rust → WebAssembly for Bun

WASM gives you one portable artifact (no per‑platform native build), a sandbox,
and code you can also ship to browsers. The cost: the WASM ABI only speaks numbers
and linear memory — strings/structs cross via memory + glue, and threads/SIMD/some
syscalls are limited.

> **For the full, Bun‑verified how‑to** (wasm-bindgen macros, every wasm-pack
> target, the load recipes, and the `--target nodejs` rule), use the **`wasm-bun`
> skill**. This page is the decision‑level summary.

## Two routes

1. **`wasm-bindgen` (recommended for rich APIs).** Generates JS glue that handles
   strings, `Vec`, structs, closures across the boundary for you.
2. **Raw `wasm32-unknown-unknown` `extern "C"`** — smallest, no glue, but you
   marshal memory by hand (export functions returning pointers/lengths, read Bun's
   `instance.exports.memory`). Use for tiny numeric kernels.

## wasm-bindgen route

```toml
# Cargo.toml
[lib]
crate-type = ["cdylib"]

[dependencies]
wasm-bindgen = "0.2"
```

```rust
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn add(a: i32, b: i32) -> i32 { a + b }

#[wasm_bindgen]
pub fn greet(name: &str) -> String { format!("hello, {name}") }
```

```bash
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli   # or: bun add -d, then use wasm-pack
cargo build --release --target wasm32-unknown-unknown
wasm-bindgen target/wasm32-unknown-unknown/release/mycrate.wasm \
  --out-dir pkg --target nodejs       # nodejs target for Bun (see below)
```

```ts
// nodejs target self-initializes on import — verified under Bun.
import { add, greet } from "./pkg/mycrate.js";
console.log(add(2, 3), greet("world"));
```

> **Use `--target nodejs` for Bun.** `wasm-pack build --target nodejs` (or the
> raw `wasm-bindgen --target nodejs` above) loads with zero glue. The default
> **`--target bundler` does NOT work under Bun** — Bun resolves an imported
> `.wasm` to a file‑path string, not a module, so the glue throws
> `__wbindgen_start is not a function`. `--target web` works with manual init.
> Full detail in the `wasm-bun` skill.

## Raw route (numeric kernels, no glue)

```rust
#![no_std]   // optional, for minimal size
#[unsafe(no_mangle)]
pub extern "C" fn fib(n: u32) -> u64 {
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 0..n { let t = a + b; a = b; b = t; }
    a
}
```

```ts
const bytes = await Bun.file("./target/wasm32-unknown-unknown/release/mycrate.wasm").arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, {});
const fib = instance.exports.fib as (n: number) => bigint;
console.log(fib(40)); // 102334155n  (i64 export → bigint in JS)
```

For strings/buffers in the raw route: export `alloc(len) -> ptr` and
`dealloc(ptr, len)`, write into `new Uint8Array(instance.exports.memory.buffer,
ptr, len)`, call your function with `(ptr, len)`, read results back out of
`memory.buffer`. This is the same pointer+length discipline as `bun:ffi`, but the
memory is the wasm linear memory rather than the process heap.

## Limits to know

- **i64 exports become `bigint`** in JS; i32/f32/f64 are `number`.
- **No native threads** by default (wasm threads need shared memory + flags and
  aren't broadly enabled). CPU‑bound parallelism won't come for free.
- **Some `std` doesn't work** on `wasm32-unknown-unknown` (no filesystem/network).
  Use `wasm32-wasi` (WASI) if you need syscalls, with a WASI runtime.
- **Per‑call overhead is low** but the boundary marshalling for strings/structs is
  real — for hot loops keep data in wasm memory and call coarsely.

## When to pick WASM

One artifact for every OS/arch, sandboxed execution, or a kernel you also want in
the browser. Not ideal when you need native threads, the full `std`, OS handles,
or the absolute lowest per‑call latency on big data (native FFI/N‑API wins there).
