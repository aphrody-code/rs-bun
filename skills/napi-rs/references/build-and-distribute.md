# napi-rs — build, dev loop, and multi-platform distribution

Uses `@napi-rs/cli` (3.x). Install it as a dev dependency (run via Bun) or global:

```sh
bun add -d @napi-rs/cli         # then: bunx napi <cmd>
# or: npm i -g @napi-rs/cli
```

## CLI commands

| Command | Purpose |
| --- | --- |
| `napi new` | Scaffolder — prompts for name, target platforms, CI; generates a full project + GitHub Actions. |
| `napi build --platform` | Debug build; `--platform` appends the target triple to the `.node` filename. |
| `napi build --platform --release` | Optimized build. |
| `napi artifacts` | Move CI‑built binaries into the per‑platform package dirs. |
| `napi create-npm-dirs` | Generate the per‑platform npm package directories. |
| `napi prepublish -t npm` | Prepare/publish the per‑platform packages. |
| `napi version` | Sync versions across the platform packages. |
| `napi rename` | Rename a scaffolded package. |

## What `napi build` emits

- `<name>.<target-triple>.node` — the native addon (e.g. `awesome.linux-x64-gnu.node`).
- `index.js` — a generated **loader** that `require`s the right `.node` for the
  current `process.platform`/`arch`/libc, falling back to the per‑platform npm
  packages.
- `index.d.ts` — TypeScript declarations generated from your `#[napi]` signatures.

```ts
import { plus100 } from "./index.js";   // typed via the generated .d.ts
console.log(plus100(1)); // 101
```

Dev loop: `napi build --platform` (debug) on change is fast; keep `--release` for
benchmarks and publishing.

## The `napi` block in package.json

This drives the build and the prebuild target list:

```json
{
  "name": "my-addon",
  "version": "0.1.0",
  "napi": {
    "binaryName": "my-addon",
    "targets": [
      "x86_64-unknown-linux-gnu",
      "aarch64-unknown-linux-gnu",
      "x86_64-apple-darwin",
      "aarch64-apple-darwin",
      "x86_64-pc-windows-msvc",
      "wasm32-wasip1-threads"
    ]
  },
  "scripts": {
    "build": "napi build --platform --release",
    "build:debug": "napi build --platform",
    "prepublishOnly": "napi prepublish -t npm"
  }
}
```

napi‑rs supports a broad target set: Windows x64/x86/arm64, macOS x64/aarch64,
Linux x64/aarch64/arm (gnu + musl), powerpc64le, s390x, riscv64, loong64, Android
arm64/armv7, FreeBSD x64. The **`wasm32-wasip1-threads`** target (via emnapi)
builds a portable WASM addon — one artifact with no per‑platform native binary,
useful when you want to avoid native cross‑compilation entirely.

## Cross‑platform npm distribution (per‑platform packages)

The standard model: one **main** package whose `optionalDependencies` are the
per‑platform packages, each tagged with `os`/`cpu` so the package manager installs
only the matching one. The generated `index.js` resolves the local `.node` first,
then the platform package.

```jsonc
// main package
{
  "name": "@me/addon",
  "version": "0.5.0",
  "main": "index.js",
  "types": "index.d.ts",
  "optionalDependencies": {
    "@me/addon-linux-x64-gnu":  "0.5.0",
    "@me/addon-darwin-arm64":   "0.5.0",
    "@me/addon-win32-x64-msvc": "0.5.0"
  }
}
// one platform package (built in CI, published by `napi prepublish`)
{ "name": "@me/addon-linux-x64-gnu", "version": "0.5.0", "os": ["linux"], "cpu": ["x64"], "libc": ["glibc"] }
```

`napi new` generates a GitHub Actions matrix that builds each target, runs
`napi artifacts` + `napi prepublish`. Keep all platform package versions **locked
to the main version** and publish them together — a consumer resolving the main
package at `X` must get the platform package at `X` or the loader loads a stale ABI.

## Loading and running under Bun

- Bun implements Node‑API, so a napi‑rs `.node` built for Node generally loads in
  **Bun unmodified** — `import`/`require` the generated `index.js`, no flag, no
  recompile. The in‑repo test `test/js/third_party/@napi-rs/canvas/napi-rs-canvas.test.ts`
  exercises exactly this (`createCanvas`, `loadImage`, `ctx.drawImage`,
  `canvas.encode("png")`) against a real napi‑rs addon.
- **The event‑loop gotcha (most important Bun caveat):** on Linux/macOS Bun is
  **not** backed by libuv, so `uv_default_loop()` is not Bun's real loop. Native
  code must obtain the loop via **`napi_get_uv_event_loop`**, never assume the
  default. napi‑rs's own `AsyncTask`/TSFN paths go through Node‑API and work; the
  risk is raw libuv usage in a dependency that bypasses `napi_get_uv_event_loop`.
- **Bun canary:** the N‑API surface is large and CI‑guarded but not bit‑for‑bit
  identical to Node — an exotic or brand‑new `napi_*` symbol can have a gap. Stay
  on the common API surface and verify on your actual Bun build. The common path
  (what `@napi-rs/canvas` uses) is solid.
- ThreadsafeFunction works under Bun via the Node‑API TSFN implementation; the
  "don't throw synchronously in a `CalleeHandled=false` callback" rule still
  applies (it can crash the process).

## Quick test under Bun

```ts
import { test, expect } from "bun:test";
import { plus100, divide } from "./index.js";

test("napi addon loads and runs under Bun", () => {
  expect(plus100(1)).toBe(101);
  expect(() => divide(1, 0)).toThrow(/division by zero/); // Rust Err → thrown JS Error
});
```
