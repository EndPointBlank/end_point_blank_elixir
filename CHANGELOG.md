# Changelog

## Unreleased

### Added

- `EndPointBlank.Commands.GenerateAccessToken.generate_result/1`, returning
  `{:ok, payload}` or `{:error, reason}` so a caller can tell a rejected
  credential from a failed intake. Reasons are `:credential_rejected` (401 —
  permanent until the credential is re-issued), `{:request_rejected, status}`
  (any other 4xx — also permanent, but the remedy is the request or the
  registration), `{:server_error, status}` (5xx) and
  `{:transport_error, reason}` (both transient).
- `EndPointBlank.AccessTokens.last_failure/1`, reporting the last failure
  recorded for a URL — the same reasons plus `{:invalid_response, reason}` for
  a 2xx this cache cannot store. A successful mint clears the record.
- A distinct, loud log line when intake rejects the credential, instead of the
  generic "Failed to generate access token" that reads as an outage.

### Changed

- Nothing removed or renamed. `GenerateAccessToken.generate/1`,
  `AccessTokens.token/1` and `AccessTokens.exists?/1` keep their exact return
  contracts (payload-or-`nil`, token-or-`nil`, boolean) and their existing log
  lines; `generate/1` is now a thin wrapper over `generate_result/1`.

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
