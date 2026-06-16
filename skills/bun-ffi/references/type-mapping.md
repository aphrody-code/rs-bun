# Rust ↔ FFIType ↔ JS — complete type mapping

The declared `FFIType` must match the Rust `extern "C"` parameter/return type
exactly. The C trampoline reinterprets raw bytes; there is no runtime type check.

## Master table

| `FFIType` (+ aliases)                    | Rust `extern "C"` type        | JS value in/out         | Notes |
| ---------------------------------------- | ----------------------------- | ----------------------- | ----- |
| `i8` / `int8_t` / `char`                 | `i8` (`c_char` is `i8`)       | `number`                | |
| `u8` / `uint8_t`                         | `u8`                          | `number`                | |
| `i16` / `int16_t`                        | `i16`                         | `number`                | |
| `u16` / `uint16_t`                       | `u16`                         | `number`                | |
| `i32` / `int32_t` / `int` / `c_int`      | `i32`                         | `number`                | |
| `u32` / `uint32_t` / `c_uint`            | `u32`                         | `number`                | |
| `i64` / `int64_t` / `isize`              | `i64` (`isize` on 64‑bit)     | **`bigint`** (return)   | accepts `number`\|`bigint` as arg |
| `u64` / `uint64_t` / `usize` / `size_t`  | `u64` (`usize` on 64‑bit)     | **`bigint`** (return)   | accepts `number`\|`bigint` as arg |
| `i64_fast`                               | `i64`                         | `number` if ≤2^53 else `bigint` | prefer for ergonomics |
| `u64_fast`                               | `u64`                         | `number` if ≤2^53 else `bigint` | prefer for ergonomics |
| `f32` / `float`                          | `f32`                         | `number`                | |
| `f64` / `double`                         | `f64`                         | `number`                | |
| `bool`                                   | `bool`                        | `boolean`               | Rust `bool` is 1 byte = C `_Bool` |
| `ptr` / `pointer` / `void*` / `char*`    | `*const T` / `*mut T`         | `number` (a pointer)    | see "Pointers" |
| `cstring`                                | `*const c_char` (`*const i8`) | **arg:** like `ptr`; **return:** `string` | see "Strings" |
| `buffer`                                 | `*const u8` / `*mut u8`       | arg only: TypedArray/DataView | cannot be a return type |
| `function` / `fn` / `callback`           | `extern "C" fn(...) -> ...`   | `JSCallback` (or its `.ptr`) | see callbacks recipe |
| `void`                                   | `()` (no return)              | `undefined`             | return only |
| `napi_env` / `napi_value`                | (N‑API interop)               | —                       | advanced; not for plain Rust |

`use core::ffi::{c_char, c_int, c_void};` for ABI‑exact C aliases. On all
platforms Bun targets, `c_char = i8`, `c_int = i32`.

## Pointers (the #1 source of bugs)

- A pointer is a **JS `number`**, NOT a BigInt. 64‑bit addresses fit because Bun
  uses the 52 usable mantissa bits (52‑bit addressable space on real CPUs).
- **Windows `HANDLE` is not a virtual address** — represent it as `u64`, not
  `ptr`, or values break.
- **Passing a `TypedArray`/`DataView` to a `ptr` or `buffer` arg passes the
  data pointer with zero copy.** Rust receives `*const u8` to the backing store.
  The view must (a) stay alive for the whole call and (b) be aligned/sized for the
  C type — a `*const u64` needs 8‑byte alignment; a `Uint8Array` isn't guaranteed
  aligned. Use the typed view that matches (`Float64Array` for `*const f64`, etc.)
  or `ptr(typedarray, byteOffset)` for an explicit offset.
- To get a raw pointer number from a TypedArray explicitly: `ptr(view)` (returns a
  `number`). Usually unnecessary — pass the view directly.
- A returned `ptr` is a `number`; read it with `read.*`, `toArrayBuffer`, or
  `new CString(p)`.

## Strings (asymmetric — read carefully)

- **Rust → JS:** return `*const c_char` declared as `cstring`. Bun scans for `\0`
  and transcodes UTF‑8→UTF‑16 into a JS `string`. The pointer must remain valid
  and the bytes must be NUL‑terminated. If you build a `std::ffi::CString` and
  return its pointer, you MUST keep it alive (leak it or own it) — see
  `memory-and-lifetimes.md`.
- **JS → Rust:** there is NO automatic string→pointer conversion. Passing a JS
  `string` to a `ptr`/`cstring` arg **throws** `TypeError`. Encode it first:
  `Buffer.from(str + "\0", "utf8")` (add the NUL yourself) and pass the buffer,
  or pass `(ptr, len)` from a `TextEncoder` result. Rust then reads
  `CStr::from_ptr` (NUL‑terminated) or `slice::from_raw_parts(p, len)` (explicit
  length — safer, no NUL needed).
- **Encoding trap:** JSC stores some strings as Latin‑1 (1 byte) and some as
  UTF‑16. Never reinterpret raw bytes as UTF‑8 yourself; let `CString`/`CStr` and
  proper encoders handle it. Test with non‑ASCII (accents, CJK, emoji).

## Structs

There is no struct marshalling. Two options:

1. **By pointer (recommended):** define a `#[repr(C)]` struct in Rust, pass a
   `*mut MyStruct` (a `ptr`), and have JS read/write fields with `read.*` at known
   byte offsets, or build the struct bytes in a `DataView`/`ArrayBuffer` on the JS
   side and pass it. You are responsible for matching offsets and alignment.
2. **Flatten:** pass each field as a separate scalar arg. Simplest for small
   structs; no layout to keep in sync.

Never pass a `#[repr(Rust)]` struct or return a struct by value across FFI — the
layout is unspecified.

## Not representable across `bun:ffi`

Rust `String`, `Vec<T>`, `&str`, `Option<T>`, `Result<T,E>`, enums with data,
tuples, traits/`dyn`, closures (use `extern "C" fn` + a `void* ctx` instead),
and any `#[repr(Rust)]` type. Convert to pointer+length or scalars at the
boundary. If you need any of this richly, that's the signal to use N‑API
(`napi-rs`) instead — see the `rust-bun` skill.
