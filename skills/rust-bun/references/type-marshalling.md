# Cross‑boundary type marshalling — the representation facts

These explain *why* values look the way they do crossing Rust↔Bun. The FFI column
is exact for `bun:ffi`; N‑API converts richer types for you but rests on the same
JSC value representation, so the same edge cases (BigInt thresholds, Latin‑1,
pointer packing) recur.

## JSC value representation (the root cause of the rules)

JSC NaN‑boxes every JS value into a 64‑bit `EncodedJSValue`:
- **int32** → tagged inline (high bits set); cheap.
- **doubles** → the bit pattern plus a `DoubleEncodeOffset` (2^49).
- **pointers/cells** → tagged pointers.
- Bun encodes a **native pointer as a double** holding the address — which is why
  an FFI pointer surfaces as a JS `number`, and why only ~52 bits are usable.

Consequences you must design around:
- **A JS `number` is exact only up to 2^53** (`Number.MAX_SAFE_INTEGER`). Anything
  wider must be `bigint` or it silently loses precision.
- **A pointer is a `number`**, not a `bigint`. Don't declare pointers as `u64`.

## Scalar mapping (bun:ffi)

| Rust | FFIType | JS |
| --- | --- | --- |
| `i8 i16 i32` / `u8 u16 u32` | `i8..i32` / `u8..u32` | `number` |
| `f32 f64` | `f32` / `f64` | `number` |
| `bool` | `bool` | `boolean` |
| `i64 u64` | `i64` / `u64` | **`bigint`** |
| `i64 u64` (small‑value ergonomics) | `i64_fast` / `u64_fast` | `number` ≤2^53 else `bigint` |
| `*const T *mut T` | `ptr` | `number` |
| `*const c_char` | `cstring` (return) | `string` |
| `extern "C" fn` | `function` | `JSCallback` |
| `()` | `void` | `undefined` |

## Strings — always asymmetric

- **Rust → JS:** a `cstring` return is scanned for `\0` and transcoded
  **UTF‑8 → UTF‑16**. The bytes must be NUL‑terminated and stay alive until read.
- **JS → Rust:** no auto conversion. Encode in JS (`Buffer.from(s + "\0", "utf8")`
  or `TextEncoder` + length) and pass a pointer; Rust reads `CStr::from_ptr`
  (NUL) or `slice::from_raw_parts(p, len)` (explicit length).
- **Latin‑1 hazard:** JSC stores some strings as 1‑byte Latin‑1, others as UTF‑16.
  Latin‑1 bytes 128–255 are NOT valid UTF‑8. Never reinterpret raw string bytes;
  go through real encoders. Test with accents and CJK, not just ASCII/emoji.

## Buffers / typed arrays — zero copy, with caveats

- A `TypedArray`/`DataView` passed to a `ptr`/`buffer` arg passes its **backing
  data pointer** directly. Rust gets `*const u8` (+ you pass the length).
- The view must **outlive the synchronous call** and be **aligned** for the C type
  (`*const f64` ⇒ 8‑byte alignment ⇒ pass a `Float64Array`, not an offset
  `Uint8Array`). `u64*` ≠ `[8]u8*` if misaligned.
- Going the other way, materialize a JS view over a native pointer with
  `toArrayBuffer(ptr, off, len)` / `toBuffer(...)`, or read scalars with
  `read.u8/i32/f64/ptr(ptr, byteOffset)`.

## What does NOT cross bun:ffi (use N‑API or flatten)

Rust `String`, `Vec<T>`, `&str`, `Option`, `Result`, data‑carrying enums, tuples,
trait objects, closures, and `#[repr(Rust)]` structs. Across FFI: flatten to
scalars, or pass `#[repr(C)]` by pointer + length, or return owned pointer +
provide `free_*`. If you find yourself wanting these to "just work," that's the
signal to switch to **N‑API** (`references/napi.md`), which marshals objects,
arrays, strings, and typed arrays natively.

## Memory ownership (FFI)

bun:ffi manages nothing. Every cross‑boundary allocation has **one owner, freed
once, with the allocator that made it**. Rust‑owned data handed to JS ⇒ export a
matching `free_*` (`Box::into_raw`/`from_raw`, `CString::into_raw`/`from_raw`) and
have JS call it, or tie it to GC with a `toArrayBuffer` deallocator callback. (The
`bun-ffi` skill's `memory-and-lifetimes.md` is the deep reference.) N‑API handles
this for you via the GC.
