## `mountdir` is validated as a URL path prefix, so some mounts now throw at startup (#101)

- **Version**: 0.3.0
- **Nitro ref**: #101; `src/utilities/fileutil.jl`, `src/methods.jl`
- **Recorded**: 2026-09-07
- **Severity**: **breaking (throws at mount time)** — affects apps whose `mountdir` was a wildcard,
  a brace name, a dot-segment, or contained a character that has to be percent-encoded.

### What changed

`mountable_files` has always refused a **filename** the router would read as a pattern, because a
file must not be able to claim URLs other than its own. Nothing applied that rule to `mountdir`, so a
mount could do exactly what a file was forbidden from doing: `staticfiles(dir, "*")` registered
`/*/<file>` **and** a bare `/*`, so `GET /anything` was answered by the mount's `index.html`. The
blast radius was one path segment, not the whole router — but no one spelling `staticfiles(dir, "*")`
can have meant it. `staticfiles(dir, "**")` and `staticfiles(dir, "{id}")` already failed loudly at
registration; `*` was the one that came up clean.

`mount_segments` now refuses a segment on three grounds, checked in this order:

1. **A router pattern** — `*`, `**`, or a segment containing `{` or `}`. Checked first because `*` is
   a legal URL path character, so the encoding rule below would otherwise let it through.
2. **A relative dot-segment** — `.` or `..`. `.` is `unreserved`, so the encoding rule passes it too,
   and clients remove dot-segments before sending: nothing that would match `/../x` ever arrives.
3. **Not a legal URL path segment** — anything outside RFC 3986 `pchar`
   (`unreserved / pct-encoded / sub-delims / ":" / "@"`).

Rule 3 closes the silent half. The router compares path segments byte for byte and never
percent-decodes, so `staticfiles(dir, "my static")` used to register routes that came up clean,
reported themselves, and then matched nothing at all. The encoded spelling is accepted, so
`"my%20static"` and `"caf%C3%A9"` mount and serve — and those are what a conforming client sends.

**This is not purely a dead-mount cleanup, and one case needs a real decision from you.** The refused
set splits in two:

- `" "`, `"?"` and control characters are **strictly** unmatchable — the request line cannot carry
  them. A mount spelled that way never served anything, so there is nothing to lose.
- Everything else — `"café"`, `"a#b"`, `"a|b"`, `"a[b]"`, `"a^b"`, `"100%"` — **was reachable**, by a client
  that sends raw bytes rather than percent-encoding them. `curl` does this by default. If you have a
  mount with such a prefix *and* a non-browser client hitting it, that mount stops working, and
  switching to the encoded spelling will **not** transparently fix it: `caf%C3%A9` and raw `café` are
  different byte strings and the router matches bytes, so the encoded route does not answer the raw
  client. You would have to change the client to percent-encode as well.

The trade is deliberate: `mountdir` is judged by the same rule as a filename, and a prefix no browser
can reach is a footgun whatever curl can do with it. But if you are deliberately serving a raw-byte
path to a controlled client, this is a breaking change you must handle on both ends.

Percent triplets are validated and passed through byte for byte; `"%2f"` is not rewritten to `"%2F"`.

Because `mountdir` is canonicalized before the folder is enumerated, a call that is wrong in both
respects — `staticfiles("does_not_exist", "*")` — now reports the `mountdir`, where it used to report
the missing folder. Both are `ArgumentError`.

### How to find the calls to migrate

```bash
# Every mount. The second argument is the one to check; a bare call uses the default "static".
rg -n '(static|spa|dynamic)files\(' <app>/src

# Rules 1 and 2 — a wildcard, a brace, a dot-segment, or whitespace in the prefix
rg -n '(static|spa|dynamic)files\([^)]*,\s*"[^"]*([*{}]|\s|\.\.)' <app>/src

# Rule 3 — a prefix character outside RFC 3986 pchar. This is the class above that WAS
# reachable ("café", "a|b", "a#b", "a[b]", "a^b"), so it is the one to check first.
rg -n "(static|spa|dynamic)files\([^)]*,\s*\"[^\"]*[^-A-Za-z0-9/._~!\$&'()*+,;=:@%\"]" <app>/src

# Rule 3, the percent case — a `%` that is not the head of a well-formed %XX triplet
rg -nP '(static|spa|dynamic)files\([^)]*,\s*"[^"]*%(?![0-9A-Fa-f]{2})' <app>/src
```

The first pattern alone will **not** find the reachable-but-refused class — `"café"` and `"100%"`
contain no wildcard, brace, dot-segment or space — which is why the second and third are here. The
catch-all `rg` at the top finds every mount regardless; check each one's second argument by hand if
you would rather not trust a character class.

There is no silent case to hunt for on the *Nitro* side — an affected mount throws `ArgumentError` at
startup, and the message names the segment and why it was refused. The silent case is on the
**client** side: if a refused prefix was one of the reachable ones above, a non-browser caller that
was hitting it starts getting 404s, so grep your clients too.

### Migrate your app

```julia
# ✗ before — registered `/*/app.js` and a bare `/*`, so GET /anything hit the mount
staticfiles("dist", "*")
# ✓ after — name the prefix you actually meant
staticfiles("dist", "assets")

# ✗ before — registered, reported its routes, and matched nothing: a space cannot appear
#   in a request line at all, so this mount was dead however the client behaved
staticfiles("dist", "my static")
# ✓ after — the encoded spelling is the one a conforming client sends, and it serves
staticfiles("dist", "my%20static")
# ✓ or avoid the question
staticfiles("dist", "my-static")

# ✗ before — this one DID serve, but only to a client sending raw UTF-8 (curl's default);
#   no browser could ever reach it
staticfiles("dist", "café")
# ✓ after — serves every conforming client...
staticfiles("dist", "caf%C3%A9")
#   ...but NOT the raw-byte client that used to work: "café" and "caf%C3%A9" are different
#   byte strings and the router matches bytes. Fix such a client to percent-encode too.

# ✗ before — a dot-segment the client strips before the request is sent
staticfiles("dist", "../public")
# ✓ after — mount the folder you mean, at the prefix you mean
staticfiles("../public", "public")
```

Filenames are unaffected by this change: `mountable_files` still *skips* an unservable file rather
than throwing, because filenames arrive in bulk from the filesystem and refusing one would silently
drop a file from a mount that serves it today.
