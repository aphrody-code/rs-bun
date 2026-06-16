# wasm-bindgen — build targets and loading under Bun

All findings here were **verified by building every target and running under Bun
1.3.14** (wasm-pack 0.15.0, wasm-bindgen 0.2.125), except where marked.

## `wasm-pack build --target <T>`

Valid targets: `bundler` (default), `nodejs`, `web`, `no-modules`, `deno`.

| Target | Loader mechanism | Works under Bun? |
| --- | --- | --- |
| **`nodejs`** | CommonJS; reads the `.wasm` with `fs.readFileSync` and does a **sync** `WebAssembly.Module`/`Instance`. Self‑initializes on import. | ✅ **Yes — use this.** Zero glue. |
| `web` | ESM with a default‑export async `init(...)` (+ `initSync`). Caller must init. | ✅ Yes, with manual init (feed bytes). |
| `bundler` (default) | ESM `import * as wasm from "./<name>_bg.wasm"` — assumes the bundler treats `.wasm` as a module namespace. | ❌ **No** — see below. |
| `deno` | ESM for Deno. | untested |
| `no-modules` | single global, `<script>` use. | n/a |

### Why `bundler` fails under Bun (the #1 gotcha)

```
TypeError: wasm.__wbindgen_start is not a function
```

Bun's `.wasm` loader resolves an imported `.wasm` to its **file‑path string**, not
an instantiated module namespace. Verified directly:

```ts
import x from "./add.wasm";
typeof x; // "string"  → the absolute path, e.g. "/abs/add.wasm"
```

So the bundler glue's `import * as wasm from "..._bg.wasm"` receives a string with
no exports. Bun (runtime and `bun build`) does not implement the WebAssembly
ESM‑integration proposal the bundler target relies on. **Fix: build with
`--target nodejs`.**

## Loading recipes (verified)

### A) nodejs target — simplest

```sh
wasm-pack build --target nodejs
```
```ts
import mod from "./pkg/bunwasm.js";   // self-initializes
mod.greet("Bun");
const c = new mod.Counter(10); c.increment(); // 11
mod.checked_div(1, 0);                // throws Error: division by zero
```

The generated `.js` ends with synchronous self‑init, fully supported by Bun:
```js
const bytes = require('fs').readFileSync(`${__dirname}/bunwasm_bg.wasm`);
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
wasm.__wbindgen_start();
```

### B) web target — manual init with bytes

```ts
import init, { greet, Counter } from "./pkg/bunwasm.js";
const bytes = await Bun.file(new URL("./pkg/bunwasm_bg.wasm", import.meta.url)).arrayBuffer();
await init({ module_or_path: bytes });        // async — verified
// or: import { initSync } from "..."; initSync({ module: bytes });  // sync — verified
greet("web");
```

### C) Raw path (no wasm-pack) — also Bun‑consumable

```sh
cargo build --target wasm32-unknown-unknown --release
wasm-bindgen target/wasm32-unknown-unknown/release/bunwasm.wasm \
  --out-dir pkg --target nodejs
```
(wasm-pack additionally runs `wasm-opt`; the manual path skips it unless you call
`wasm-opt` yourself.)

### D) Target‑agnostic — the most robust for any `.wasm`

```ts
const bytes = await Bun.file(wasmPath).arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, imports);
```

## Bun's WebAssembly support (verified)

- `WebAssembly` is fully implemented: `instantiate`, `instantiateStreaming`,
  `compileStreaming`, `compile`, `Module`, `Instance`, `Memory`.
- `instantiateStreaming`/`compileStreaming` accept a `fetch()` Response,
  `new Response(Bun.file(...))`, a `ReadableStream` Response, data‑URIs, and string
  bodies (enforces `Content-Type: application/wasm`).
- Bun can run a WASI module directly: `bun ./file.wasm`. `node:wasi` is partially
  implemented.
- **`bun build --compile`** embeds an imported `.wasm` as an asset and gives you
  its path; load it with recipe (D).

## Limits to state honestly

- **Sandbox:** bare `wasm32-unknown-unknown` has no OS — no direct filesystem,
  network, or threads. Reach outside only via imported JS (`extern "C"`), or use
  **WASI** (`wasm32-wasip1`) for fs/clock/env.
- **Threads:** off by default; need `+atomics,+bulk-memory`, a shared
  `WebAssembly.Memory`, and `wasm-bindgen-rayon`/worker plumbing. **Unverified
  under Bun** — Bun has Worker + shared‑memory wasm in its Node test suite, but a
  threaded wasm-bindgen build was not run here.
- **SIMD:** `+simd128` is supported by JSC/Bun engines but was not benchmarked.
- **`std`:** most of `std` works, but `std::thread`, blocking I/O, and direct
  fs/socket access are unavailable on bare `wasm32-unknown-unknown`.
- **No wasm-bindgen tests exist in the Bun repo** — Bun's WASM CI covers the
  standard `WebAssembly` API and WASI, not wasm-bindgen glue. The results above are
  from a hands‑on run on Bun 1.3.14; re‑verify on your build if something looks off.

## When raw wasm32 beats wasm-bindgen

For a tiny numeric kernel with no strings/structs, skip wasm-bindgen: build
`wasm32-unknown-unknown` with `#[no_mangle] extern "C"` exports and use recipe (D)
with `{}` imports. Only i32/i64/f32/f64 cross; you marshal memory by hand via
`instance.exports.memory`. Less glue, smaller output, but you give up the
auto‑marshalling of strings/Vec/classes. (The `rust-bun` skill's `wasm.md` shows
the raw pattern.)
