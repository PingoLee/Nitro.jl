## `get_cookie(req, …)` / `set_cookie!(res, …)` — use the cookie configuration of the `App` serving the request

- **Version**: Unreleased
- **Nitro ref**: [#308](https://github.com/PingoLee/Nitro.jl/issues/308) ; `src/methods.jl`, `src/core/pipeline.jl`
- **Recorded**: 2026-09-24
- **Severity**: behavior change — an app that configures cookies on the **global** app but serves
  an explicit `App` must move that configuration onto the `App`, or its cookies stop being
  encrypted.

### What changed

The argument-less `get_cookie(req, name, …)` and `set_cookie!(res, name, value; …)` read the
process-wide global app's cookie configuration, whichever app was serving the request. With an
explicit `App` — the recommended handle — they could not see its `secret_key`, so they wrote
plaintext and returned whatever the client sent (`Cookie: role=admin` read as `"admin"`).

They now use the configuration of the `App` **serving the current request**, carried by a
task-scoped binding that also reaches tasks the handler spawns. Outside any request they still use
the global app, as before. The `(app, …)` forms are unchanged.

Two setups notice:

| Setup | Before | After |
|---|---|---|
| `configcookies(app; secret_key = K)`, `serve(app)` | cookies written in **plaintext**, reads unverified | encrypted under `K` — the fix |
| `configcookies(secret_key = K)` on the **global** app, `serve(app)` | encrypted under `K`, by accident | **plaintext**: `app` has no key. `serve(app)` logs a warning once |

Cookies written in plaintext before the upgrade read as absent afterwards, because `app`'s key now
applies to them — the same one round of absent cookies as the
[token-format change](2026-09-24-309-encrypted-cookie-format.md) in this release.

### How to find the calls to migrate

```bash
# Global cookie configuration...
grep -rnE 'configcookies\((secret_key|[a-z_]+\s*=)' --include=*.jl .
# ...in an app that serves an explicit App.
grep -rnE 'serve\([a-z_]+[;,)]|App\(' --include=*.jl .
```

At runtime, `serve(app)` warns: `a cookie secret_key is configured on the GLOBAL app … but the App
being served has none, so its cookies are NOT encrypted`.

### Migrate your app

```julia
# ✗ before — configured on the global app, served through an explicit one
configcookies(secret_key = SecretString(ENV["COOKIE_SECRET"]))
app = App(mod = @__MODULE__)
serve(app)

# ✓ after — configure the app you serve
app = App(mod = @__MODULE__)
configcookies(app; secret_key = SecretString(ENV["COOKIE_SECRET"]))
serve(app)
```
