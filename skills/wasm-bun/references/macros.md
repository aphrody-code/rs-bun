# wasm-bindgen — the `#[wasm_bindgen]` surface

Current API (wasm-bindgen 0.2.x). All examples assume:

```rust
use wasm_bindgen::prelude::*;
```

The function/class/error examples below were **verified loading and running under
Bun 1.3.14** (nodejs target). Async and web-sys are marked where unverified.

## Functions

`&str`/`String`/`Vec<T>`/`Option<T>`/numbers/`bool` cross automatically.
Snake_case → camelCase is automatic.

```rust
#[wasm_bindgen]
pub fn greet(name: &str) -> String { format!("Hello, {name}!") }

#[wasm_bindgen]
pub fn sum(xs: Vec<i32>) -> i32 { xs.iter().sum() }

#[wasm_bindgen]
pub fn maybe(flag: bool) -> Option<String> { flag.then(|| "yes".into()) }

#[wasm_bindgen(js_name = sumBig)]   // explicit name override
pub fn sum_big(a: u32, b: u32) -> u32 { a + b }
```

## Structs as JS classes

```rust
#[wasm_bindgen]
pub struct Counter { value: i32 }     // private field = opaque to JS

#[wasm_bindgen]
impl Counter {
    #[wasm_bindgen(constructor)]
    pub fn new(start: i32) -> Counter { Counter { value: start } }

    pub fn increment(&mut self) -> i32 { self.value += 1; self.value }

    #[wasm_bindgen(getter)]
    pub fn value(&self) -> i32 { self.value }

    #[wasm_bindgen(setter)]
    pub fn set_value(&mut self, v: i32) { self.value = v; }
}
```

An instance returned to JS owns a Rust pointer. wasm-bindgen registers a
`FinalizationRegistry` to free it on GC **and** exposes an explicit `.free()` for
deterministic release — call `.free()` when you want to release promptly rather
than wait for GC.

## Errors → JS throw

Return `Result<T, E>` where `E: Into<JsValue>`. `JsError` is the ergonomic choice.
A returned `Err` becomes a thrown JS `Error`.

```rust
#[wasm_bindgen]
pub fn checked_div(a: i32, b: i32) -> Result<i32, JsError> {
    if b == 0 { return Err(JsError::new("division by zero")); }
    Ok(a / b)
}
// Verified under Bun: checked_div(1, 0) throws Error: division by zero
```

## Import JS into Rust (`extern "C"`)

```rust
#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console)]
    fn log(s: &str);

    // `catch` turns a JS throw into Result<_, JsValue>
    #[wasm_bindgen(js_name = fetchThing, catch)]
    async fn fetch_thing(url: &str) -> Result<JsValue, JsValue>;

    // import a JS class + a method on it
    type ExternalThing;
    #[wasm_bindgen(method)]
    fn do_it(this: &ExternalThing) -> u32;
}
```

This is how you reach **Bun globals** from WASM (since web-sys's DOM bindings
don't apply): declare the JS API you need with `extern "C"` and call it.

## Closures passed to JS

```rust
use wasm_bindgen::closure::Closure;

#[wasm_bindgen]
pub fn make_cb() -> JsValue {
    // FnMut closure; into_js_value() hands ownership to JS (or .forget() to leak it).
    Closure::<dyn FnMut(i32) -> i32>::new(|x| x * 2).into_js_value()
}
```

Mind the lifetime: a `Closure` dropped on the Rust side invalidates the JS
function. `into_js_value()`/`forget()` transfer ownership so JS can keep calling it.

## Async — `wasm-bindgen-futures`

Add `wasm-bindgen-futures = "0.4"`. An exported `async fn` returns a JS `Promise`.

```rust
use wasm_bindgen_futures::JsFuture;

#[wasm_bindgen]
pub async fn load(url: String) -> Result<JsValue, JsValue> {
    let resp = JsFuture::from(fetch_thing(&url)).await?;  // await a js_sys::Promise
    Ok(resp)
}
```

- `JsFuture::from(promise).await` awaits a JS `Promise` in Rust;
  `wasm_bindgen_futures::future_to_promise(fut)` does the reverse.
- ⚠️ **Not independently verified under Bun this session.** The mechanism relies
  only on standard `Promise` + microtask scheduling (which Bun supports), so it's
  *expected* to work — run your async path before relying on it.

## js-sys vs web-sys (the Bun distinction)

- **js-sys** (`js-sys = "0.3"`) — bindings to ECMAScript builtins present in any JS
  engine: `Array`, `Object`, `Map`, `Set`, `Promise`, `JSON`, `Date`, `Math`,
  `Reflect`, `BigInt`, typed arrays. **Useful under Bun.**
- **web-sys** (`web-sys = "0.3"`) — bindings to **browser** Web/DOM APIs
  (`window`, `document`, `Element`, `WebSocket`, canvas, …), generated from browser
  WebIDL. **Mostly NOT useful under Bun** — Bun is not a browser, so `window`/
  `document`/DOM code fails at runtime. A few features backed by globals Bun
  implements (`fetch`, `WebSocket`, `console`, `performance`, `TextEncoder`) *may*
  work but are **unverified** — don't assume any web-sys API works under Bun
  without testing. Prefer `extern "C"` imports of Bun globals or js-sys.
