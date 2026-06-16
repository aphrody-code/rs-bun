# Automating the build, bindings, and dev loop

The goal: one command to go from a Rust edit to a tested binding, and never
hand‑maintain a `dlopen` block.

## `build.ts` — compile + regenerate bindings

Run the cargo build, then regenerate the typed wrapper from the manifest so the
JS `args` can't drift from the Rust signatures.

```ts
// build.ts — `bun build.ts`
import { $ } from "bun";
import manifest from "./ffi.manifest";
import { generate } from "./scripts/gen-bindings";

const profile = manifest.profile ?? "release";
await $`cargo build ${profile === "release" ? "--release" : ""}`;
await Bun.write("bindings.generated.ts", generate(manifest));
console.log(`built (${profile}) + regenerated bindings`);
```

> Importing `generate()` directly (instead of shelling out to the script) keeps it
> a single process and lets the build fail loudly if the manifest is invalid.

## `dev.ts` — watch loop for fast prototyping

Rebuild and re‑run whenever Rust or the manifest changes. Use the **debug**
profile while iterating — `cargo build` is much faster than `--release`.

```ts
// dev.ts — `bun dev.ts [entry.ts]`   (Ctrl-C to stop)
import { watch } from "node:fs";
import { $ } from "bun";

const entry = Bun.argv[2] ?? "index.test.ts";
let building = false;
let queued = false;

async function rebuild() {
  if (building) { queued = true; return; }
  building = true;
  try {
    await $`cargo build`;                       // debug profile
    await $`bun scripts/gen-bindings.ts ffi.manifest.ts`;
    await $`bun ${entry}`.nothrow();            // run tests/entry; keep watching on failure
  } catch (e) {
    console.error("build failed:", e);
  } finally {
    building = false;
    if (queued) { queued = false; rebuild(); }
  }
}

watch("src", { recursive: true }, rebuild);
watch(".", { recursive: false }, (_e, f) => f === "ffi.manifest.ts" && rebuild());
console.log("watching src/ and ffi.manifest.ts …");
await rebuild();
```

> While prototyping, set `profile: "debug"` in the manifest so the generated
> bindings point at `target/debug/...`. Flip to `"release"` for benchmarks/ship.

## `package.json` scripts

```json
{
  "name": "my-pkg",
  "version": "0.1.0",
  "type": "module",
  "module": "index.ts",
  "scripts": {
    "build": "bun build.ts",
    "dev": "bun dev.ts",
    "test": "bun build.ts && bun test",
    "prepublishOnly": "bun build.ts && bun test"
  }
}
```

## Cross‑platform CI matrix (prebuilt artifacts)

For per‑platform distribution (see `packaging.md`), build the cdylib on each
target in CI and upload the artifact. Minimal GitHub Actions shape:

```yaml
jobs:
  build:
    strategy:
      matrix:
        include:
          - { os: ubuntu-latest,  target: x86_64-unknown-linux-gnu,  pkg: linux-x64 }
          - { os: ubuntu-24-arm,  target: aarch64-unknown-linux-gnu, pkg: linux-arm64 }
          - { os: macos-latest,   target: aarch64-apple-darwin,      pkg: darwin-arm64 }
          - { os: macos-13,       target: x86_64-apple-darwin,       pkg: darwin-x64 }
          - { os: windows-latest, target: x86_64-pc-windows-msvc,    pkg: win32-x64 }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
      - run: rustup target add ${{ matrix.target }}
      - run: cargo build --release --target ${{ matrix.target }}
      # upload target/<target>/release/lib*.{so,dylib,dll} as artifact "<pkg>"
      - uses: actions/upload-artifact@v4
        with: { name: ${{ matrix.pkg }}, path: target/${{ matrix.target }}/release/*.{so,dylib,dll} }
```

A publish job then assembles one platform package per artifact (or attaches them
to a release for a download‑on‑install approach). Keep the **bindings** generated
once and shared; only the native library differs per platform.

## Why generate instead of hand‑write

The single most common `bun:ffi` bug is an `args`/`returns` declaration that no
longer matches the Rust signature after a refactor — a silent crash, not a type
error. Generating the binding from the manifest, and keeping the manifest next to
the Rust source, makes that drift impossible to ship: change the signature, change
the manifest, the binding regenerates, the test catches a mismatch.
