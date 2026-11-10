# ForgeKit

ForgeKit is a Swift client for code hosts. It speaks one `Forge` protocol to
two hosts, so one set of screens works against either:

- **GitHub**, through a small `GitHubTransport` (ForgeKit ships
  `GitHubHTTPTransport`, a URLSession implementation with bearer auth and
  origin-pinned redirects).
- **gitboy**, through `GitboyClient`, including device-flow sign-in.

What it covers on both hosts: the signed-in user, repositories, issues, pull
requests (detail, reviews, checks, merge, conversation, diff), CI runs, jobs
and logs, and runners. gitboy adds live logs over SSE, pausing runners, and
agent sessions (sending an issue to an agent on one of your computers).
`forge.capabilities` says what a host can do, so a screen shows or hides a
control instead of asking which host it is on.

It was extracted from `PhrenKit/Sources/PhrenKit/Forge/` in phren-apps. See
[`PHRENKIT_ADAPTER.md`](PHRENKIT_ADAPTER.md) for the phren-apps changes and
[`CHANGELOG.md`](CHANGELOG.md) for what each version changed.

ForgeKit depends on Foundation only. On Apple platforms it uses Security for
the gitboy credential Keychain; elsewhere it falls back to an in-memory store
for tests.

## Who uses it

- **Phren iOS** (phren-apps): depends on an exact version and conforms its
  existing `GitHubClient` to `GitHubTransport`.
- **gitboy iOS** is planned to adopt it and does not yet. An app other than
  Phren passes its own name, scopes and Keychain service; see below.

## Using it from your own app

The defaults are Phren for iPhone's, because its saved credentials must keep
loading. Another app says who it is:

```swift
// The name gitboy shows on its approval page, and the scopes the token needs.
let flow = GitboyDeviceFlow(host: host,
                            clientName: "Example for iPhone",
                            scopes: ["read:user", "read:repo", "write:repo"])

// Its own Keychain service, so two apps never read each other's accounts.
let store = ForgeKeychainCredentialStore(service: "com.example.app.forge")
```

A token pasted by hand carries no scopes or expiry. Ask the host:

```swift
let info = try await GitboyClient(host: host, token: pasted).tokenInfo()
// info?.scopes, info?.expiresAt
```

For GitHub requests ForgeKit does not make (file contents, refs), extend
`GitHubHTTPTransport` and use its public `request` and `get`, so the auth,
redirect and throttling rules exist once.

## Pin an exact version

Add the package with an exact version, not a range:

```swift
.package(url: "https://github.com/alaarab/forgekit.git", exact: "0.2.0")
```

and the target dependency:

```swift
.product(name: "ForgeKit", package: "forgekit")
```

Use `exact:` rather than `from:` or a branch. An app should only move when a
ForgeKit release has been reviewed and its version bump is in that app's own
pull request.

## Version bumps

A ForgeKit version bump lands in its own PR in each app: update the `exact:`
version in `Package.swift`/`Package.resolved`, run that app's tests, and merge
nothing else with it. Never fold a version bump into a feature PR, and never
point an app at a branch or a local checkout.

## Layout

```
Package.swift
Sources/ForgeKit/       forge models, GitHub transport, gitboy client
Tests/ForgeKitTests/    forge tests
.github/workflows/      CI: macOS and Linux
kotlin/                 placeholder for the Phase 3 Kotlin module
```

`AgentSendLink.swift` intentionally stays in PhrenKit: it depends on
`WorktreeBranch`, which is not part of the forge layer.

## Build and test

```sh
swift build
swift test
```

The package supports iOS 17 and macOS 14. It also builds and tests on Linux,
which is what CI's second job runs: there the Keychain is an in-memory store,
a live log is read whole instead of streamed, and the three job-log redirect
tests are skipped. Every push and pull request runs both jobs
(`.github/workflows/ci.yml`).
