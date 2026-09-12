# Changelog

## Unreleased

### Fixed

- **Disabling `AuthCache` now actually invalidates it, instead of only
  hiding entries (sc-660).** `cache_ttl <= 0` previously made `get/1` refuse
  to look at the table, but left every stored row untouched; restoring
  `cache_ttl` afterwards brought every one of them back, including a
  decision cached before a grant was revoked. An operator disabling the
  cache specifically to force-flush a revoked grant, then re-enabling it
  once the caller was confirmed refused, would have that stale
  authorization silently resurface from cache. `get/1` and `put/2` now
  delete every entry (`:ets.delete_all_objects/1`) whenever they observe the
  cache disabled, and `handle_cast/2` re-checks the *current* `cache_ttl`
  before writing rather than trusting the expiry it was handed, so a write
  that raced the disable — decided while the TTL was still live, processed
  after it dropped to zero — can no longer land and outlive the disable it
  raced. `EndPointBlank.AuthCache.clear/0` is now public, matching the
  `clear()` the JS, Python and Ruby SDKs already had; Elixir was the only
  one without it.

  **Known remaining gap, deliberately not fixed here:** lowering `cache_ttl`
  to a smaller *positive* value (e.g. `300` to `10`) does not shorten the
  remaining life of entries already cached — they keep answering until
  their original expiry. Only dropping to `0` or below (a full disable)
  gets the immediate-effect behavior above. sc-660 named "lowering the TTL"
  generally as the incident-response case worth covering; a correct fix for
  the partial case needs either recomputing an entry's remaining life
  against the *currently* configured TTL from its original write time (a
  larger change to the expiry model — a naive "remaining ≤ current TTL"
  clamp is subtly wrong: it lets an entry outlive a lowered TTL once enough
  time has passed that its remaining life happens to fit back under the new,
  shorter window) or tracking the previously observed TTL to detect and act
  on any downward change, not just a drop to zero. Both are a bigger design
  question than this PR's scope. None of the JS, Python or Ruby SDKs
  implement TTL-driven invalidation at all today (they only ever consult
  `cache_ttl` at write time), so this is a four-SDK gap, not an Elixir-only
  one.

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
