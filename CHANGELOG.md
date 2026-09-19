# Changelog

## Unreleased

### Breaking

- **`EndPointBlank.configure/1` now raises `ArgumentError` for a `:cache_ttl`
  that is not a non-negative integer, instead of accepting it (sc-970).**
  This is one rule, the same in the Elixir, JS, Java, Python and Rails SDKs:
  omit `:cache_ttl` for the default of 300 seconds, pass `0` to disable the
  authorization cache, or pass a positive integer number of seconds.
  Anything else raises at the `configure/1` call, and nothing else in that
  call is applied. What changes, by value:
  - `nil`: was stored, then silently treated as 300 when the cache was first
    used. Now raises. Omit the option to get the default.
  - A negative integer: silently disabled the cache, the same as `0`. Now
    raises. Use `0` to disable.
  - A string (`"300"`, `"abc"`): silently treated as 300. Now raises.
  - A float (`3.5`, `300.0`): used as a fractional TTL (`3.5` cached for
    3.5 seconds). Now raises.
  - Omitted, `0`, and positive integers behave as before.

  `EndPointBlank.AuthCache` no longer rescues the `ArithmeticError` that a
  `nil` or string `cache_ttl` used to raise, which is where the silent 300
  came from. `configure/1` can no longer store such a value, so that rescue
  could only ever hide a broken invariant. If an invalid value is in the
  config anyway (for example, config state from 0.7.0 surviving a hot code
  upgrade), the cache now raises a `RuntimeError` that names the value, rather
  than guessing a TTL; calling `configure/1` with a valid `:cache_ttl`
  replaces it.

### Fixed

- **Runtime `cache_ttl` changes now apply to already-cached entries, not
  just to entries written after the change (sc-755).** Previously,
  lowering `cache_ttl` (e.g. `300` to `10`) had no effect on anything
  already cached — each entry only ever answered until the fixed
  `expires_at` computed from the TTL in force *when it was written*, so a
  lowered TTL could take up to the *old*, longer TTL to take effect for an
  entry cached just before the change. `AuthCache.put/2` now also records
  each entry's `written_at`, and `get/1` re-derives validity from the
  `cache_ttl` in force *at read time*: a hit requires both `now <
  expires_at` (raising `cache_ttl` never extends an entry past what it was
  written with) and `now - written_at < current cache_ttl` (lowering it
  applies starting on the very next read). Deliberately not implemented as
  `expires_at - now <= current cache_ttl` (a "remaining time" clamp): once
  enough real time has passed, an entry's remaining-until-original-expiry
  can coincidentally fall back under a new, shorter TTL window and look
  valid again even though it is older than that window allows — anchoring
  both checks to the fixed `written_at` avoids that trap.

- **Disabling `AuthCache` clears the *entire* cache the next time it is
  used, not just the one entry a request happens to touch — and the same
  is now true of a store made while disabled (sc-660, sc-755).** The only
  caller of `AuthCache.get/1` or `put/2` in this library is
  `EndPointBlank.Commands.EndpointAuthorize` (reached through
  `EndPointBlank.Plug.Authorized`), so concretely: an **authorize call**
  made while `cache_ttl` is `0` deletes every row in the table
  (`:ets.delete_all_objects/1`), not only the key that call happened to
  look up or write, so restoring `cache_ttl` afterwards cannot resurrect
  *any* decision cached before that call — including one for a caller that
  authorize call never touched. `handle_cast/2` also still re-checks the
  *current* `cache_ttl` before writing rather than trusting the expiry it
  was handed, so a write that raced the disable can no longer land and
  outlive it. `EndPointBlank.AuthCache.clear/0` is public, matching the
  `clear()` the JS, Python, Ruby and Java SDKs already had.

  **Residual, deliberately not fixed here:** even on a single node, the
  clear only happens on an authorize call (or a direct `get/1`/`put/2`)
  made *while* that node is disabled — never at `configure/1` time itself,
  and never merely because a request arrives. Disabling and re-enabling
  `cache_ttl` with no authorize call (or direct `get/1`/`put/2`) landing in
  between flushes nothing.

  `cache_ttl`, "disabled", and the table are each **per BEAM node** —
  none of them is shared or propagated across a cluster. `cache_ttl` comes
  from this node's own `EndPointBlank.Config`, set only via `configure/1`
  (there is no `ENDPOINTBLANK_CACHE_TTL` or other env-var fallback for
  this setting — see `Config`'s `resolve/1`), which only ever affects the
  node it runs on. So disabling `cache_ttl` on one node (say, node A) has
  *no effect at all* on any other node: node B and node C are not
  disabled, their tables are untouched, and a revoked grant already cached
  on either of them keeps answering for up to its own TTL — there is no
  mechanism by which they "find out" A was disabled. Flushing every node
  requires setting `cache_ttl` to `0` on **each node individually** and
  getting an authorize call (or a direct `get/1`/`put/2`) to land on
  **each of them** while it is disabled. Call `AuthCache.clear/0`
  directly, on every node, when a flush is the goal and that is not
  something you can rely on.

- **Defensive handling for a row left in the table from before this
  release, across a hot code upgrade.** A row written by 0.7.0 or earlier
  is a 3-element tuple with no `written_at`; this release's read path adds
  a `written_at`-bearing 4-element shape. The ETS table itself is not
  dropped by a code upgrade — only a process restart does that — so a host
  that upgrades without restarting could have both shapes in the table at
  once. `get/2` now recognizes the older shape explicitly, treating it as
  a miss and removing it, rather than assuming every row already matches
  the new one.

## 0.7.0

### Breaking

- **`EndPointBlank.configure/1` (`EndPointBlank.Config.update/1`) now raises
  `ArgumentError` on an unknown option, instead of silently dropping it.**
  Code that passed a misspelled or obsolete key — `client_secert:`,
  `base_uri:` — previously ran with that setting quietly missing (`nil`
  credentials, or the public default `base_url`) and no indication why. It
  now raises at the `configure/1` call, which for most hosts means at boot,
  so check your `configure/1` options before upgrading. The check is
  all-or-nothing: a mix of valid and unknown keys applies none of them.
  It also rejects `:__struct__` and anything that is not a keyword list. On
  0.6.0, `:__struct__` or a bare atom (`configure([:foo])`) crashed the config
  Agent outright (`FunctionClauseError`). Validation runs in the calling
  process, before the config Agent is touched, so a bad call cannot crash the
  Agent that owns the config store for the rest of the host app.

### Documentation

- **The README's install section said the package is on a private Hex
  organization. It is not.** Every release, 0.6.0 included, was published to
  the public hex.pm repository. The install instructions now show the plain
  `{:end_point_blank_elixir, "~> 0.7.0"}` dependency, with no `organization:`
  and no `mix hex.organization auth` step. It also recommends pinning to the
  patch level, because breaking changes ship in minor releases before 1.0.
- **The README showed `version_of :index, ["v1"], state: "Current"`.** There
  is no three-argument `version_of`; that example did not compile. Lifecycle
  state is managed in the portal, and the README now says so and shows
  `version_of/2`.

### Fixed

- **The caller's source environment is recorded again (sc-463).** On a 201,
  `EndPointBlank.Commands.EndpointAuthorize` read
  `source_application_environment_id` from an `accesses` key. Intake has only
  ever sent the grant list under `data`, so the id was always `nil`. That nil
  went into `RequestStore`, the auth cache, and every response, log and error
  payload, and the portal's error detail page could not name the calling
  client. It now reads `data`, as the Rails SDK does. A 201 that still
  carries no id authorizes the request but logs an error instead of passing
  silently. The test stubs had invented the `accesses` shape; they now
  answer in intake's real one.

- **`EndPointBlank.Config.get/0` is no longer a call to a process.** Every
  config read in the library goes through it — `masking_rules/0`,
  `mask_hook/0`, `worker_count/0`, all seven URL builders — so it sat in the
  hot path of every inbound request (the authorization plug, the version
  finder) and every outbound write. It was `Agent.get(__MODULE__, &resolve/1)`,
  which serialised all of that through a single mailbox for data that is
  written once at boot, and carried `Agent.get/2`'s 5000 ms default timeout.
  A call timeout **exits the caller**: a config process that was slow, wedged
  or merely restarting did not return an error to its readers, it killed them,
  a plug mid-request included.

  Writes still go through the Agent, which remains the writer of record: it
  serialises `update/1`'s read-modify-write and owns the read path's ETS
  table, so config still dies with the process rather than outliving it. Reads
  go straight to that table — `:protected`, `read_concurrency`, one row — as a
  lock-free lookup in the calling process. `ENDPOINTBLANK_*` fallbacks are
  unchanged and still resolved on every read, not frozen at write time: the
  table holds the *stored* config, and `resolve/1` now runs in the reader.

  ETS rather than `:persistent_term`, which is the other way to make a read
  free. Measured on this library's own struct: reads are 0.04 µs from
  `:persistent_term` against 0.16–1.2 µs from ETS (the difference is the copy,
  and it only becomes visible with a long `:masking_rules` list), but a
  `:persistent_term.put/2` of a changed value costs 170–430 µs against ETS's
  0.2 µs, and it pays that by scheduling a scan of **every process on the
  node** — the cost rises with the host's total live heap, not with anything
  this library does. This is a library embedded in someone else's application,
  `configure/1` is public API a host may call at runtime, and `update/1` and
  `reset/0` run constantly under test. Trading a sub-microsecond read for a
  node-wide GC pass per write is the wrong trade here.

  If the store is unavailable, `get/0` raises with a message saying so. It
  deliberately does **not** catch and fall back to a default `%Config{}`: that
  would authorize requests against `nil` credentials and write telemetry to
  the public default base URL because a process was down. Note this is a
  change in kind — an unavailable config used to *exit* its reader and now
  *raises* in it. `EndPointBlank.Writers.DelayedWriter` already guards its
  flush callback against both (see below), and that guard is still required
  and still tested. `AuthCache`'s `rescue` around the config read has been
  narrowed from `_` to `ArithmeticError`, which is the nonsensical
  `:cache_ttl` it was always for; a bare rescue would now swallow "the config
  store is down" and cache with an invented TTL.

- **`EndPointBlank.Writers.DelayedWriter` can no longer take the host
  application down.** It ran `Task.async_stream/3` inside its own
  `handle_info/2`, and those tasks are linked to the caller — so any raise or
  exit in any batch sent an exit signal to the writer itself. At the old 100 ms
  flush cadence a persistent fault restarted it about ten times a second,
  exceeding the supervisor's default intensity (3 restarts in 5 seconds) in
  well under a second; under `start_permanent: true` (a `:prod` release) that
  terminates the application and halts the node. A fire-and-forget telemetry
  writer could stop the service it was reporting on.

  A batch now fails inside its own task, where it is caught and cannot become a
  signal. The flush callback separately guards what it evaluates itself, which
  includes `EndPointBlank.Config.worker_count/0` — an `Agent.get/2` whose
  5000 ms default timeout exits *its caller*, and which runs in the writer
  process before any task is spawned, so an idle writer with an empty queue was
  just as exposed as a busy one.

  Deliberately still fatal: an exit signal delivered to a write task from
  outside it (`Process.exit(task, :kill)`, a `max_heap_size` breach, a
  `:brutal_kill` shutdown). Those are untrappable, and mean something outside
  this library is tearing processes down on purpose. A test pins that boundary.

- **Exceptions reported outside the request process are no longer dropped
  (sc-378).** `RequestStore` is backed by the process dictionary, so it is
  empty outside a request, and also inside one when read from any process
  other than the one Phoenix allocated: a `Task.async` closure, an Oban job, a
  GenServer callback. `ExceptionWriter` sent that `nil` as the payload's
  `uuid`. Intake requires `uuid`, so it rejected the row and the error never
  reached the portal; the only sign was a `Write ... failed` warning in the
  host's own log. The writer now mints a uuid when the store has none.
  That uuid is not correlated with any request, but the error is recorded.
  Request context is still not propagated across processes.

- **A `mask_hook` now sees `stamped_path` and `stamped_http_method` (sc-382).**
  `LogWriter` and `ExceptionWriter` used to mask first and merge the stamped
  fields in afterwards, so a hook could not redact a sensitive path segment
  such as `/patients/1234/notes`. The JS and Rails SDKs could. Both writers
  now merge first and mask second. Rule-based masking is unaffected, because
  no rule targets those keys.

### Added

- `EndPointBlank.Commands.GenerateAccessToken.generate_result/1`, returning
  `{:ok, payload}` or `{:error, reason}` so a caller can tell a rejected
  credential from a failed intake. Reasons are `:credential_rejected` (401 —
  permanent until the credential is re-issued), `{:request_rejected, status}`
  (any other 4xx — also permanent, but the remedy is the request or the
  registration), `{:server_error, status}` (5xx) and
  `{:transport_error, reason}` (both transient).
  `{:server_error, status}` also covers a 2xx the SDK cannot read an access
  token out of, carrying the real 2xx status.
- `EndPointBlank.AccessTokens.last_failure/1`, reporting the last failure
  recorded for a URL, using exactly those reasons. A successful mint clears
  the record, and only the 64 most recently failed URLs are kept so a revoked
  credential — which fails every mint forever — cannot grow the map without
  bound.
- A distinct, loud log line when intake rejects the credential, instead of the
  generic "Failed to generate access token" that reads as an outage.

### Changed

- **The `:delayed` flush interval is now 1 second, was 100 ms.** A 100 ms
  window batched almost nothing at any realistic payload rate, cost ten
  wakeups (and ten `Agent.get/2` round trips to the Config agent) per second in
  every host app whether or not anything was queued, and was the multiplier
  that turned a recoverable fault into a restart storm. Delivery of telemetry
  nobody is waiting on is up to 900 ms later; nothing else changes.
- A flush that fails is logged once, at `error` level, naming the exception,
  the number of consecutive failing flushes, how many batches and payloads went
  with it, the retry interval and the failing stack frame. Consecutive failures
  back the flush interval off exponentially — 1 s doubling to a 30 s ceiling —
  and the first clean flush resets it. A non-2xx or an exhausted transport
  retry is *not* counted: `DirectWriter` already reports those, and they are an
  expected outcome of talking to a network rather than a defect.
- A flush with nothing queued now returns before consulting
  `EndPointBlank.Config`, so an idle host app makes no `Agent.get/2` calls on
  the writer's behalf at all.
- `:worker_count` was documented in the README as "reserved for future writer
  pooling; not currently read by any writer". It has been the delayed writer's
  `max_concurrency` for some time; the table now says so.
- Nothing removed or renamed. `GenerateAccessToken.generate/1`,
  `AccessTokens.token/1` and `AccessTokens.exists?/1` keep their exact return
  contracts (payload-or-`nil`, token-or-`nil`, boolean) and their existing log
  lines; `generate/1` is now a thin wrapper over `generate_result/1`.
- `generate/1` now returns `nil`, rather than the raw body, for a 2xx it
  cannot read an access token out of — an undecodable body, one that is not a
  JSON object, or one carrying no `token` or no `base_url`. Its documented
  contract already called that a failure, and a healthy intake never sends
  one, but it is a behaviour change at the edge.

## 0.6.0

### Breaking

- **`Authorization.header/1` and `AccessTokens.token/1` now take a URL, not a
  hostname.** Pass the URL you are about to call —
  `https://api.example.com/orders`, not `api.example.com`. Strip any query
  string or fragment first; they are rejected. Earlier READMEs showed the
  hostname form; those examples no longer work.
- **`AccessTokens.exists?/1` now requires the same URL argument.** It answers
  for the entry covering that URL; there is no longer a single process-wide
  token for it to answer about.
- **Requires an intake that accepts `base_url`.** An older intake returns
  `400 {"error":"Missing required parameter: base_url"}`.

### Changed

- `EndPointBlank.Commands.EndpointAuthorize` authenticates to intake with
  Basic instead of minting an access token for itself (previously via
  `EndPointBlank.Commands.GenerateAccessToken.generate/1`). The inbound
  request path no longer touches the token cache at all.
- A 401 from the authorize endpoint is returned to the caller rather than
  retried once. With Basic, a 401 means the credential is wrong.
- Tokens are cached per application environment, keyed on the canonical base
  URL intake resolves the request to, rather than one per process.
