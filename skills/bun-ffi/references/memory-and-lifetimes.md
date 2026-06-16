# Memory & lifetimes across the Rust ↔ Bun boundary

`bun:ffi` does **no** memory management for you. Every byte that crosses the
boundary has exactly one owner, freed exactly once, with the allocator that
allocated it. Getting this wrong is the dominant cause of FFI crashes — and they
reproduce under load or at GC time, not deterministically.

## The one‑sentence ownership test

Before you return or store any pointer, answer out loud:

> *"This pointer was allocated by **\_\_** using **\_\_**; it is freed by **\_\_**
> on **\_\_**, exactly once."*

If you can't fill every blank, you have a leak or a use‑after‑free. Write the
answer as a comment next to the function.

## Rules

1. **Rust‑owned allocation handed to JS → pair it with a `free_*` export.**
   Use `Box::into_raw` / `CString::into_raw` to transfer ownership out, and a
   matching `free_*` that does `Box::from_raw` / `CString::from_raw` and drops it.
   Same allocator both sides (the Rust global allocator). JS must call `free_*`
   exactly once, typically in a `finally`.

   ```rust
   #[unsafe(no_mangle)]
   pub extern "C" fn make_thing() -> *mut Thing {
       Box::into_raw(Box::new(Thing::new()))
   }
   #[unsafe(no_mangle)]
   pub extern "C" fn free_thing(p: *mut Thing) {
       if !p.is_null() { drop(unsafe { Box::from_raw(p) }); }
   }
   ```

2. **Never return a pointer into a value that drops at end of function.**
   `CString::new(s).unwrap().as_ptr()` returns a dangling pointer — the `CString`
   is dropped on the next line. Use `.into_raw()` (transfer) and free later. Same
   for returning `&local_vec[..]`, a `&str` into a temporary, etc.

3. **Borrowed pointers (JS → Rust for the duration of one call) are fine to read
   without freeing** — JS still owns them. `slice::from_raw_parts(ptr, len)` is
   valid only for that call; do not stash the pointer in Rust state and read it
   later (JS may have freed/moved the buffer, GC may have collected it).

4. **JS‑owned buffers passed to Rust must outlive the call.** A `TypedArray`
   passed to a `ptr` arg is valid during the synchronous call. If Rust keeps the
   pointer for async/later use, JS must guarantee the buffer stays alive and
   un‑moved (hold a reference; note GC can move/free). Prefer: Rust copies what it
   needs before returning.

5. **`ArrayBuffer` from `toArrayBuffer` can be detached.** If you `toArrayBuffer`
   a Rust‑owned region and Rust later frees it, JS reads freed memory. Tie the
   lifetimes with a **deallocator callback**.

## Deallocator callbacks — letting Rust free what it lent to JS

`toArrayBuffer(ptr, byteOffset, byteLength, ctx?, deallocator)` registers a
callback invoked when the JS `ArrayBuffer` is garbage‑collected. Signature
(JSC's `JSTypedArrayBytesDeallocator`):

```c
void deallocator(void* bytes, void* ctx);
```

```rust
#[unsafe(no_mangle)]
pub extern "C" fn export_bytes(out_len: *mut usize) -> *mut u8 {
    let mut v = vec![0u8; 1024];
    unsafe { *out_len = v.len(); }
    let p = v.as_mut_ptr();
    std::mem::forget(v); // hand the allocation to JS; freed via the callback
    p
}

#[unsafe(no_mangle)]
pub extern "C" fn free_bytes(bytes: *mut u8, ctx: *mut std::ffi::c_void) {
    let len = ctx as usize; // we encoded len in ctx; or store a header
    if !bytes.is_null() {
        // SAFETY: rebuild the Vec with the SAME len/cap to free correctly.
        drop(unsafe { Vec::from_raw_parts(bytes, len, len) });
    }
}
```

```ts
import { toArrayBuffer, read } from "bun:ffi";
const lenBuf = new BigUint64Array(1);
const p = symbols.export_bytes(lenBuf);          // returns ptr; writes len
const len = Number(lenBuf[0]);
const ab = toArrayBuffer(p, 0, len, len /*ctx*/, symbols.free_bytes /*dealloc ptr*/);
// ...use ab... freed automatically when GC collects it.
```

> Reconstructing a `Vec` requires the **same capacity** you forgot it with. If
> capacity ≠ length, store both (e.g. a small header) and rebuild precisely, or
> use `Box<[u8]>` (`into_raw` / `from_raw`) where len == cap.

## Callback lifetimes (`JSCallback`)

- A `JSCallback` owns a JIT‑compiled trampoline **and** a GC root on your JS
  function. It does **not** free on its own — call `cb.close()` (or `using cb` /
  `Symbol.dispose`). Leaking them leaks executable pages.
- Do not `close()` a callback while native code might still call it. Close after
  you're certain the Rust side is done (e.g. after the call returns, or after the
  Rust object that stored the pointer is freed).
- **Threadsafe callbacks** (`threadsafe: true`): required when Rust invokes the
  callback from a non‑JS‑instantiation thread. The call is marshalled back to the
  owning JS context asynchronously, so the callback **must return `void`** — there
  is no value to send back across the thread hop. They currently work best when
  the calling thread is itself running JS (a Bun `Worker`). The wrapper is
  reference‑counted, so in‑flight posted tasks stay valid even after `close()`.

## Quick GC‑safety stress test

If a binding stores pointers or buffers across calls, prove it under GC pressure:

```ts
import { test, expect } from "bun:test";
test("no UAF under GC churn", () => {
  for (let i = 0; i < 10_000; i++) {
    const r = greet("x".repeat(i % 64));
    expect(typeof r).toBe("string");
    if (i % 1000 === 0) Bun.gc(true);
  }
});
```
