# Rust as a subprocess / daemon (Bun.spawn + IPC)

When in‑process FFI/N‑API is more coupling than you want — coarse work, crash
isolation, reuse of an existing Rust CLI, or a streaming boundary — run the Rust
code as a separate process and talk over stdio or a socket.

## One‑shot: spawn a Rust binary, read its output

```ts
const proc = Bun.spawn(["./target/release/mytool", "--json", "input"], {
  stdin: "pipe",
  stdout: "pipe",
  stderr: "pipe",
});

// Drain ALL pipes concurrently — an unread pipe fills the OS buffer and deadlocks.
const [stdout, stderr, exitCode] = await Promise.all([
  new Response(proc.stdout).text(),
  new Response(proc.stderr).text(),
  proc.exited,
]);
if (exitCode !== 0) throw new Error(`mytool failed: ${stderr}`);
const result = JSON.parse(stdout);
```

Rust side: parse args, do the work, `println!("{}", serde_json::to_string(&out)?)`,
exit nonzero on error with a message to stderr.

## Long‑lived daemon: framed request/response over stdio

For many calls, keep one Rust process alive and exchange length‑ or newline‑framed
JSON. Newline‑delimited JSON (NDJSON) is the simplest robust framing.

```ts
const proc = Bun.spawn(["./target/release/mydaemon"], { stdin: "pipe", stdout: "pipe" });
const writer = proc.stdin;

// Send a request line.
writer.write(JSON.stringify({ id: 1, op: "hash", data: "abc" }) + "\n");
writer.flush();

// Read responses line by line. Buffer partial chunks until a '\n'.
let buf = "";
for await (const chunk of proc.stdout) {
  buf += new TextDecoder().decode(chunk);
  let nl: number;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    const msg = JSON.parse(line); // dispatch by msg.id
    // ...resolve the pending promise for msg.id...
  }
}
```

```rust
// Rust daemon: read lines from stdin, write one response line per request.
use std::io::{BufRead, Write};

fn main() -> std::io::Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.is_empty() { continue; }
        // parse `line` as JSON, compute, serialize a response with the same `id`
        let resp = format!(r#"{{"id":1,"result":"..."}}"#);
        writeln!(stdout, "{resp}")?;
        stdout.flush()?;            // flush so Bun sees it immediately
    }
    Ok(())
}
```

## Things that bite

- **Always drain stdout *and* stderr** (concurrently). A full stderr pipe
  deadlocks the child even if you only care about stdout.
- **Flush on both sides.** Rust stdout is block‑buffered when not a TTY — flush
  after each response or the reader hangs. Bun's `stdin.flush()` likewise.
- **Frame explicitly.** Don't assume one `read` == one message; TCP/pipes split
  and coalesce. Buffer until a delimiter (NDJSON) or read a length prefix.
- **Backpressure & shutdown.** Decide who closes: `proc.kill()` / close stdin to
  signal EOF; await `proc.exited`. Handle the child dying mid‑request (reject
  pending promises on `exited`).
- **Serialization cost** dominates per‑call latency — batch where possible. If
  you're making thousands of tiny calls, this is the wrong boundary; use FFI/N‑API.

## When to pick this

Good when the Rust unit of work is large relative to the IPC overhead (a
compile, a scan, a transcode), when you want the OS to contain Rust crashes, or
when a stable CLI/daemon contract is more valuable than raw speed. Bad for
fine‑grained, latency‑sensitive calls.
