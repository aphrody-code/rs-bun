# How Bun itself bridges Rust ↔ JavaScript (canonical patterns)

Bun's runtime is the best worked example of a high‑performance Rust↔JS boundary.
You won't copy its internal machinery into an external project, but it shows *why*
the type rules exist and how a serious native↔JS bridge is built. File pointers
are into `oven-sh/bun`; line numbers drift, so search by symbol.

## The big picture

- **Bun = Rust + C++ (JavaScriptCore).** The Rust workspace (~200 crates, rooted
  at the top‑level `Cargo.toml`) compiles to `libbun_rust.a`; C++ in
  `src/jsc/bindings/` hosts JSC. JS builtins live in `src/js/` (a special TS
  dialect, bundled into the binary).
- **Zig→Rust port in progress.** Many `.rs` files have a `.zig` sibling — the Zig
  is a *behavior reference only*, not compiled. New code is Rust. Do not import
  Zig‑era idioms. (`src/runtime/ffi/ffi.zig` is reference; `ffi_body.rs` ships.)

## bun_jsc — the Rust↔JSC glue

`src/jsc/` (crate `bun_jsc`) is where Rust meets the engine:

- **`JSValue`** — the NaN‑boxed JS value (see `type-marshalling.md`). Methods like
  `to_int32`, `get_object`, `is_string`, `to_uint64_no_truncate` do the checked
  conversions.
- **`Strong` / `Weak`** — GC handles. `Strong::create(value, global)` keeps a JS
  value alive across calls; it's `!Send`/`!Sync`, created and dropped on the JS
  thread. This is how Rust safely holds a `JSValue` beyond the current call (the
  same reason a `JSCallback` roots your function).
- **`JSGlobalObject`, `CallFrame`** — the host‑function ABI. A JS‑callable Rust
  fn has the shape `fn(global: &JSGlobalObject, frame: &CallFrame) -> JsResult<JSValue>`.
- **`#[host_fn]` macro** — annotates a Rust fn so codegen emits the C‑ABI shim JSC
  calls. This is the blessed "expose a Rust function to JS" primitive (analogous to
  what N‑API's `#[napi]` does for external addons).

Lesson for your own code: hold JS values beyond a call only via a rooting handle
(`Strong`, or in N‑API a `Ref`); never stash a raw `JSValue`/pointer and read it
later.

## `.classes.ts` codegen — Rust struct ⇄ JS object

`src/codegen/generate-classes.ts` reads declarative `*.classes.ts` specs and
generates **both** the Rust and C++ bindings for a JS class: constructor,
prototype methods, getters/setters, cached values, and a finalizer. Example:
`src/runtime/ffi/ffi.classes.ts` declares the `FFI` class (the object `dlopen`
returns) with a `close` method and a cached `symbols` getter; the generator wires
it to the Rust `FFI` struct in `ffi_body.rs`.

Lesson: when a Rust object must appear as a JS object with methods and a GC‑driven
finalizer, you describe the shape declaratively and let codegen keep the Rust/C++
sides in sync — exactly what **napi-rs**'s `#[napi]` macro does for you in external
projects.

## Foundation crates (why not `std`)

The runtime prefers in‑tree helpers over `std` to keep OS error info and use pools:

- **`bun_core`** (`src/bun_core/`) — `String` (the 5‑variant FFI‑compatible tagged
  union shared with C++; **Latin‑1 ≠ UTF‑8**, conversions need a real encoder),
  `fmt`, `output` logging, typed/cached `env_var`, allocator/`heap` helpers
  (`into_raw`/`take`/`destroy` for FFI round‑trips).
- **`bun_sys`** (`src/sys/`) — syscall wrappers returning `Maybe<T>` (= `Result<T,
  bun_sys::Error>` carrying errno + syscall + path); `File`, `Fd`, `Dir`.
- **`bun_paths`** — path joining/normalization with a path‑buffer pool (avoids
  64 KB stack buffers on Windows).

Lesson: at an FFI boundary, the string type is a tagged union that may be Latin‑1
or UTF‑16 — which is exactly why your external bindings must encode explicitly and
never reinterpret raw bytes.

## The FFI subsystem — a masterclass (`src/runtime/ffi/`)

This is the engine under `bun:ffi`, and it's the clearest demonstration of a
zero‑overhead Rust↔JS call:

- For **every** declared symbol, `Function::print_source_code` (in `ffi_body.rs`)
  emits a tiny C source file, and `Function::compile` JIT‑compiles it with
  **embedded TinyCC** (`bun_tcc_sys`). The generated `JSFunctionCall(global,
  callFrame)` *is* the JSC host function.
- It reads arguments **straight out of the JSC call frame** at a fixed pointer
  offset (`LOAD_ARGUMENTS_FROM_CALL_FRAME` in `FFI.h`), NaN‑box‑decodes each via
  macros (`JSVALUE_TO_INT32`, `JSVALUE_TO_PTR`, …), calls your symbol, and
  re‑encodes the return (`INT32_TO_JSVALUE`, …). No generic marshalling loop — each
  function gets bespoke, inlined C. That's the 2–6× over Node‑API FFI.
- **`JSVALUE_TO_PTR` has a typed‑array fast path:** passing a `TypedArray` returns
  its data vector directly — the zero‑copy buffer behavior you rely on externally.
- The type model is one source of truth: `ABIType` (`abi_type.rs`), an
  `[AbiRow; 21]` table driving the C type names and the to‑C/to‑JS conversion
  macros, kept in sync with `JSFFIFunction.h` and the numbers in `src/js/bun/ffi.ts`.
- **Callbacks** (JS called from C) JIT a reverse trampoline calling
  `FFI_Callback_call`, backed by an `FFICallbackFunctionWrapper` holding
  `JSC::Strong` roots; the threadsafe variant `postTaskTo`s the owning context and
  must return void.
- **Lifetime care:** the `FFI` finalizer is a deliberate no‑op unless `close()`
  ran, because JIT'd trampolines stay reachable via destructured
  `const { fn } = dlopen(...).symbols` — teardown is explicit, not GC‑driven.

Lesson: the rules you follow externally (pointers as numbers, zero‑copy typed
arrays, explicit string encoding, 64‑bit→BigInt, manual memory, closing
callbacks) are not arbitrary — they fall directly out of this design.

## Where to look (search these)

- `src/runtime/ffi/ffi_body.rs` — `cc`/`dlopen`/`linkSymbols`/`callback`,
  `Function::compile`, `print_source_code`.
- `src/runtime/ffi/abi_type.rs` + `src/runtime/ffi/FFI.h` — the type table + the
  NaN‑box conversion macros.
- `src/jsc/bindings/JSFFIFunction.cpp` — the JSC wrapper + callback trampolines.
- `src/js/bun/ffi.ts` — the user‑facing JS builtin (the `FFIType` numbers,
  `FFIBuilder` arg coercion, `CString`, `JSCallback`).
- `src/codegen/generate-classes.ts` + any `*.classes.ts` — the class binding
  generator.
- `CLAUDE.md` and `src/CLAUDE.md` in the repo — the maintainers' own rules for the
  Rust↔JSC boundary (exception checks, GC rooting, thread affinity, allocators).
