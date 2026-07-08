# EndPointBlank (Elixir)

EndPointBlank client for Elixir / Phoenix apps — endpoint tracking and authorization, request/response/error/log reporting, and client-side data masking, all reporting back to the EndPointBlank API.

## Installation

This package is published to a **private** Hex organization (not on the public
`hex.pm` index). Add the dependency and pass your organization at fetch time:

```elixir
def deps do
  [
    {:end_point_blank_elixir, "~> 0.3", organization: "your-hex-org"}
  ]
end
```

Then authenticate the Hex CLI against your org once per machine/CI runner
(`mix hex.organization auth your-hex-org`) before `mix deps.get`.

If you don't have Hex org access yet, depend on the git repo directly:

```elixir
def deps do
  [
    {:end_point_blank_elixir, git: "https://github.com/EndPointBlank/end_point_blank_elixir.git", tag: "v0.3.1"}
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

All settings are held in a singleton `EndPointBlank.Config` agent (started by
`EndPointBlank.Application`), set via `EndPointBlank.configure/1`, and read
back via `EndPointBlank.Config.get/0`. Six of them also fall back to
`ENDPOINTBLANK_*` environment variables so you can run without any
Elixir-side configuration at all (e.g. purely env-driven deployments).

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
| Reserved for future writer pooling; not currently read by any writer | `:worker_count` | — (`configure/1` only) | `4` |
| Authorization-cache TTL in seconds (`EndPointBlank.AuthCache`) | `:cache_ttl` | — (`configure/1` only) | `300` |
| Ordered list of masking rule maps (see [Data masking](#data-masking)) | `:masking_rules` | — (`configure/1` only) | `[]` |

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
  version_finder: fn conn -> Plug.Conn.get_req_header(conn, "x-api-version") |> List.first() end
)
```

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
- Sends `Authorization: Bearer <token>` when a cached access token exists for
  the target host (`EndPointBlank.AccessTokens`), otherwise `Basic
  <client_id:client_secret>` (`EndPointBlank.Authorization`).
- Caches successful authorizations for up to `:cache_ttl` seconds
  (`EndPointBlank.AuthCache`), keyed on the caller's own auth header, path,
  HTTP method, and `app_name` — repeat calls skip the network round trip.
- On a `401` from a Bearer-authenticated call, evicts the stale token and
  retries once with a fresh token (or Basic auth as a last resort).
- Stores the resulting `source_application_environment_id` in
  `EndPointBlank.RequestStore` for the rest of the request lifecycle (it's
  attached to request/response/log/error payloads).

`EndPointBlank.UnauthorizedError` is available for your own code to raise on
authorization failures. `EndPointBlank.Plug.ReportInteraction` (below)
specifically re-raises it *without* sending it to the error-reporting
endpoint, since the authorization flow already reports the denial itself.

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
  `GenServer` that batches up to 4 payloads per flush every 100 ms, per
  endpoint key. Each key's queue is capped at 1,000 payloads; under a
  sustained intake outage the oldest payloads for that key are dropped (and a
  warning logged) rather than growing memory unbounded.

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

  version_of :index, ["v1", "v2"], state: "Current"
  version_of :index, ["v0"],       state: "Deprecated"

  def index(conn, _params), do: ...
end
```

`EndpointRegistrar.register/1` introspects `router.__routes__/0`, merges in
any `version_of` metadata, and POSTs the endpoint list (path, HTTP method,
and `%{state => [versions]}`) to your `base_url`.

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
lib/end_point_blank/authorization.ex      # Authorization header builder
lib/end_point_blank/auth_cache.ex         # ETS-backed authorization result cache
lib/end_point_blank/access_tokens.ex      # per-hostname access-token cache
lib/end_point_blank/request_store.ex      # per-process request-scoped state
lib/end_point_blank/version_finder.ex     # API-version detection from a conn
lib/end_point_blank/masking.ex            # + masking/json_path.ex
lib/end_point_blank/http.ex               # shared HTTP client w/ retries + timeouts
lib/end_point_blank/commands/            # EndpointAuthorize, EndpointUpdate, GenerateAccessToken
lib/end_point_blank/writers/             # Direct/Delayed writers + Request/Response/Log/ExceptionWriter
lib/end_point_blank/plug/                # Authorized, ReportInteraction
lib/end_point_blank/phoenix/             # EndpointRegistrar, Versioned, RoutePatternFinder
test/                                     # ExUnit test suite
```

`mix docs` (via `ex_doc`, dev-only dependency) builds API reference docs into `doc/`.

## License

Proprietary. See `mix.exs` (`LicenseRef-Proprietary`) — this package is published only to a private Hex organization.

## Links

- Source: https://github.com/EndPointBlank/end_point_blank_elixir
