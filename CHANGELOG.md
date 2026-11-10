# Changelog

## 0.3.4

### Added

- `GitboyDeviceFlow.poll(deviceCode:currentInterval:)` is public, for an app
  that runs its own poll loop: a `slow_down` without an interval adds 5
  seconds to the interval it passes.

## 0.3.3

### Changed

- **Minimum platforms are iOS 16 and macOS 13** (were iOS 17 and macOS 14).
  Nothing in ForgeKit needed the newer ones, so an app no longer has to drop
  iOS 16 to use it. CI now builds the package for an iOS 16 device.

### Upgrading from 0.3.2

- Only the pin changes.

## 0.3.2

### Changed

- **Sign-in failures about the address have their own type,
  `GitboySignInError`**, so an app can tell them apart without matching text:
  `.notGitboyServer`, `.approvalPageElsewhere(URL)` (its message names the
  host it was sent to) and `.responseTooLarge`. In 0.3.1 the first two were
  `ForgeError.validation` strings and the third was `.invalidResponse`.
- **RFC 8628 intervals.** A device-code answer without `interval` means 5
  seconds, and `slow_down` without an interval adds 5 seconds to the one in
  use instead of resetting it to 5.
- **OAuth error sentences.** An error body's `error_description` is the
  message shown when there is one; `error` is only its code word.
- **A log stream the server closes on its time limit is picked up again.**
  A `done` with status `timeout` reconnects from the last byte read instead of
  ending the log as if the job had finished.
- `GitboyDeviceFlow.responseLimit` is public.

### Upgrading from 0.3.1

- Code that matched the two sign-in sentences, or caught them as
  `ForgeError`, catches `GitboySignInError` instead. Code that shows
  `error.localizedDescription` needs no change.

## 0.3.1

### Changed

- **gitboy sign-in checks where it is sending you.** `requestCode()` refuses
  an approval page that is not on the instance itself (https, same host and
  port, no credentials in the link), for both the page and its short link.
- **Sign-in answers are read up to 64 KiB.** The code and poll requests go to
  an address a person typed, before anything says it is a gitboy server, so a
  larger answer is refused rather than read into memory.
- **A wrong address is reported as one.** A 404, a 405, or an answer that is
  not gitboy's on `requestCode()` now says the address doesn't answer like a
  gitboy server, instead of "not found" or an unreadable response. Throttling
  (429) and server errors (5xx) keep their own cases.

### Upgrading from 0.3.0

- Only the pin changes. No API was added, removed or renamed.

## 0.3.0

### Added

- **Start a run.** `workflows(in:ref:)` lists what a person can start in a
  repository and `start(_:ref:inputs:)` starts it on a branch or tag. On
  gitboy that is the repository's own pipeline and its Actions workflows that
  accept a manual start, with the inputs they declare; on GitHub, the
  workflows that are not disabled. gitboy answers with the new run; GitHub
  accepts the request and the run appears in the list a moment later.
- **Merge when green.** `enableAutoMerge(_:method:expectedHeadSHA:)` and
  `disableAutoMerge(_:)` queue a merge for when checks and reviews allow it
  and take it back. `ForgePullRequestDetail.autoMerge` says whether one is
  queued, by whom and how.
- **`updateBranch(of:expectedHeadSHA:)`** brings a pull request up to date
  with its base, and **`markReady(_:)`** takes it out of draft.
- Capability flags for each: `.startRuns`, `.autoMerge`, `.updateBranch`,
  `.markReady`.

### Changed

- **New GitHub requests no longer break an app's own transport.** They are
  separate protocols, `GitHubWorkflowTransport` and
  `GitHubPullAutomationTransport`. `GitHubHTTPTransport` conforms to both. A
  transport that does not keeps compiling, and `GitHubForge.capabilities`
  leaves out what it cannot do.

### Upgrading from 0.2.0

- Nothing is required: every new `Forge` method has a default that refuses,
  and `GitHubTransport` has no new requirements.
- A `Forge` conformer that answers with the `.github` or `.gitboy` preset now
  also claims `.startRuns`, `.autoMerge`, `.updateBranch` and `.markReady`.
  Implement them or subtract the flags.
- gitboy queues a merge or a squash, not a rebase; asking for a rebase is
  refused before any request is made.

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
