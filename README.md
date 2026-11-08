# ForgeKit

ForgeKit is the shared forge layer for the Phren iOS app and gitboy iOS. It
speaks one `Forge` protocol to two hosts:

- **GitHub**, through a small `GitHubTransport` (ForgeKit ships
  `GitHubHTTPTransport`, a URLSession implementation with bearer auth and
  origin-pinned redirects).
- **gitboy**, through `GitboyClient`, including device-flow sign-in, issues,
  pull requests, pipelines, job logs (SSE and polling) and runners.

It was extracted from `PhrenKit/Sources/PhrenKit/Forge/` in phren-apps. The
public type names, initializers and methods are unchanged, so PhrenKit call
sites keep compiling once `GitHubClient` conforms to `GitHubTransport`. See
[`PHRENKIT_ADAPTER.md`](PHRENKIT_ADAPTER.md) for the exact phren-apps changes.

ForgeKit depends on Foundation only. On Apple platforms it uses Security for
the gitboy credential Keychain; elsewhere it falls back to an in-memory store
for tests.

## Who uses it

- **Phren iOS** (phren-apps): depends on an exact version and conforms its
  existing `GitHubClient` to `GitHubTransport`.
- **gitboy iOS**: depends on the same exact version and uses ForgeKit's
  `GitboyClient` and forge models directly.

## Pin an exact version

Add the package with an exact version, not a range:

```swift
.package(url: "https://github.com/alaarab/forgekit.git", exact: "0.1.0")
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
Tests/ForgeKitTests/    forge tests, ported from PhrenKit
kotlin/                 placeholder for the Phase 3 Kotlin module
```

`AgentSendLink.swift` intentionally stays in PhrenKit: it depends on
`WorktreeBranch`, which is not part of the forge layer.

## Build and test

```sh
swift build
swift test
```

The package supports iOS 17 and macOS 14.
