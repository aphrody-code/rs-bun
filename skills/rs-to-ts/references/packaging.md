# Distribution strategies

A `bun:ffi` package ships a **platform‑specific** native library
(`.so`/`.dylib`/`.dll`). Unlike pure JS, you can't publish one artifact for
everyone. Pick by audience.

Always resolve the library at runtime via `suffix` + an `os-arch` lookup; never
hardcode `lib*.so`.

---

## A. Prebuilt per‑platform packages (recommended for libraries)

The model napi‑rs popularized: build the cdylib in CI for each platform, publish a
**small package per platform**, and have the main package depend on all of them as
`optionalDependencies`, loading whichever one actually installed.

**Layout**

```
my-pkg/                      # the package users install
├── package.json            # optionalDependencies: the platform packages
├── index.ts                # resolves + loads the right native lib
├── bindings.generated.ts
npm/                         # one sub-package per platform (published separately)
├── linux-x64/   { package.json (os/cpu fields), libmy_pkg.so }
├── darwin-arm64/{ package.json,                  libmy_pkg.dylib }
└── win32-x64/   { package.json,                  my_pkg.dll }
```

**Platform package `package.json`** (so npm/Bun only installs the matching one):

```json
{
  "name": "my-pkg-linux-x64",
  "version": "0.1.0",
  "os": ["linux"],
  "cpu": ["x64"],
  "files": ["libmy_pkg.so"]
}
```

**Main package** declares them optional and resolves at runtime:

```json
{
  "name": "my-pkg",
  "optionalDependencies": {
    "my-pkg-linux-x64": "0.1.0",
    "my-pkg-darwin-arm64": "0.1.0",
    "my-pkg-win32-x64": "0.1.0"
  }
}
```

```ts
// resolve the native lib from the installed platform package
import { dlopen } from "bun:ffi";

const triple = `${process.platform}-${process.arch}`;      // e.g. "linux-x64"
const file = { linux: "libmy_pkg.so", darwin: "libmy_pkg.dylib", win32: "my_pkg.dll" }[process.platform]!;
const libPath = require.resolve(`my-pkg-${triple}/${file}`);
const lib = dlopen(libPath, { /* … or import the generated bindings … */ });
```

Pros: consumers `bun add my-pkg` with **no Rust toolchain**, fast installs, only
the needed binary downloads. Cons: CI matrix + publishing several packages (see
`automation.md`). Best default for anything public.

---

## B. Build from source on install

A `postinstall` script compiles the crate on the consumer's machine.

```json
{
  "name": "my-pkg",
  "scripts": { "postinstall": "cargo build --release" }
}
```

Pros: one package, no CI matrix, always matches the host exactly. Cons: **every
consumer needs Rust installed**, slow installs, fails in toolchain‑less CI/Docker.
Acceptable for internal tools and prototypes; poor for public libraries.

Mitigation: try prebuilt first, fall back to source — but that's most of the work
of (A) anyway, so prefer (A) for public packages.

---

## C. Embed the library into one executable (`bun build --compile`)

For shipping a **CLI/app** (not a consumable library), bundle the native library
*into* a single Bun executable. Mark the library as an embedded file and Bun will
extract it to a temp file at runtime so `dlopen` can load it (this is exactly how
Bun's own FFI loader handles compiled‑in libraries).

```ts
// app.ts
import { dlopen, FFIType } from "bun:ffi";
// `with { type: "file" }` makes bun build --compile embed the binary; the import
// yields a path Bun resolves at runtime (extracted from the bundle).
import libPath from "./target/release/libmy_pkg.so" with { type: "file" };

const { symbols } = dlopen(libPath, {
  add: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
});
console.log(symbols.add(2, 3));
```

```bash
cargo build --release
bun build --compile ./app.ts --outfile myapp     # single self-contained binary
./myapp
```

Pros: one file to distribute, zero install, no Rust on the target. Cons: the
embedded library is one platform per build (build once per OS/arch you ship), and
it's an *app* distribution model, not an importable package. Ideal for tools.

---

## Choosing

- Public/importable library, broad audience → **A (prebuilt per‑platform)**.
- Internal tool, you control the machines, Rust is present → **B (build from
  source)**, it's the least ceremony.
- A CLI/app you hand someone as a single binary → **C (`--compile` embed)**.

## Versioning note

Keep the platform packages' versions **locked to the main package version** and
publish them together — a consumer resolving `my-pkg@0.2.0` must get the matching
`my-pkg-linux-x64@0.2.0`, or `require.resolve` loads a stale ABI. Any change to the
`extern "C"` surface is a breaking change for the bindings; bump accordingly.
