# Copy‑paste recipes

Each recipe shows the **Rust** side and the matching **TS** binding. Build with
`cargo build --release`; the library lands in `target/release/lib<name>.<suffix>`.

## 0. The minimum: a scalar function

```rust
// src/lib.rs
#[unsafe(no_mangle)]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

```ts
// index.ts
import { dlopen, FFIType, suffix } from "bun:ffi";

const path = `./target/release/libmycrate.${suffix}`;
const { symbols, close } = dlopen(path, {
  add: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
});

console.log(symbols.add(2, 3)); // 5
close(); // optional; frees the dlopen handle
```

> On Rust < 1.82 use `#[no_mangle]` (without `unsafe`). Nightly/1.82+ prefer
> `#[unsafe(no_mangle)]`.

## 1. Rust returns a string (owned — must be freed)

```rust
use std::ffi::{c_char, CString};

#[unsafe(no_mangle)]
pub extern "C" fn greet(name: *const c_char) -> *mut c_char {
    let name = if name.is_null() {
        "world".to_string()
    } else {
        // SAFETY: caller guarantees a NUL-terminated string
        unsafe { std::ffi::CStr::from_ptr(name) }.to_string_lossy().into_owned()
    };
    // Move ownership to the heap and hand the raw pointer to JS.
    CString::new(format!("hello, {name}")).unwrap().into_raw()
}

/// JS MUST call this with the pointer `greet` returned, exactly once.
#[unsafe(no_mangle)]
pub extern "C" fn free_string(p: *mut c_char) {
    if p.is_null() { return; }
    // SAFETY: p came from CString::into_raw; reclaim and drop it.
    drop(unsafe { CString::from_raw(p) });
}
```

```ts
import { dlopen, FFIType, suffix, CString } from "bun:ffi";

const { symbols } = dlopen(`./target/release/libmycrate.${suffix}`, {
  greet: { args: [FFIType.cstring], returns: FFIType.ptr }, // ptr, not cstring,
  free_string: { args: [FFIType.ptr], returns: FFIType.void }, // so we can free it
});

function greet(name: string): string {
  const input = Buffer.from(name + "\0", "utf8");      // NUL-terminate
  const p = symbols.greet(input);                       // returns a pointer number
  try {
    return new CString(p).toString();                   // clones into a JS string
  } finally {
    symbols.free_string(p);                             // free the Rust allocation
  }
}
```

> Why `returns: ptr` not `cstring`? `cstring` would coerce to a string but you'd
> then have no pointer left to pass to `free_string`, leaking the allocation.
> Take the `ptr`, build the `CString` (which clones), then free.

## 2. JS passes a buffer; Rust reads/writes it in place

```rust
#[unsafe(no_mangle)]
pub extern "C" fn sum_bytes(ptr: *const u8, len: usize) -> u64 {
    if ptr.is_null() || len == 0 { return 0; }
    // SAFETY: caller guarantees `ptr` is valid for `len` bytes for the call.
    let s = unsafe { std::slice::from_raw_parts(ptr, len) };
    s.iter().map(|&b| b as u64).sum()
}

#[unsafe(no_mangle)]
pub extern "C" fn fill(ptr: *mut u8, len: usize, value: u8) {
    if ptr.is_null() { return; }
    unsafe { std::slice::from_raw_parts_mut(ptr, len) }.fill(value);
}
```

```ts
const { symbols } = dlopen(path, {
  sum_bytes: { args: [FFIType.ptr, FFIType.u64], returns: FFIType.u64_fast },
  fill:      { args: [FFIType.ptr, FFIType.u64, FFIType.u8], returns: FFIType.void },
});

const buf = new Uint8Array([1, 2, 3, 4]);
symbols.sum_bytes(buf, buf.length);   // pass the view directly → its data pointer
symbols.fill(buf, buf.length, 0xff);  // Rust mutates buf in place
```

> The `Uint8Array` must outlive the call (it does here — it's a local). For
> `*const u32`/`f64` etc., pass the matching typed view so alignment is correct.

## 3. Struct by pointer (`#[repr(C)]`)

```rust
#[repr(C)]
pub struct Point { x: f64, y: f64 }

#[unsafe(no_mangle)]
pub extern "C" fn distance(p: *const Point) -> f64 {
    if p.is_null() { return f64::NAN; }
    let p = unsafe { &*p };
    (p.x * p.x + p.y * p.y).sqrt()
}
```

```ts
const { symbols } = dlopen(path, {
  distance: { args: [FFIType.ptr], returns: FFIType.f64 },
});

// Build the struct bytes in JS (two f64 = 16 bytes, x at 0, y at 8).
const dv = new DataView(new ArrayBuffer(16));
dv.setFloat64(0, 3, true);  // x  (little-endian)
dv.setFloat64(8, 4, true);  // y
console.log(symbols.distance(new Uint8Array(dv.buffer))); // 5
```

> Keep offsets/alignment in sync with `#[repr(C)]`. For reading a struct Rust
> returns by pointer, use `read.f64(ptr, 0)`, `read.f64(ptr, 8)`, etc.

## 4. Rust calls a JS callback

```rust
// A C function pointer: extern "C" fn(i32) -> i32
type Predicate = extern "C" fn(i32) -> i32;

#[unsafe(no_mangle)]
pub extern "C" fn count_matching(ptr: *const i32, len: usize, pred: Predicate) -> u64 {
    let s = unsafe { std::slice::from_raw_parts(ptr, len) };
    s.iter().filter(|&&v| pred(v) != 0).count() as u64
}
```

```ts
import { dlopen, FFIType, suffix, JSCallback } from "bun:ffi";

const { symbols } = dlopen(path, {
  count_matching: {
    args: [FFIType.ptr, FFIType.u64, FFIType.function],
    returns: FFIType.u64_fast,
  },
});

const isEven = new JSCallback((v: number) => (v % 2 === 0 ? 1 : 0), {
  args: [FFIType.i32],
  returns: FFIType.i32,
});

const data = new Int32Array([1, 2, 3, 4, 5, 6]);
try {
  console.log(symbols.count_matching(data, data.length, isEven)); // 3
} finally {
  isEven.close(); // free the JIT'd trampoline + GC root
}
```

> For a callback Rust invokes from another thread, add `threadsafe: true` and make
> it return `void` (see `memory-and-lifetimes.md`). Pass `isEven.ptr` instead of
> `isEven` for a tiny speedup.

## 5. The ergonomic TS wrapper template

Hide raw pointers behind a clean module so callers never see FFI:

```ts
// mycrate.ts
import { dlopen, FFIType as T, suffix, CString } from "bun:ffi";

const lib = dlopen(`${import.meta.dir}/target/release/libmycrate.${suffix}`, {
  add:         { args: [T.i32, T.i32], returns: T.i32 },
  greet:       { args: [T.cstring], returns: T.ptr },
  free_string: { args: [T.ptr], returns: T.void },
});

export const add = (a: number, b: number) => lib.symbols.add(a, b);

export function greet(name: string): string {
  const p = lib.symbols.greet(Buffer.from(name + "\0", "utf8"));
  try { return new CString(p).toString(); }
  finally { lib.symbols.free_string(p); }
}

export const close = lib.close; // call on shutdown if you want to unload
```

## 6. The `bun:test` template

```ts
import { test, expect } from "bun:test";
import { add, greet } from "./mycrate";

test("add: scalars and boundaries", () => {
  expect(add(2, 3)).toBe(5);
  expect(add(-1, 1)).toBe(0);
  expect(add(2147483647, 0)).toBe(2147483647); // i32 max round-trips
});

test("greet: ascii, non-ascii, empty", () => {
  expect(greet("world")).toBe("hello, world");
  expect(greet("café 🦊")).toBe("hello, café 🦊"); // UTF-8 round trip
  expect(greet("")).toBe("hello, ");
});
```

> Assert **exact values**, and include non‑ASCII + boundary inputs — an FFI bug is
> usually silent corruption, not an exception, so weak assertions hide it.

## `cc()` — inline C glue (occasionally useful)

`bun:ffi` also exposes `cc({ source, symbols })` to compile C at runtime (embedded
TinyCC). For a Rust project you rarely need it, but it's handy to write a tiny C
shim that adapts a struct‑by‑value C API into a pointer‑based one your Rust/JS can
consume, without a separate build step. Prefer doing the adaptation in Rust.
