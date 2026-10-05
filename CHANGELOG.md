# Changelog

## 0.10.1

### Added

- **`ManagedClients.claim_invite/4` takes `return_to:`.** A URL registered
  under the provider organization's claim return URLs; once the user accepts
  the claim, EndPointBlank sends their browser back to it, as an OAuth
  `redirect_uri` would. Refused with `"return_to_not_registered"` otherwise.

## 0.10.0

### Added

- **A client for the organization management API (sc-1504).**
  `EndPointBlank.Management.new(key: "epb_mk_...")` builds it, separate from
  the runtime SDK: it reads none of `EndPointBlank.configure/1`'s settings,
  sends only the management key (as `Authorization: Bearer`, to
  `https://app.endpointblank.com` or `:base_url`), refuses a key that is not
  `epb_mk_...`, and leaves the key out of `inspect/1` and every error. One
  module per resource: `Organization`, `ApiPackages` (with `list_endpoints`,
  `add_endpoint`, `remove_endpoint`), `Endpoints`, `Clients`,
  `ClientPackages`, `ClientGrants`, `Applications`,
  `ApplicationEnvironments`, `Environments`, `Credentials` (`create`,
  `rotate`, `delete`/`revoke`) and `ManagedClients` (`claim_invite`);
  `Management.for_managed_client/2` scopes applications, environments and
  credentials to a managed client. Every call answers `{:ok, data}` or
  `{:error, %EndPointBlank.Management.Error{}}` (`code`, `message`,
  `details`, `status`, `retry_after`, `location`); lists answer an
  `EndPointBlank.Management.Page` and have a lazy `stream`. Every POST sends
  an `Idempotency-Key` (generated, or `idempotency_key:`), reused on retry.
  `429` is retried after `Retry-After`, and 5xx or transport failures for
  GET, DELETE and POST only, at most `:max_retries` (default 2) times;
  `idempotency_replay_unavailable` is never retried. No new dependencies:
  it uses `Req`, as the rest of the SDK does.

## 0.9.0

### Breaking

- **Outbound calls to a provider never fall back to HTTP Basic; the SDK
  refuses instead (sc-1469).** `EndPointBlank.Authorization.header/1` used to
  answer `"Basic base64(client_id:client_secret)"` whenever no access token
  could be minted — an intake outage or timeout, a 5xx, a revoked credential
  (401) — which sent this service's own credential to whichever provider it
  was calling. A provider is not EndPointBlank and must never see it.
  - `header/1` now returns `{:ok, "Bearer <token>"}` or `{:error, reason}`
    instead of a bare string. `reason` is an
    `EndPointBlank.AccessTokens.failure/0` (`:credential_rejected`,
    `{:request_rejected, status}`, `{:server_error, status}`,
    `{:transport_error, reason}`), `:token_cache_unavailable`,
    `:invalid_token` (a defensive refusal should the token cache ever answer
    without a usable token), `:missing_base_url`, `:invalid_base_url`,
    `:missing_credentials`, or `{:unexpected, reason}`. On an error, do not
    make the call.
  - New `header!/1` returns the `"Bearer <token>"` string or raises the new
    `EndPointBlank.TokenUnavailableError` (fields `:base_url`, `:reason`,
    `:status`, `:message`). The message says the token could not be minted,
    why, and that credentials are never sent to providers.
    `TokenUnavailableError.message/2` builds the same text from a `header/1`
    error.
  - `TokenUnavailableError`'s `:status` is the HTTP status intake answered
    the token request with, derived from the reason: `401` for
    `:credential_rejected`, `status` for `{:request_rejected, status}` and
    `{:server_error, status}`, and `nil` otherwise (a transport error, the
    cache not answering, a missing URL). `TokenUnavailableError.status/1`
    derives it from a `header/1` error.
  - The message is built from fixed phrases, the same in every EndPointBlank
    SDK, and never `inspect`s the reason or repeats intake's response body,
    a transport error or an exception: a transport error can carry request
    data. `:credential_rejected` reads "intake rejected this application's
    client credential (HTTP 401); retrying cannot help -- re-issue the
    credential"; `{:request_rejected, s}` "intake refused the token request
    (HTTP s); check the URL and that a grant covers the target";
    `{:server_error, s}` "intake failed to issue a token (HTTP s); this may be
    transient"; a transport error "intake could not be reached (timeout,
    connection refused or retries exhausted); this may be transient"; a mint
    that raised or threw "the token request failed unexpectedly". The raw
    term is kept on `:reason`.
  - The URL's userinfo, query and fragment are removed before the token
    request (new `EndPointBlank.OutboundUrl.strip/1`); they are never sent to
    intake, logged, or kept on the error. intake refuses a `base_url`
    carrying any of them with 422, so sending them both leaked them and
    guaranteed the mint failed. `header/1`, `AccessTokens.token/1`,
    `token_result/1`, `exists?/1`, `last_failure/1` and
    `GenerateAccessToken.generate_result/1` all strip, so cache keys, failure
    keys and log lines use the stripped form, and `TokenUnavailableError`'s
    `:base_url` holds the stripped URL (`nil` when none parsed), never the
    one passed in. A URL that does not parse or has no scheme or host is
    refused with `{:error, :invalid_base_url}` without a request; a
    non-string one passed to `AccessTokens.token_result/1` answers
    `{:error, :missing_base_url}` without a request (it used to be sent to
    intake).
  - The access-token failure log line no longer `inspect`s a transport
    error; it names only an atom reason such as `econnrefused`.
  - `header/0` is gone; it always answered Basic, for writers and host
    code alike. `header(nil)` and `header("")`, which also answered Basic,
    now answer `{:error, :missing_base_url}`.
  - A missing `client_id` or `client_secret` (nil or empty) is refused
    before any request: `header/1` answers `{:error, :missing_credentials}`,
    `header!/1` raises the new `EndPointBlank.ConfigurationError`, and
    `GenerateAccessToken.generate_result/1` answers
    `{:error, :missing_credentials}`. The request used to go out as Basic of
    `":"`, intake answered 401, and the error said to re-issue the credential.
  - Only a real failure to reach intake (`Req.TransportError`,
    `Req.HTTPError`, the Mint/Finch equivalents, or an atom such as
    `:timeout`) is `{:transport_error, reason}`. A mint that raised or threw,
    or an HTTP-client error that is not a transport failure, is now
    `{:unexpected, reason}` (it was `{:transport_error, reason}`):
    `TokenUnavailableError` has a new `:unexpected` field, `true` for it, and
    `TokenUnavailableError.unexpected?/1` derives it from a `header/1` error.
    Neither `:missing_credentials` nor `{:unexpected, _}` is recorded for
    `AccessTokens.last_failure/1` or drops a held token.
  - `OutboundUrl.strip/1` also lowercases the scheme and host and drops an
    empty port (`https://api.test:/x`) along with a default one. A scheme
    other than `http` or `https`, or a port that is not a number from 1 to
    65535, is refused with `:invalid_base_url`, whose message now reads "the
    URL is not an absolute http or https URL with a host and a port from 1
    to 65535, so no token was requested".
  - Every call to the SDK's own intake refuses a missing credential too,
    through the new `Authorization.intake_header/0` (`{:ok, "Basic ..."}` or
    `{:error, :missing_credentials}`) and `intake_header!/0`. They used to
    send `Basic Og==` (base64 of `":"`). Now nothing is sent: the authorize
    plug answers 503 (`EndpointAuthorize.authorize/3` returns
    `{:error, :missing_credentials}`), and `EndpointUpdate.update/1` and the
    writers log `ConfigurationError`'s message ("EndPointBlank is missing
    client_id and client_secret: ...") and return `:error`. None of them, nor
    the `AccessTokens` GenServer, raises for it. `ConfigurationError` gains
    `:missing`, naming what is missing, and `Authorization.missing_credentials/0`
    reports the same list.
  - The HTTP retry, access-token, authorize, endpoint-update and
    direct-writer error log lines no longer `inspect` the transport error;
    they name its atom reason or exception module only. A mint that raised logs the exception's module, not its
    message.
  - Migrating: replace `auth = Authorization.header(url)` with
    `{:ok, auth} = Authorization.header(url)` plus an error branch, or with
    `auth = Authorization.header!(url)`. Do not rescue the error and send
    `basic_header/0` yourself.

### Added

- `EndPointBlank.AccessTokens.token_result/1`: `{:ok, token}` or
  `{:error, reason}` with the reason for that very mint. `token/1` still
  answers the token or `nil`.
- **The intake hostname can be derived from `client_id` (sc-1463), off by
  default.** New credentials carry their organization's slug as a prefix
  (`acima-x7k2mq.<random>`), and that organization's intake answers at
  `https://<slug>.in.endpointblank.com`. With the new
  `derive_base_url_from_client_id: true`, the SDK calls that hostname when
  neither `:base_url` nor `ENDPOINTBLANK_BASE_URL` is set. It derives only when
  the part before the first `.` has the exact shape of an organization slug
  and something follows the dot (`EndPointBlank.Config.client_id_slug/1`, the
  same rule as app_portal's `Credentials.client_id_slug/1`); any other
  `client_id`, including a legacy `my.client`, calls
  `https://in.endpointblank.com` as before. The option defaults to `false`
  because `*.in.endpointblank.com` has no DNS or TLS in production yet; with it
  off, every `client_id` resolves exactly as in 0.8.0. It will default to
  `true` in a later release, once DNS and TLS are live. A value other than
  `true` or `false` is refused by `configure/1` with `ArgumentError`. The logs
  hostname (`:log_base_url`) is never derived.
- **Every call to intake sends `x-epb-sdk: elixir/<version>` (sc-1463)**, with
  the version of this library as loaded. intake ignores it today; it will
  record the oldest version seen per credential for the move gate. **This
  release is not that gate's minimum Elixir version:** derivation is off by
  default here, so a host on this version with the default config keeps
  calling `in.endpointblank.com` after its organization moves. The minimum is
  the release that turns `derive_base_url_from_client_id` on by default.

### Unchanged

- A 503 or a 429 from intake is never cached (sc-1463 conformance, now pinned
  by tests): the authorization cache stores only a 201, and the token cache
  stores only a token, so the next call asks intake again. The token cache is
  still keyed on the `base_url` the mint response returns, and a 2xx without
  one is still a failed mint, `{:server_error, status}`. intake sends
  `base_url` on every successful mint, and this SDK has required it since
  0.6.0.
- Calls to this SDK's own intake — authorize, token minting, endpoint updates
  and the request/response/log/error writers — still authenticate with Basic,
  now via `Authorization.intake_header/0`, which refuses when a credential is
  missing (above). The writers used `header/0` for this. `basic_header/0`
  is still public but no longer used by the SDK.

## 0.8.0

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
