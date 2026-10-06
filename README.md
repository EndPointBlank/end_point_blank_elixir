# EndPointBlank (Elixir)

Elixir and Phoenix SDK for [EndPointBlank](https://endpointblank.com): authorize service-to-service API calls, report endpoint versions, and see which clients still call deprecated API versions. It covers endpoint tracking and authorization, request/response/error/log reporting, and client-side data masking, all reporting back to the EndPointBlank API.

## Installation

This package is published to the public [hex.pm](https://hex.pm/packages/end_point_blank_elixir)
repository:

```elixir
def deps do
  [
    {:end_point_blank_elixir, "~> 0.11.0"}
  ]
end
```

Pin to the patch level (`~> 0.11.0`, not `~> 0.11`): before 1.0, breaking
changes ship in minor releases, so `~> 0.11` would accept a future 0.12.0.

Or depend on a release tag of the git repo directly:

```elixir
def deps do
  [
    {:end_point_blank_elixir, git: "https://github.com/EndPointBlank/end_point_blank_elixir.git", tag: "v0.11.1"}
  ]
end
```

The library starts its own supervision tree (`EndPointBlank.Application`) as
soon as it's listed as a dependency — no extra child spec to add to your app.

## Quick start

Configure credentials (typically in `application.ex`'s `start/2`, before your
endpoint starts) and wire in the two plugs:

```elixir
EndPointBlank.configure(
  client_id: "my-client-id",
  client_secret: "my-client-secret",
  app_name: "my-app",
  environment: "production"
)
```

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # ... other plugs ...

  plug EndPointBlank.Plug.ReportInteraction
  plug MyAppWeb.Router
end
```

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug EndPointBlank.Plug.Authorized
  end
end
```

With just this, every request/response pair is reported to EndPointBlank, and
every request is authorized against your configured application before it
reaches your controllers.

## Configuration

All settings live in a singleton `EndPointBlank.Config` store (started by
`EndPointBlank.Application`), set via `EndPointBlank.configure/1`, and read
back via `EndPointBlank.Config.get/0`. Six of them also fall back to
`ENDPOINTBLANK_*` environment variables so you can run without any
Elixir-side configuration at all (e.g. purely env-driven deployments).

Writes go through an Agent, which serialises them. Reads do not: `Config.get/0`
is a lock-free ETS lookup performed in the calling process, because it sits in
the hot path of every inbound request and every outbound write. Nothing your
app does can queue behind a config write, and a busy config process cannot
take a request down with it. If the store is unavailable — the application is
not started, or the config process is down — `Config.get/0` **raises**. It
does not fall back to a blank config: that would mean authorizing against
`nil` credentials and shipping telemetry to the default base URL because a
process happened to be down.

**Precedence** (per setting, resolved fresh on every `Config.get/0` call —
the env var is never cached): **explicit `configure/1` value > `ENDPOINTBLANK_*`
env var > built-in default**.

| Setting | Config key | Env var | Default |
|---|---|---|---|
| API client ID | `:client_id` | `ENDPOINTBLANK_CLIENT_ID` | `nil` |
| API client secret | `:client_secret` | `ENDPOINTBLANK_CLIENT_SECRET` | `nil` |
| Authorization/update API base URL | `:base_url` | `ENDPOINTBLANK_BASE_URL` | `"https://in.endpointblank.com"` |
| Request/response/log/error ingestion base URL | `:log_base_url` | `ENDPOINTBLANK_LOG_BASE_URL` | `"https://log.endpointblank.com"` |
| Application identifier sent with every payload | `:app_name` | `ENDPOINTBLANK_APP_NAME` | `nil` |
| Deployment environment (e.g. `"production"`) | `:environment` | `ENDPOINTBLANK_ENV` | `nil` |
| App version string (e.g. a git SHA), sent as `app_version` on endpoint registration | `:application_version` | — (`configure/1` only) | `nil` |
| Custom 1-arity API-version detector, `fn conn -> version end` | `:version_finder` | — (`configure/1` only) | `nil` |
| Access-token TTL in seconds (sent to `GenerateAccessToken`) | `:token_ttl` | — (`configure/1` only) | `nil` |
| Post-rule masking hook, `fn payload, record_type -> payload end` | `:mask_hook` | — (`configure/1` only) | `nil` |
| Write mode: `:direct` (synchronous HTTP per payload) or `:delayed` (batched background queue) | `:log_mode` | — (`configure/1` only) | `:direct` |
| Max concurrent writes `EndPointBlank.Writers.DelayedWriter` performs per flush | `:worker_count` | — (`configure/1` only) | `4` |
| Authorization-cache TTL in seconds (`EndPointBlank.AuthCache`); `0` disables the cache. See [`:cache_ttl` values](#cache_ttl-values) | `:cache_ttl` | — (`configure/1` only) | `300` |
| Whether the per-request `scheme`/`host`/`port` report honors `x-forwarded-proto`/`-host`/`-port` (see [Reported base URL](#reported-base-url)) | `:trust_proxy_headers` | — (`configure/1` only) | `true` |
| Ordered list of masking rule maps (see [Data masking](#data-masking)) | `:masking_rules` | — (`configure/1` only) | `[]` |
| Derive the intake hostname from a slug-prefixed `client_id` when no base URL is set (see [Intake hostname from `client_id`](#intake-hostname-from-client_id)) | `:derive_base_url_from_client_id` | — (`configure/1` only) | `false` |

### `:cache_ttl` values

`:cache_ttl` follows one rule, the same in the Elixir, JS, Java, Python and
Rails SDKs:

| You pass | Result |
|---|---|
| nothing (omit `:cache_ttl`) | the default, 300 seconds |
| a positive integer, e.g. `cache_ttl: 60` | cache authorizations for that many seconds |
| `cache_ttl: 0` | caching disabled |
| `cache_ttl: nil` | `ArgumentError` from `configure/1` |
| a negative integer, e.g. `cache_ttl: -1` | `ArgumentError` from `configure/1` |
| anything else that is not an integer: a float (`3.5`, `300.0`), a string (`"300"`) | `ArgumentError` from `configure/1` |

The error is raised by the `configure/1` call itself, so a bad value fails at
boot rather than when the first request is authorized, and nothing else in
that `configure/1` call is applied. To get the default, leave `:cache_ttl` out;
`nil` does not mean "use the default". A value read from an environment
variable arrives as a string, so convert it first
(`String.to_integer(System.fetch_env!("MY_CACHE_TTL"))`).

### Configure example (all settings)

```elixir
EndPointBlank.configure(
  base_url: "https://in.endpointblank.com",
  log_base_url: "https://log.endpointblank.com",
  client_id: "my-client-id",
  client_secret: "my-client-secret",
  app_name: "my-app",
  environment: "production",
  application_version: System.get_env("GIT_SHA"),
  log_mode: :delayed,
  token_ttl: 3600,
  cache_ttl: 300,
  trust_proxy_headers: true,
  version_finder: fn conn -> Plug.Conn.get_req_header(conn, "x-api-version") |> List.first() end
)
```

### Reported base URL

Every request payload carries the base URL the *caller* used, as three separate
fields — `scheme`, `host` and `port`. A field that cannot be resolved is omitted
rather than sent as null. EndPointBlank uses these to fill in an application
environment's base URL for you, instead of asking someone to type it.

By default the library honors `x-forwarded-proto`, `x-forwarded-host` and
`x-forwarded-port`, reading the **last** comma-separated hop, straight off
`conn.req_headers`. Plug has no notion of a trusted proxy unless your
application installs `Plug.RewriteOn` itself, which is why this client could not
previously see through a load balancer at all. It resolves the headers the same
way the Ruby, JS, Python and Java clients do, so all five answer identically for
the same request.

**Turn this off if your application is reachable directly, with no proxy in
front of it** — or if you would simply rather report nothing than report
something a caller could influence:

```elixir
EndPointBlank.configure(trust_proxy_headers: false)
```

With it off, the `x-forwarded-*` headers are ignored entirely and `scheme`,
`host` and `port` come from the conn and the `host` header only.

It defaults to `true` because the alternative is worse for almost everyone. Most
production deployments sit behind an ALB, nginx, Caddy or an Ingress, and a
client that ignored the forwarded headers there would not report *nothing* — it
would confidently report an internal hostname on an internal port. `host` is
caller-controlled either way (`conn.host` comes from the `host` header), and
none of these three values is ever used as an identity or authorization key, so
the worst case is a wrong *suggestion* that an admin has to approve.

### Intake hostname from `client_id`

Each organization's intake will answer at its own hostname,
`https://<slug>.in.endpointblank.com`, and every new `client_id` starts with
that slug and a dot (`acima-x7k2mq.ijXI+MVwmrC5xH/9ZuGiQlAbAyobTqMa`). With
`derive_base_url_from_client_id: true`, the SDK picks its intake in this
order:

1. `:base_url`, or else `ENDPOINTBLANK_BASE_URL`, if either is set;
2. else, if the `client_id` carries a slug prefix,
   `https://<slug>.in.endpointblank.com`;
3. else `https://in.endpointblank.com`.

A `client_id` carries a slug prefix only when the part before its first `.`
has the exact shape of an organization slug and something follows the dot
(`EndPointBlank.Config.client_id_slug/1`). A credential issued before slugs,
including one with a `.` in it such as `my.client`, keeps calling
`https://in.endpointblank.com`.

**This is off by default, and turns on by default in a later release, once
DNS and TLS for `*.in.endpointblank.com` are live.** Until then those
hostnames do not resolve in production, so leave it off unless EndPointBlank
has told you otherwise. With it off, the base URL is `:base_url`, else
`ENDPOINTBLANK_BASE_URL`, else `https://in.endpointblank.com`, whatever the
`client_id`.

The logs hostname is not derived: `:log_base_url`, else
`ENDPOINTBLANK_LOG_BASE_URL`, else `https://log.endpointblank.com`, as before.

Every call to intake also sends `x-epb-sdk: elixir/<version>`, so
EndPointBlank can tell which SDK versions use a credential before it moves an
organization to another intake. The minimum Elixir version for a move is the
release that turns `derive_base_url_from_client_id` on by default, **not**
this one: with the option at its default here, the SDK keeps calling
`https://in.endpointblank.com` after its organization has moved.

### 12-factor / env-var example

Only these six settings have an env-var fallback; everything else must be set
via `EndPointBlank.configure/1` (there's no `:log_mode` or `:masking_rules`
env var, for example):

```bash
export ENDPOINTBLANK_CLIENT_ID="my-client-id"
export ENDPOINTBLANK_CLIENT_SECRET="my-client-secret"
export ENDPOINTBLANK_APP_NAME="my-app"
export ENDPOINTBLANK_ENV="production"
export ENDPOINTBLANK_BASE_URL="https://in.endpointblank.com"
export ENDPOINTBLANK_LOG_BASE_URL="https://log.endpointblank.com"
```

With just the env vars set, you can skip `EndPointBlank.configure/1` entirely
(or call it with only the settings that don't have an env fallback, like
`log_mode:`).

## Usage

### Authorization

`EndPointBlank.Plug.Authorized` calls the EndPointBlank `/api/authorize`
endpoint for the current request and halts with a `401` (authorization
denied) or `503` (service unavailable) JSON response on failure. It can be
used as a controller plug or in a router pipeline:

```elixir
defmodule MyAppWeb.BooksController do
  use Phoenix.Controller
  plug EndPointBlank.Plug.Authorized
  ...
end
```

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug EndPointBlank.Plug.Authorized
end
```

Under the hood it:

- Resolves the route pattern via `EndPointBlank.Phoenix.RoutePatternFinder`
  (falls back to `conn.request_path` if no Phoenix router is present) and the
  API version via `EndPointBlank.VersionFinder`.
- Authenticates to intake with `Authorization: Basic <client_id:client_secret>`
  (`EndPointBlank.Authorization.intake_header/0`). This call never presents a
  Bearer token — intake already holds this service's credential, so minting
  one to present it back would be a hop that buys nothing, and with no Bearer
  there is nothing that can go stale for a `401` to retry. Without both
  `client_id` and `client_secret` nothing is sent: the plug logs why and
  answers 503, failing closed.
- Caches successful authorizations for up to `:cache_ttl` seconds
  (`EndPointBlank.AuthCache`), keyed on the caller's own auth header, path,
  HTTP method, `app_name`, and API version — repeat calls skip the network
  round trip.
  `:cache_ttl` is re-checked on every read, not just applied to entries
  written after it changes: lowering it shortens the remaining life of
  everything already cached (an entry never outlives whichever is smaller,
  the TTL it was written with or the TTL currently configured), and raising
  it never extends an entry past what it was written with. Setting
  `:cache_ttl` to `0` disables the cache outright: every lookup
  misses, and an authorize call made *while disabled* deletes every entry
  already stored, not merely the one it looked up — so raising `:cache_ttl`
  back up afterwards cannot resurrect anything that was cached before that
  call. This is the SDK's answer to "force-flush a revoked grant", but note
  two things before relying on it: the trigger, and the scope.

  The trigger: the flush happens on the next authorize call (or a direct
  `EndPointBlank.AuthCache.get/1`/`put/2`) made while `:cache_ttl` is `0`,
  not at the moment `configure/1` sets it. Disabling and re-enabling with no
  authorize call in between flushes nothing.

  The scope: `:cache_ttl`, "disabled", and the cache table are each
  **per BEAM node** — none of them is shared or propagated across a
  cluster. `:cache_ttl` comes from this node's own configuration, set only
  via `configure/1` (there is no `ENDPOINTBLANK_CACHE_TTL` or other env
  var for it — see the settings table above), which only ever affects
  the node it runs on, and the cache is an ETS table, which ETS never
  distributes. So running `configure(cache_ttl: 0)` on one node (say, node
  A) does **not** disable node B or node C at all: their `:cache_ttl` is
  whatever it already was, they are not "disabled" by any definition this
  module has, and a revoked grant already cached on either of them keeps
  answering for up to its own TTL — nothing here makes B or C "find out"
  that A was disabled, no matter how much traffic reaches them. Flushing
  every node requires setting `:cache_ttl` to `0` on **each node
  individually** and getting an authorize call (or a direct
  `get/1`/`put/2`) to land on **each of them** while it is disabled. Call
  `EndPointBlank.AuthCache.clear/0` directly, on every node, when a flush
  is the goal and that is not something you can rely on.
- Stores the `source_application_environment_id` from the response's `data`
  list in `EndPointBlank.RequestStore` for the rest of the request lifecycle
  (it's attached to response/log/error payloads).

`EndPointBlank.UnauthorizedError` is available for your own code to raise on
authorization failures. `EndPointBlank.Plug.ReportInteraction` (below)
specifically re-raises it *without* sending it to the error-reporting
endpoint, since the authorization flow already reports the denial itself.

### Calling another EndPointBlank-protected service

`EndPointBlank.Authorization.header/1` is the public building block for your
own outbound calls to *other* services protected by EndPointBlank (providers).
Pass the URL you are about to call, **not a hostname** — intake normalizes the
base URL and matches it against registered base URLs by longest path prefix,
so you do not need to know how the target registered itself. Its userinfo,
query and fragment are removed before the token request, the scheme and host
are lowercased, and a default port (`:443` for https, `:80` for http) or an
empty one is dropped; userinfo, query and fragment are never sent to intake,
logged, or kept on the error. A URL that does not parse, has no host, has a
scheme other than `http` or `https`, or has a port that is not a number from
1 to 65535 is refused with `{:error, :invalid_base_url}` without asking
intake. `header!/1` raises `EndPointBlank.TokenUnavailableError`
for it (reason `:invalid_base_url`, or `:missing_base_url` for a missing URL);
the Ruby SDK raises `ArgumentError` for both:

```elixir
url = "https://api.example.com/orders"

case EndPointBlank.Authorization.header(url) do
  {:ok, auth} ->
    # "Bearer <token>", minting one via EndPointBlank.AccessTokens if none is
    # held yet.
    Req.post(url, json: order, headers: [{"authorization", auth}])

  {:error, reason} ->
    # No token could be obtained. Do NOT make the call, and do not send
    # Basic credentials yourself.
    {:error, EndPointBlank.TokenUnavailableError.message(url, reason)}
end

# Or, raising EndPointBlank.TokenUnavailableError (or
# EndPointBlank.ConfigurationError, below) instead:
auth = EndPointBlank.Authorization.header!(url)
```

If `client_id` or `client_secret` is not configured (nil or empty), nothing
is sent: `header/1` answers `{:error, :missing_credentials}` and `header!/1`
raises `EndPointBlank.ConfigurationError`. Before, the token request went out
with an empty credential, intake answered 401, and the error said to re-issue
a credential that had simply never been set. The SDK's own calls to intake
refuse the same way, without sending anything: the authorize plug answers 503,
and the endpoint update at boot and the writers log "EndPointBlank is missing
client_id and client_secret: ..." and return. None of them raises into your
application; only `header!/1` (and `Authorization.intake_header!/0`) raise.

**Your `client_id`/`client_secret` is never sent to a provider.** When a token
cannot be minted — intake is down or times out, answers 5xx, or rejects the
credential with 401 — `header/1` answers `{:error, reason}` and `header!/1`
raises `EndPointBlank.TokenUnavailableError`, whose message says what failed
and why. Neither falls back to HTTP Basic. Until sc-1469 `header/1` did, which
handed the credential to the provider. A missing or empty URL is
`{:error, :missing_base_url}`; there is no no-argument `header/0`.

`reason` is one of the failures below, plus `:missing_base_url`,
`:invalid_base_url`, `:missing_credentials`, `:token_cache_unavailable` (the
token cache did not answer in time) and `{:unexpected, reason}`: the mint
raised, threw, or the HTTP client answered something that is not a transport
failure — a bug or a bad setting, not intake being out of reach. Only a real
failure to reach intake (a timeout, a refused connection) is
`{:transport_error, reason}`. `EndPointBlank.TokenUnavailableError` carries
the reason as `:reason` alongside `:base_url` (the stripped URL, or `nil` when
there was none that parsed), `:status`, the HTTP status intake answered with
(`401` for `:credential_rejected`, the status in `{:request_rejected, status}`
or `{:server_error, status}`, otherwise `nil`), and `:unexpected`, `true` for
`{:unexpected, _}`. The message is built from fixed
phrases, the same in every EndPointBlank SDK, and never repeats intake's
response body, a transport error or an exception: for example "intake
rejected this application's client credential (HTTP 401); retrying cannot
help -- re-issue the credential", or "intake could not be reached (timeout,
connection refused or retries exhausted); this may be transient". A mint that
raised reads "the token request failed unexpectedly". The raw term stays on
`:reason`.

`EndPointBlank.AccessTokens` caches one token per application environment,
keyed on the canonical base URL intake resolves the request to — not on the
URL you passed — so a service that calls several targets holds a token for
each. Every call this SDK makes to its *own* intake (authorize, token minting,
endpoint updates and the writers) uses
`EndPointBlank.Authorization.intake_header/0` instead, which answers
`{:ok, "Basic ..."}` or `{:error, :missing_credentials}`; intake already holds
the credential. Never use it, or `basic_header/0`, for a call to a provider.

#### Finding out why a token could not be minted

`header/1` answers the reason for the mint it just attempted, and
`AccessTokens.token_result/1` does the same for the bare token
(`AccessTokens.token/1` answers `nil` for every failure). Not every failure is
an outage: intake answers **401** when
the API credential itself has been rejected, and that is permanent until
someone re-issues it. `AccessTokens.last_failure/1` reports the last failure
for a URL so a caller can tell them apart and alarm on the one that will not
fix itself:

```elixir
case EndPointBlank.AccessTokens.last_failure("https://api.example.com/orders") do
  nil -> :ok
  # Permanent — retrying changes nothing.
  :credential_rejected -> alarm("re-issue the EndPointBlank credential")
  {:request_rejected, status} -> alarm("intake refused the request: #{status}")
  # Transient — worth trying again.
  {:server_error, _status} -> :ok
  {:transport_error, _reason} -> :ok
end
```

`{:server_error, status}` also covers a 2xx the SDK cannot read an access
token out of — an undecodable body, or one carrying no `token` or no
`base_url`. The status is the real one intake sent; *why* a 2xx was unusable
is in the log line rather than in the return value.

Classification is on the HTTP status alone; the body never overrides a status
that was actually received. A 401 whose body is not JSON — which is what a
proxy or gateway in front of intake answers — is still `:credential_rejected`.
`{:transport_error, reason}` means no HTTP status was obtained at all.
`last_failure/1` records only what intake's answer (or its absence) says:
`:missing_credentials` and `{:unexpected, _}` are answered by `header/1` and
`token_result/1` but never recorded, and do not drop a held token.

A successful mint clears the record, and only the 64 most recently failed
URLs are held — ask about a URL you just called and it will be there.

`EndPointBlank.Commands.GenerateAccessToken.generate_result/1`
is the same distinction one layer down, for callers that mint directly:
`{:ok, payload}` or `{:error, reason}` with the same reasons.
`generate/1` still answers payload-or-`nil`.

### Request/response/log reporting

`EndPointBlank.Plug.ReportInteraction` reports every request/response pair
and any unhandled exception. Place it early in your endpoint, before routing:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  plug EndPointBlank.Plug.ReportInteraction
  plug MyAppWeb.Router
end
```

It generates a per-request UUID (`EndPointBlank.RequestStore`), writes the
request immediately via `EndPointBlank.Writers.RequestWriter`, registers a
`before_send` callback that writes the response via
`EndPointBlank.Writers.ResponseWriter`, and — for any exception that
propagates up (other than `EndPointBlank.UnauthorizedError`) — reports it via
`EndPointBlank.Writers.ExceptionWriter` before re-raising, so your normal
error handling / `Plug.ErrorHandler` still runs.

Request and response bodies are JSON-encoded and truncated to 1024 bytes
before being sent.

For structured application logs, call `EndPointBlank.Writers.LogWriter`
directly from anywhere in your app (it picks up the current request's UUID
from `RequestStore` automatically, if any):

```elixir
EndPointBlank.Writers.LogWriter.info("Fetching books list")
EndPointBlank.Writers.LogWriter.warn("Slow query", %{duration_ms: 820})
EndPointBlank.Writers.LogWriter.error("Payment provider timeout", %{provider: "stripe"})
EndPointBlank.Writers.LogWriter.fatal("Out of retries", %{job_id: job.id})
```

All four writers (`RequestWriter`, `ResponseWriter`, `ExceptionWriter`,
`LogWriter`) dispatch through `EndPointBlank.Writers`, honoring `:log_mode`:

- `:direct` (default) — sends synchronously via `EndPointBlank.Writers.DirectWriter`.
- `:delayed` — enqueues onto `EndPointBlank.Writers.DelayedWriter`, a
  `GenServer` that batches up to 4 payloads per flush, per endpoint key, and
  flushes once a second. Each key's queue is capped at 1,000 payloads; under a
  sustained intake outage the oldest payloads for that key are dropped (and a
  warning logged) rather than growing memory unbounded.

  A batch that fails costs that batch and nothing more. Every way a flush can
  fail — a raise anywhere under `DirectWriter.write/2`, or a `GenServer.call`
  timeout that exits its caller — is caught, logged at `error` level once per
  failing flush (with a running count of consecutive failures), and backed off:
  the flush interval doubles from 1 s up to a 30 s ceiling while failures
  continue, and resets on the first clean flush. Telemetry delivery can degrade;
  it cannot take your application's supervision tree with it.

All outbound HTTP goes through `EndPointBlank.Http.post/3`, which retries up
to 3 times (200 ms apart) on network error, with a 3 s connect timeout and a
5 s receive timeout per attempt, so a hung intake can never block the caller
indefinitely.

### Endpoint registration (Phoenix)

Register your Phoenix router's endpoints (and any per-action version
metadata) with EndPointBlank at application startup:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    EndPointBlank.configure(client_id: "...", client_secret: "...", app_name: "my-app")
    EndPointBlank.Phoenix.EndpointRegistrar.register(MyAppWeb.Router)

    children = [MyAppWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

Declare per-action version metadata on a controller with
`EndPointBlank.Phoenix.Versioned`:

```elixir
defmodule MyAppWeb.BooksController do
  use Phoenix.Controller
  use EndPointBlank.Phoenix.Versioned

  version_of :index, ["v1", "v2"]
  version_of :index, ["v0"]

  def index(conn, _params), do: ...
end
```

`version_of/2` takes an action and the list of versions it serves; repeated
calls for the same action merge, deduplicated, in declaration order. Lifecycle
state (Current, Deprecated, ...) is **not** declared in code — it is managed in
the EndPointBlank portal, so changing it does not require a deploy.

`EndpointRegistrar.register/1` introspects `router.__routes__/0`, merges in
any `version_of` metadata, and POSTs the versioned endpoints (path, HTTP
method, and the list of versions) to `<base_url>/api/application_updates`,
alongside the app name, hostname, environment and application version. Routes
whose action has no `version_of` declaration are not registered.

### Data masking

Mask sensitive data **before it leaves your app**. Configure an ordered list
of rules; each rule targets one field and masks by a JSONPath, a regex, or
both. (Server-side intake also masks independently, so this is defense in
depth.)

```elixir
EndPointBlank.configure(
  masking_rules: [
    # Replace any "ssn" field at any depth in the request body.
    %{target: "request_body", path: "$..ssn", replacement_value: "***"},
    # Keep first/last 4 of a card number in error messages via backreferences.
    %{target: "error_message", regex: "(\\d{4})-\\d{4}-\\d{4}-(\\d{4})", replacement_value: "$1-****-****-$2"}
  ],
  # Optional: runs after the rules; last chance to transform the payload.
  mask_hook: fn payload, record_type -> payload end
)
```

Rules are maps with atom keys.

**Rule fields**

- `target` — exactly one of `"request_body"`, `"request_headers"`, `"path"`, `"response_body"`, `"error_message"`.
- `path` — an optional JSONPath (supported subset: `$`, `.name`, `['name']`, `[n]`, `.*` / `[*]`,
  and `..name` for recursive descent). Keys are case-sensitive.
- `regex` — an optional regular expression.
- `replacement_value` — the replacement string (default `"..."`).

**Semantics — path scopes, regex matches within.** With only a `path`, the selected node is replaced
entirely. With only a `regex`, every matching string is replaced. With both, the regex is applied
only within the path-selected node(s). When a `regex` is present, `replacement_value` supports
backreferences: `$1`, `$2`, … insert capture groups (`$0` the whole match; `$$` for a literal `$`).
Stacktraces and log messages are never masked.

A bad regex or an unparseable path makes that rule a no-op rather than raising — masking never
breaks the request it's protecting.

**Credential and cookie headers are never sent.** Before any rule runs,
`RequestWriter` drops `authorization`, `proxy-authorization` and `cookie`
from the request record, and `ResponseWriter` drops `set-cookie` from the
response record, whatever their letter case. They are left out of the record,
not masked, so no rule or `mask_hook` is needed for them and none can bring
them back. The list is `EndPointBlank.Writers.sensitive_headers/0`.

## Management API

`EndPointBlank.Management` is a client for the organization management API
(`/api/v1`): your organization, API packages, clients and what they hold,
applications, environments, runtime credentials and managed clients. Use it
to automate what you would otherwise do in the portal.

It is separate from everything above. It reads none of the
`EndPointBlank.configure/1` settings, and it never sends your runtime
`client_id`/`client_secret`: its only credential is a **management key**
(`epb_mk_...`, created in the portal), sent as `Authorization: Bearer` to
`https://app.endpointblank.com` (or the `:base_url` you give it). Keep the key
out of logs; `inspect/1` of the client leaves it out.

### Quickstart

```elixir
alias EndPointBlank.Management
alias EndPointBlank.Management.{ApiPackages, ClientPackages, Clients, Credentials, Error}

mgmt = Management.new(key: System.fetch_env!("EPB_MGMT_KEY"))

{:ok, organization} = Management.Organization.get(mgmt)

# One page (limit 1..100, default 50), then every client, a page at a time.
{:ok, %Management.Page{data: clients, next_cursor: cursor}} = Clients.list(mgmt, limit: 20)

Clients.stream(mgmt)
|> Stream.filter(&(&1["status"] == "pending"))
|> Enum.each(&IO.puts(&1["name"]))

# Invite a client (the source organization that calls your API) and assign a package.
{:ok, package} = ApiPackages.create(mgmt, %{name: "Partner API"})

{:ok, client} =
  Clients.create(mgmt, %{
    name: "Acme",
    contacts: [%{email: "dev@acme.example", first_name: "Ada", last_name: "Lovelace"}]
  })

# Send client["invite_code"] to Acme; it accepts from its own organization.
{:ok, _assignment} =
  ClientPackages.create(mgmt, client["id"], %{
    api_package_id: package["id"],
    environment_id: production_environment_id
  })

# Issue a runtime credential for one of your application environments, then
# rotate it. client_secret is in these two answers only: store it now.
{:ok, credential} = Credentials.create(mgmt, %{application_environment_id: app_env_id})
store_secret(credential["client_id"], credential["client_secret"])

{:ok, rotated} = Credentials.rotate(mgmt, credential["id"])
store_secret(rotated["client_id"], rotated["client_secret"])
```

Every call answers `{:ok, data}` or `{:error, %EndPointBlank.Management.Error{}}`
and never raises (the `stream` functions raise the error, since a stream
cannot answer a tuple). `data` is the API's JSON with string keys.

### Errors

Match on `code`, which is stable; `message` is for people. `details` holds
field errors for `validation_failed`, and `status` the HTTP status. A code the
SDK does not know yet still arrives as given
(`Error.known_codes/0` lists the documented ones).

```elixir
case ClientPackages.create(mgmt, client_id, attrs) do
  {:ok, assignment} -> {:ok, assignment}
  {:error, %Error{code: "already_assigned"}} -> :ok
  {:error, %Error{code: "nothing_published_in_environment", message: message}} -> {:error, message}
  {:error, %Error{code: "validation_failed", details: details}} -> {:error, details}
  {:error, %Error{code: "plan_limit"}} -> {:error, :upgrade_plan}
  {:error, %Error{} = error} -> {:error, Exception.message(error)}
end
```

### Retries and idempotency

Every POST carries an `Idempotency-Key`, a random UUID unless you pass
`idempotency_key:` (for example to make a job that may run twice create one
client, not two). The client retries a call at most `:max_retries` times
(default 2, `0` turns it off), with the same key:

- `429 rate_limited`, after its `Retry-After` seconds (up to
  `:max_retry_wait_ms`, default 60 s);
- `409 idempotency_request_in_progress`;
- a 5xx answer (`intake_unavailable`, `audit_unavailable`,
  `internal_server_error`, ...) or no answer at all, for GET, DELETE and POST.
  A PATCH is never retried for these.

`409 idempotency_replay_unavailable` is never retried: the first create or
rotate succeeded but its secret cannot be shown again. Get or list the
credential, and rotate it if the secret was lost.

### Managed clients

A managed client is a client organization you create and run for your
customer until they claim it. `Management.for_managed_client/2` gives a client
whose `Applications`, `ApplicationEnvironments`, `Environments` and
`Credentials` calls act on that organization (`/api/v1/clients/:client_id/...`).

```elixir
# `owner_email` (optional) names the person at your customer who will own it;
# change it later with `Clients.update/3`.
{:ok, managed} =
  Clients.create(mgmt, %{
    name: "Customer Co",
    managed: true,
    owner_email: "owner@customer.example"
  })
customer = Management.for_managed_client(mgmt, managed["id"])

# An environment needs a name and a domain; an application needs a base URL in
# at least one environment, and is placed in each one it is given.
{:ok, env} =
  Management.Environments.create(customer, %{name: "staging", domain: "staging.customer.example"})

{:ok, app} =
  Management.Applications.create(customer, %{
    name: "orders",
    environment_base_urls: %{env["id"] => "https://orders.staging.customer.example"}
  })

{:ok, %Management.Page{data: [app_env | _]}} =
  Management.ApplicationEnvironments.list(customer, app["id"])

{:ok, credential} = Credentials.create(customer, %{application_environment_id: app_env["id"]})

# Hand it over: the first person to accept becomes its owner, and its
# credentials are rotated. `return_to:` (optional) is where their browser lands
# after accepting; it must be a URL your organization registered as a claim
# return URL in EndPointBlank, or the call is refused with 422
# `return_to_not_registered`.
{:ok, _invite} =
  Management.ManagedClients.claim_invite(mgmt, managed["id"], "owner@customer.example",
    return_to: "https://app.example.com/onboarding/done"
  )
```

The integration test (`test/end_point_blank/management_integration_test.exs`)
runs this flow against a real app_portal when `EPB_MGMT_BASE_URL` and
`EPB_MGMT_KEY` are set, and is skipped otherwise.

## Framework integration

The SDK ships two `Plug` modules and a Phoenix-only registrar/versioning
pair; nothing requires Phoenix specifically except
`EndPointBlank.Phoenix.RoutePatternFinder`, `EndPointBlank.Phoenix.Versioned`,
and `EndPointBlank.Phoenix.EndpointRegistrar` (any plain-`Plug` app can still
use `Plug.Authorized` / `Plug.ReportInteraction`, just without route-pattern
resolution or endpoint registration).

Full endpoint wiring:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # ... session, static, etc. ...

  plug EndPointBlank.Plug.ReportInteraction
  plug MyAppWeb.Router
end
```

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug EndPointBlank.Plug.Authorized
  end

  scope "/api", MyAppWeb do
    pipe_through :api
    resources "/books", BooksController
  end
end
```

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    EndPointBlank.configure(
      client_id: System.fetch_env!("ENDPOINTBLANK_CLIENT_ID"),
      client_secret: System.fetch_env!("ENDPOINTBLANK_CLIENT_SECRET"),
      app_name: "my-app",
      environment: Application.get_env(:my_app, :environment)
    )

    EndPointBlank.Phoenix.EndpointRegistrar.register(MyAppWeb.Router)

    children = [MyAppWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

## Development

```bash
mix deps.get
mix test
mix compile --warnings-as-errors
```

Layout:

```
lib/end_point_blank.ex                    # configure/1, version/0
lib/end_point_blank/config.ex             # settings + ENDPOINTBLANK_* env fallback
lib/end_point_blank/authorization.ex      # Authorization header builder (Bearer-only for providers)
lib/end_point_blank/token_unavailable_error.ex # raised by Authorization.header!/1
lib/end_point_blank/configuration_error.ex # raised by Authorization.header!/1 when a credential is missing
lib/end_point_blank/auth_cache.ex         # ETS-backed authorization result cache
lib/end_point_blank/access_tokens.ex      # per-application-environment access-token cache, keyed on base URL
lib/end_point_blank/request_store.ex      # per-process request-scoped state
lib/end_point_blank/version_finder.ex     # API-version detection from a conn
lib/end_point_blank/masking.ex            # + masking/json_path.ex
lib/end_point_blank/http.ex               # shared HTTP client w/ retries + timeouts
lib/end_point_blank/commands/            # EndpointAuthorize, EndpointUpdate, GenerateAccessToken
lib/end_point_blank/writers/             # Direct/Delayed writers + Request/Response/Log/ExceptionWriter
lib/end_point_blank/plug/                # Authorized, ReportInteraction
lib/end_point_blank/phoenix/             # EndpointRegistrar, Versioned, RoutePatternFinder
lib/end_point_blank/management.ex         # management API client (Bearer epb_mk_ key, /api/v1)
lib/end_point_blank/management/          # one module per resource, Error, Page, Request
test/                                     # ExUnit test suite
```

`mix docs` (via `ex_doc`, dev-only dependency) builds API reference docs into `doc/`.

## License

Proprietary. See `mix.exs` (`LicenseRef-Proprietary`).

## Links

- Source: https://github.com/EndPointBlank/end_point_blank_elixir
