# Changelog

## 0.2.0

### Added

- **GitHub failures as `ForgeError`.** `GitHubForge` now throws `ForgeError`
  for everything GitHub answers, so a screen written against `ForgeError`
  handles either host. `ForgeError(_: GitHubError)` is public for an app's own
  GitHub calls. A transport's `GitHubError` is still what a transport throws.
- **Capability flags** for what screens used to decide by asking which host
  they were on: `.pullRequests`, `.cancelJob`, `.playJob`, `.accountRunners`,
  `.pullComments`, `.pullDiffs`, `.agentSessions`.
- **Pull request conversation and diff** on both hosts:
  `comments(on:)`, `comment(on:body:)` and `diff(of:)` for a `ForgePullRequest`.
- **Agent sessions** on gitboy: `computers()`, `agentSessions(on:)`,
  `myAgentSessions()`, `startAgentSession(on:computer:harness:)` and
  `cancel(_:)`, with `ForgeComputer`, `ForgeAgentSession` and
  `ForgeAgentStatus`. `computers()` reads `agent_harnesses` from the runner
  list, which gitboy's `GET /api/v1/user/runners` does not send yet
  (2026-11-09); it answers an empty list until the server does.
- **`GitboyClient.tokenInfo()`**: the scopes and expiry of the token in use,
  so a pasted token no longer has to be saved with no scopes.
- **App-neutral sign-in and storage.** `GitboyDeviceFlow` takes `clientName`
  and `scopes`; `ForgeKeychainCredentialStore` takes a Keychain `service`.
  The defaults are Phren for iPhone's, so its saved credentials still load.
- **`GitHubHTTPTransport` is a base an app can build on.** `request`, `get`,
  `ensureOK`, `encodePath`, `repoPath` and `rateLimitError` are public;
  `request` takes an `etagKey` for conditional requests; `init` takes a
  `preflight` closure that can refuse a request before it is sent.
- **Linux build and CI.** The package builds and tests on Linux, and every
  push and pull request runs the tests on macOS and Linux.

### Changed

- Shared error wording names neither gitboy nor Phren: "You're not signed in
  to this host.", "Your token needs the … scope.", "The forge sent a response
  this app couldn't read."
- A GitHub repository search reads past pages with no match (up to five per
  call) instead of answering an empty page that still offers more.
- A gitboy live log that ends because access was revoked, or because the job
  was deleted, now ends with `ForgeError.unauthorized` or `.notFound`, not
  with a finished job in the "queued" state.
- `Forge.liveLog(of:)` is documented as it behaves on a host without live
  logs: nothing while the job runs, then the whole log once.

### Upgrading from 0.1.0

- **`GitHubTransport` has one new requirement**, `pullDiff(owner:repo:number:)`.
  An app that conforms its own client adds that method; see
  `PHRENKIT_ADAPTER.md`.
- **Code that catches `GitHubError` from a `GitHubForge` call** now receives
  `ForgeError`. Calls made on the app's own GitHub client are unchanged. A
  404 on a repository path arrives as `.unauthorized` carrying GitHub's
  explanation of token access, as the screens showed before; a GitHub 403
  is `.unauthorized` too, never `.missingScope`.
- **A `Forge` conformer that answers with the `.github` or `.gitboy` preset**
  now claims `.pullComments`, `.pullDiffs` and `.agentSessions`. Implement
  them or subtract the flags.
- New `Forge` methods have default implementations that refuse, so an app's
  own `Forge` conformer (a fixture, a fake) keeps compiling. Check
  `capabilities` before offering the control.
- Tests that assert the old error wording need the new sentences.

## 0.1.0

The forge layer extracted from PhrenKit: the `Forge` protocol over GitHub and
gitboy, gitboy device-flow sign-in, and the Keychain credential store.
