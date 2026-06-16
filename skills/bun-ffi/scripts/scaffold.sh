#!/usr/bin/env bash
# Scaffold a Rust cdylib + Bun (bun:ffi) wrapper, ready to `cargo build && bun test`.
# Usage: scaffold.sh <crate-name> [target-dir]
# Idempotent-ish: refuses to overwrite an existing non-empty target dir.
set -euo pipefail

NAME="${1:?usage: scaffold.sh <crate-name> [dir]}"
DIR="${2:-$NAME}"
# Rust crate names use underscores in the lib filename.
LIB="lib$(printf '%s' "$NAME" | tr '-' '_')"

if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null || true)" ]; then
  echo "error: '$DIR' exists and is not empty; refusing to overwrite" >&2
  exit 1
fi

mkdir -p "$DIR/src"

cat > "$DIR/Cargo.toml" <<EOF
[package]
name = "$NAME"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[profile.release]
opt-level = 3
lto = true
EOF

cat > "$DIR/src/lib.rs" <<'EOF'
//! C-ABI surface exposed to Bun via bun:ffi.
//! Keep every exported fn `extern "C"` with only C-ABI types (scalars,
//! pointers, lengths). See the bun-ffi skill references for the rules.

use std::ffi::{c_char, CStr, CString};

#[unsafe(no_mangle)]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// Returns an owned, NUL-terminated string. JS must call `free_string` on the
/// returned pointer exactly once.
#[unsafe(no_mangle)]
pub extern "C" fn greet(name: *const c_char) -> *mut c_char {
    let name = if name.is_null() {
        "world".to_owned()
    } else {
        // SAFETY: caller guarantees a NUL-terminated string for the call.
        unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned()
    };
    CString::new(format!("hello, {name}")).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn free_string(p: *mut c_char) {
    if p.is_null() {
        return;
    }
    // SAFETY: p came from CString::into_raw above.
    drop(unsafe { CString::from_raw(p) });
}
EOF

cat > "$DIR/index.ts" <<EOF
import { dlopen, FFIType as T, suffix, CString } from "bun:ffi";

const lib = dlopen(\`\${import.meta.dir}/target/release/$LIB.\${suffix}\`, {
  add: { args: [T.i32, T.i32], returns: T.i32 },
  greet: { args: [T.cstring], returns: T.ptr },
  free_string: { args: [T.ptr], returns: T.void },
});

export const add = (a: number, b: number): number => lib.symbols.add(a, b);

export function greet(name: string): string {
  const p = lib.symbols.greet(Buffer.from(name + "\\0", "utf8"));
  try {
    return new CString(p).toString();
  } finally {
    lib.symbols.free_string(p);
  }
}

export const close = lib.close;
EOF

cat > "$DIR/index.test.ts" <<'EOF'
import { test, expect } from "bun:test";
import { add, greet } from "./index";

test("add", () => {
  expect(add(2, 3)).toBe(5);
  expect(add(-1, 1)).toBe(0);
});

test("greet (ascii, unicode, empty)", () => {
  expect(greet("world")).toBe("hello, world");
  expect(greet("café 🦊")).toBe("hello, café 🦊");
  expect(greet("")).toBe("hello, ");
});
EOF

cat > "$DIR/build.ts" <<'EOF'
// Build the crate, then you can `bun test`. Run: `bun build.ts`
import { $ } from "bun";
await $`cargo build --release`;
console.log("built; run `bun test`");
EOF

cat > "$DIR/package.json" <<EOF
{
  "name": "$NAME",
  "version": "0.1.0",
  "type": "module",
  "module": "index.ts",
  "scripts": {
    "build": "cargo build --release",
    "test": "cargo build --release && bun test"
  }
}
EOF

echo "scaffolded '$DIR'. Next:"
echo "  cd $DIR && cargo build --release && bun test"
