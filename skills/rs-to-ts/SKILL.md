---
name: rs-to-ts
description: >-
  Turn a Rust crate into a usable, distributable Bun package via bun:ffi —
  project layout, automated build (cargo → cdylib → typed TS bindings),
  a fast prototyping loop, and multi-platform distribution (prebuilt
  per-platform deps, build-from-source, or embedding the library with
  `bun build --compile`). Use this skill whenever the user wants to "package a
  Rust crate for Bun", "ship Rust as an npm/Bun package", "wrap my Rust library
  so JS can import it", set up the build/automation/CI for a Rust+Bun project,
  generate TypeScript bindings from a symbol manifest, prototype a Rust↔Bun
  binding quickly, or distribute a native Bun package across platforms — even if
  they only say "make my Rust crate installable from Bun".
metadata:
  version: "1.0.0"
  keywords: [rust, bun, ffi, cdylib, package, npm, distribution, bun build --compile, prototyping, codegen, bindings]
---

# rs-to-ts — ship a Rust crate as a Bun package

Take a Rust crate to a Bun package someone can `bun add` and `import`, using
`bun:ffi`. Three concerns, in order of how you'll hit them: **prototype fast →
automate the build → distribute across platforms.**

Prerequisite knowledge: the FFI *mechanics* (types, memory, callbacks) live in
the **`bun-ffi`** skill — read it for anything about how the boundary works. This
skill is the **workflow** around it. For choosing FFI vs N‑API in the first place,
see **`rust-bun`**.

## Project layout

A single repo that is both a Cargo crate and a Bun package:

```
my-pkg/
├── Cargo.toml            # [lib] crate-type = ["cdylib"]
├── src/lib.rs            # extern "C" surface
├── ffi.manifest.ts       # declarative symbol list (single source of truth)
├── bindings.generated.ts # produced by gen-bindings.ts — do not edit by hand
├── index.ts              # ergonomic public API (re-exports the wrapper)
├── build.ts              # cargo build + regenerate bindings
├── dev.ts                # watch loop: rebuild on change, re-run
├── index.test.ts
└── package.json          # "module": "index.ts", build/test/prepublish scripts
```

The key idea: **declare your symbols once** in `ffi.manifest.ts` and *generate*
the `dlopen` block + typed wrapper, instead of hand‑writing (and drifting) the
binding boilerplate in every project. The `scripts/gen-bindings.ts` in this skill
does exactly that.

## 1. Prototype fast

Get a working round trip before worrying about packaging:

1. `scripts/scaffold` from the **`bun-ffi`** skill, or start from the layout above.
2. Keep the edit loop tight: `bun dev.ts` watches `src/**` and `ffi.manifest.ts`,
   runs `cargo build` (debug — faster) and re‑runs your entry/tests on change. See
   `references/automation.md` for the watcher.
3. Use the **debug** profile while iterating (`cargo build`, path
   `target/debug/...`); switch to `--release` only for benchmarking and shipping.
   Resolve the library path with `suffix` so it's portable from day one.

## 2. Automate the build + bindings

Hand‑written `dlopen` blocks rot — a symbol's `args` and the Rust signature drift
apart silently and you get a crash. Generate them from the manifest:

```ts
// ffi.manifest.ts  — the single source of truth
import type { Manifest } from "./scripts/gen-bindings";
export default {
  lib: "my_pkg",                       // → lib<my_pkg>.<suffix>
  profile: "release",                  // or "debug" while prototyping
  symbols: {
    add:   { args: ["i32", "i32"], returns: "i32" },
    // string:true wraps the returned ptr in CString and frees via `free`
    greet: { args: ["cstring"], returns: "ptr", string: true, free: "free_string" },
  },
} satisfies Manifest;
```

`bun scripts/gen-bindings.ts ffi.manifest.ts` writes `bindings.generated.ts` with
the typed `dlopen` and a wrapper (pointer→`CString`+free handled for `string:true`
symbols). `build.ts` runs the cargo build then the generator so they never drift.
Details + the CI shape in `references/automation.md`.

## 3. Distribute across platforms

A `bun:ffi` package ships a **platform‑specific** `.so`/`.dylib`/`.dll`. Pick a
strategy by audience (`references/packaging.md` has the full recipes):

- **Prebuilt per‑platform packages (recommended for libraries).** Build the
  cdylib in CI for each `os‑arch`, publish one small package per platform
  (`my-pkg-linux-x64`, `my-pkg-darwin-arm64`, …), and have the main package list
  them as `optionalDependencies` + resolve the right one at runtime. This is the
  napi‑rs distribution model; consumers `bun add my-pkg` with no Rust toolchain.
- **Build from source on install.** A `postinstall` runs `cargo build --release`.
  Simplest to publish, but requires every consumer to have Rust — fine for
  internal tooling, poor for public packages.
- **Embed the library and ship one executable.** For a *CLI/app* (not a library),
  `import lib from "./lib.so" with { type: "file" }` and `bun build --compile`
  bundles the `.so` into a single binary; Bun extracts it to a temp file at
  runtime so `dlopen` can load it. Great for distributing a tool with zero install
  steps. (This is literally how Bun's FFI loader handles compiled‑in libraries.)

Always resolve the library path via `suffix` and a per‑platform lookup; never
hardcode `.so`.

## 4. Public API & types

`index.ts` re‑exports a clean, typed surface (`add(a, b)`, `greet(name)`) over the
generated wrapper, so consumers never see pointers or `FFIType`. Ship a `.d.ts`
(or keep `index.ts` as the typed entry under Bun). Validate the package with a
`bun:test` that imports it the way a consumer would.

## Reference files

- `references/automation.md` — `build.ts`, the `dev.ts` watch loop, the manifest →
  bindings generator, and a minimal cross‑platform CI matrix.
- `references/packaging.md` — the three distribution strategies in full
  (per‑platform prebuilds + `optionalDependencies`, build‑from‑source,
  `bun build --compile` embedding), `package.json` fields, and versioning.

## Scripts

- `scripts/gen-bindings.ts` — reads `ffi.manifest.ts`, writes a typed
  `bindings.generated.ts` (`dlopen` + wrapper, with auto `CString`/free for
  `string` symbols). Run standalone or from `build.ts`.
