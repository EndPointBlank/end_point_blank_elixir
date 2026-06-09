# EndPointBlank (Elixir)

EndPointBlank client for Elixir / Phoenix.

## Configure

```elixir
EndPointBlank.configure(
  client_id: "...",
  client_secret: "...",
  app_name: "my-app",
  environment: "production"
)
```

## Masking

Mask sensitive data **before it leaves your app**. Configure an ordered list of rules; each rule
targets one field and masks by a JSONPath, a regex, or both. (Server-side intake also masks
independently, so this is defense in depth.)

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
