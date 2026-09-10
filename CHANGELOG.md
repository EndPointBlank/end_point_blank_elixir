# Changelog

## Unreleased

### Fixed

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
