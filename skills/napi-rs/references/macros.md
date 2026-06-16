# napi-rs v3 — the `#[napi]` macro surface

Current API (napi 3.x). All examples assume:

```rust
use napi_derive::napi;
use napi::bindgen_prelude::*;
```

> **v2 → v3 rename:** v3 uses prelude types `Object`, `Unknown`, `Function`,
> `Array`, etc. The old `JsObject` / `JsUnknown` / `JsString` / `JsNumber`
> wrappers are **compat mode** (`/docs/compat-mode/`). Most third‑party tutorials
> still show the `JsXxx` names — don't mix them with v3. If you see `JsObject`,
> you're reading v2 docs.

## Table of contents
1. Feature flags
2. Functions
3. Objects (`#[napi(object)]`)
4. Classes (`#[napi] impl`)
5. Async: `async fn` and `AsyncTask`
6. Value & type mapping
7. Errors
8. ThreadsafeFunction (cross‑thread callbacks)

---

## 1. Feature flags (on the `napi` dependency)

```toml
napi = { version = "3", features = ["napi9", "async", "serde-json"] }
```

- **`napi1` … `napi10`** — the Node‑API version you compile against. Higher = newer
  host required at the symbol level. `napi6` is required for `BigInt`; `napi8`/
  `napi9` are the common modern baseline (treat as "Node 16+/18+"; the docs don't
  publish an exact per‑flag floor). Pick the lowest that has what you use.
- **`async`** — enables `async fn` (futures → JS `Promise`).
- **`tokio_rt`** — bundles a Tokio runtime on a side thread so you can `.await`
  Tokio futures.
- **`serde-json`** — serde (de)serialize between JS objects and Rust structs.
- **`latin1`** — Latin‑1 string decoding. **`chrono`**, **`web_stream`**,
  **`compat-mode`** also exist.

---

## 2. Functions

Snake_case → camelCase is automatic (`sum_two` → `sumTwo`).

```rust
#[napi]
pub fn fibonacci(n: u32) -> u32 {
  match n { 1 | 2 => 1, _ => fibonacci(n - 1) + fibonacci(n - 2) }
}

#[napi(js_name = "sumBigInt")]     // explicit name override
pub fn sum(a: u32, b: u32) -> u32 { a + b }
```

Request `Env` as the **first** parameter and napi‑rs injects it (handle to the
Node‑API environment — create values, schedule microtasks, get the uv loop):

```rust
#[napi]
pub fn make(env: Env, n: u32) -> Result<Object> { /* ... */ }
```

---

## 3. Objects — `#[napi(object)]`

A plain JS object passed **by value** (cloned across the boundary; mutating it in
Rust does **not** reflect back to JS). All fields must be `pub`. `Option<T>` ⇒
optional/undefined‑able.

```rust
#[napi(object)]
pub struct Pkg {
  pub name: String,
  pub version: Option<String>,
  pub dependencies: Vec<String>,
}

#[napi]
pub fn describe(p: Pkg) -> String { format!("{}@{}", p.name, p.version.unwrap_or_default()) }
```

---

## 4. Classes — `#[napi] impl`

A Rust struct becomes a real JS class. A **private** field is opaque to JS.

```rust
#[napi(js_name = "QueryEngine")]
pub struct JsQueryEngine { engine: Engine }   // private field = opaque handle

#[napi]
impl JsQueryEngine {
  #[napi(constructor)]
  pub fn new() -> Self { Self { engine: Engine::new() } }

  #[napi(factory)]                       // static: QueryEngine.withCount(n)
  pub fn with_count(count: u32) -> Self { Self { engine: Engine::with(count) } }

  #[napi]                                // instance method → .query(q)
  pub fn query(&self, q: String) -> Result<String> { self.engine.query(q) }

  #[napi(getter)]
  pub fn status(&self) -> u32 { self.engine.status() }

  #[napi(setter)]
  pub fn count(&mut self, count: u32) { self.engine.set_count(count); }
}
```

Auto‑constructor shortcut (all `pub` fields, no logic) — put `#[napi(constructor)]`
on the struct itself:

```rust
#[napi(constructor)]
pub struct Animal { pub name: String, pub kind: u32 }
```

---

## 5. Async

### `async fn` (needs `async` or `tokio_rt`)

```rust
use tokio::fs;

#[napi]
pub async fn read_file_async(path: String) -> Result<Buffer> {
  Ok(fs::read(path).await?.into())     // → Promise<Buffer> in TS
}
```

- In an **async method**, `&self`/`&mut self` are auto‑converted to a `Reference`
  so the instance survives the await.
- `&mut self` in an async method must be marked `unsafe` — the object is co‑owned
  by the JS runtime while the future is pending.

### `AsyncTask` — blocking CPU work on the libuv threadpool (no Tokio)

```rust
pub struct AsyncFib { input: u32 }

#[napi]
impl Task for AsyncFib {
  type Output = u32;     // computed on the worker thread
  type JsValue = u32;    // produced on the JS thread
  fn compute(&mut self) -> Result<Self::Output> { Ok(fib(self.input)) }
  fn resolve(&mut self, _env: Env, output: u32) -> Result<Self::JsValue> { Ok(output) }
  // optional: fn reject(&mut self, env: Env, err: Error) -> Result<Self::JsValue>
  // optional: fn finally(&mut self, env: Env) -> Result<()>
}

#[napi]
pub fn async_fib(input: u32) -> AsyncTask<AsyncFib> { AsyncTask::new(AsyncFib { input }) }

#[napi]                                 // cancellable from JS via AbortController
pub fn async_fib2(input: u32, signal: AbortSignal) -> AsyncTask<AsyncFib> {
  AsyncTask::with_signal(AsyncFib { input }, signal)
}
```

Choose `AsyncTask` for CPU‑bound blocking work; choose `async fn` + `tokio_rt`
for IO‑bound futures.

---

## 6. Value & type mapping

| JS | Rust |
| --- | --- |
| `undefined` | `Undefined` or `()` |
| `null` / nullable | `Null`; `Option<T>` |
| `number` | `u32` `i32` `i64` `f64` |
| `boolean` | `bool` |
| `string` | `String` (also `Latin1String`, `Utf16String`) |
| `bigint` | `BigInt` (needs `napi6`) |
| `Buffer` | `Buffer` |
| TypedArray | `Uint8Array` `Uint32Array` `Float64Array` … — **by reference, zero‑copy; mutations reflect back to JS** |
| object (typed) | `#[napi(object)] struct` — by value, cloned |
| object (dynamic) | `Object` — `obj.get::<T>("k")?` / `obj.set("k", v)?` |
| array (typed) | `Vec<T>` (O(n) copy) |
| array (dynamic) | `Array` |
| Map‑like | `HashMap<String, T>` |
| `A \| B` union | `Either<A, B>` … up to `Either26` |
| function arg | `Function<Args, Ret>`; multi‑arg via `FnArgs<(A, B)>` |
| opaque native handle | `External<T>` (TS: `ExternalObject<T>`) |

```rust
#[napi]
pub fn id(x: Either<String, u32>) -> Either<String, u32> { x }

#[napi]
pub fn make_handle(len: u32) -> External<Vec<u8>> { External::new(vec![0u8; len as usize]) }

#[napi]
pub fn call_it(cb: Function<u32, u32>) -> Result<u32> { cb.call(1) }
```

Note the buffer/typed‑array asymmetry: **typed arrays pass by reference**
(zero‑copy, writes visible to JS), while **`#[napi(object)]` structs and `Vec<T>`
copy**. Pick the typed array when you need to mutate JS memory in place.

---

## 7. Errors

`napi::Result<T>` = `Result<T, napi::Error>`. Returning `Err` from any `#[napi]`
fn **throws** a JS `Error` (instanceof `Error`; `.message` = reason, `.code` =
`Status`). `?` works against any `E: Into<napi::Error>`.

```rust
#[napi]
pub fn divide(a: f64, b: f64) -> Result<f64> {
  if b == 0.0 {
    return Err(Error::new(Status::InvalidArg, "division by zero"));
  }
  Ok(a / b)
}

// shorthand → Status::GenericFailure
return Err(Error::from_reason("something went wrong"));

// from a std error via `?`
let n: u32 = s.parse().map_err(|e| Error::from_reason(format!("{e}")))?;
```

`Status` variants: `Ok`, `InvalidArg`, `GenericFailure`, `StringExpected`,
`QueueFull`, `Cancelled`, … .

---

## 8. ThreadsafeFunction (call JS from another thread)

A JS callback can't be touched off‑thread; a `ThreadsafeFunction` (TSFN) is the
safe channel. Full generics:
`ThreadsafeFunction<T, Return, CallArgs, ErrorStatus, CalleeHandled, Weak, MaxQueueSize>`
— usually only `T` matters.

```rust
use std::{sync::Arc, thread};
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};

#[napi]
pub fn stream(callback: ThreadsafeFunction<u32>) -> Result<()> {
  let tsfn = Arc::new(callback);
  for n in 0..100 {
    let tsfn = tsfn.clone();
    thread::spawn(move || {
      // CalleeHandled (default): pass a Result; Err becomes the (err, _) JS arg.
      tsfn.call(Ok(n), ThreadsafeFunctionCallMode::Blocking);
    });
  }
  Ok(())
}
// Generated TS: (callback: (err: null | Error, result: number) => void) => void
```

- **Call mode:** `Blocking` (wait if the queue is full) vs `NonBlocking` (returns
  `Status::QueueFull`).
- **`CalleeHandled` generic:**
  - `true` (default) — Node‑style `(err, value)`; you pass `Ok(v)` / `Err(e)`.
  - `false` — callback receives the value directly; you call `tsfn.call(v, mode)`.
    ⚠️ a **synchronously thrown** error inside that JS callback **crashes the
    process** under this mode (also true under Bun).
- **`Weak = true`** — don't keep the event loop alive. **`MaxQueueSize`** bounds
  the queue.

(The v2/compat API is `env.create_threadsafe_function(...)` with an
`ErrorStrategy::{CalleeHandled, Fatal}` type param — that's compat mode.)
