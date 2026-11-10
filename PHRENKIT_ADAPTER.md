# Adopting ForgeKit in phren-apps (PhrenKit)

ForgeKit is the forge layer that used to live in
`apps/ios/PhrenKit/Sources/PhrenKit/Forge/`. This is the exact list of changes
PhrenKit needs to depend on it. The goal is no copy of the forge layer left in
PhrenKit and no duplicate public type names.

## 1. Add the package dependency

In `apps/ios/PhrenKit/Package.swift` (or the Xcode project's package
references), pin an exact version:

```swift
dependencies: [
    .package(url: "https://github.com/alaarab/forgekit.git", exact: "0.1.0"),
],
targets: [
    .target(
        name: "PhrenKit",
        dependencies: [
            .product(name: "ForgeKit", package: "forgekit"),
        ]
    ),
]
```

Never use a branch or a local path for a shipping app. A version bump is its
own PR in phren-apps.

## 2. Delete the moved files

Delete every file in `Sources/PhrenKit/Forge/` **except**
`AgentSendLink.swift`. That file stays in PhrenKit because it depends on
`WorktreeBranch`. Add `import ForgeKit` to it; it uses `ForgeHost`,
`ForgeRepo`, `ForgeIssueDetail`, `ForgeKind` and friends, all unchanged.

The moved files are:

```
Forge.swift
ForgeCredential.swift
ForgeIssues.swift
ForgePulls.swift
ForgeRunners.swift
ForgeRuns.swift
ForgeSSE.swift
GitboyClient.swift
GitboyClient+Issues.swift
GitboyClient+Pulls.swift
GitboyClient+Runs.swift
GitboyClient+Runners.swift
GitboyDeviceFlow.swift
GitHubForge.swift
GitHubForge+Issues.swift
GitHubForge+Pulls.swift
GitHubForge+Runs.swift
GitHubForge+Runners.swift
```

## 3. Change imports

Any file that used the moved types now needs `import ForgeKit`: the Forge
screens, `AgentSendLink.swift`, and the GitHub client files that name the
shared DTOs or errors (see below). `ForgeHost`, `ForgeRepo`, `ForgeIssue`,
`ForgePullRequest`, `ForgeRun`, `ForgeRunner`, `ForgeError`, `GitboyClient`,
`GitboyDeviceFlow`, `GitHubForge`, `ForgeCredential` and
`ForgeCredentialStore` keep their names, initializers and methods.

## 4. Delete the copied public types

ForgeKit now owns these. Delete PhrenKit's definitions, or the app will have
two public types with the same name and ForgeKit's errors/DTOs will not match
what PhrenKit catches.

- `GitHubError` — delete from `Sources/PhrenKit/GitHub/GitHubModels.swift`.
  ForgeKit's copy is public and identical. `GitHubError.http`,
  `.shaConflict`, `.rateLimited`, `.notAuthenticated`, `.invalidResponse`,
  `.treeTruncated`, `isShaConflict`, `isRepoAccessDenied` and the error wording
  are unchanged.
- `GitHubRedirectPolicy` — delete
  `Sources/PhrenKit/GitHub/GitHubRedirectPolicy.swift`. ForgeKit's copy is
  public. Keep using `GitHubRedirectPolicy.shared` and
  `.allows(_:)` exactly as before. ForgeKit also exports
  `GitHubHTTPSOnlyRedirectPolicy` and `GitHubLogURL`, so PhrenKit's job-log
  code can use those too.
- `GitHubUser` and `GitHubRepo` — delete from
  `Sources/PhrenKit/GitHub/GitHubModels.swift`; ForgeKit's copies carry the
  same fields and public memberwise initializers (`GitHubUser(login:name:
  avatarUrl:)`, `GitHubRepo(id:fullName:name:owner:isPrivate:defaultBranch:
  pushedAt:permissions:)`, `GitHubRepo.Owner(login:)` and
  `GitHubRepo.Permissions(push:)`), so `GitHubReposTests` and
  `SessionRecoveryTests` keep compiling unchanged. Keep `GitRef`, `GitTree`,
  `GitBlob`, `ContentsPutResponse` and `DeviceCodeResponse` in PhrenKit; they
  are not part of the forge layer.
- GitHub wire DTOs — delete these definitions from PhrenKit and use
  ForgeKit's public copies:
  - `GitHubClient+Issues.swift`: `GitHubIssueDTO`,
    `GitHubIssueCommentDTO`
  - `GitHubClient+Pulls.swift`: `GitHubPullDTO`, `GitHubPullActor`,
    `GitHubPullBranchRef`, `GitHubPullReviewDTO`, `GitHubCheckRunDTO`
  - `GitHubClient+Actions.swift`: `GitHubRunDTO`, `GitHubJobDTO`
  - `GitHubClient+Runners.swift`: `GitHubRunnerDTO`

  Keep PhrenKit's page wrappers (`GitHubIssueSearchPage`,
  `GitHubCheckRunsPage`, `GitHubRunsPage`, `GitHubJobsPage`,
  `GitHubRunnersPage`) and any label helper; they are private to the client
  and can refer to ForgeKit's DTOs. If you keep `GitHubRunnerLabelDTO`, keep it
  internal.

`ISO8601Dates` is **not** exported by ForgeKit (its parser is internal), so
PhrenKit keeps its own `Sessions/ISO8601Dates.swift` unchanged.

### Symbols that stay public for PhrenKit

These are used by PhrenKit code or tests that stay in the app. Keep them in
your call sites and do not delete the tests that exercise them:

- `ForgeHost.isValidHost(_:)` — public static; `AgentSendLink.swift` calls it
  to validate the bare host it parsed from an `agent-send://` URL.
- `GitHubError.repoSlug(from:)` — public static;
  `PhrenKitTests/GitHubClientTests.swift` asserts the path classification
  directly (lines 163–164). It is also what `errorDescription` uses.
- `GitHubUser(login:name:avatarUrl:)`,
  `GitHubRepo(id:fullName:name:owner:isPrivate:defaultBranch:pushedAt:
  permissions:)`, `GitHubRepo.Owner(login:)` and
  `GitHubRepo.Permissions(push:)` — public memberwise initializers;
  `GitHubReposTests.swift:91` and `SessionRecoveryTests.swift:396` construct
  these. The synthesized parameter labels and order are unchanged.

All other `Forge*` models already had public initializers in PhrenKit and keep
them in ForgeKit.

## 5. Conform GitHubClient to GitHubTransport

ForgeKit's `GitHubForge` now takes `any GitHubTransport`:

```swift
public struct GitHubForge: Forge {
    public init(client: any GitHubTransport)
}
```

`GitHubClient` should satisfy that protocol with its existing methods. Make
the witness methods `public` (they are currently internal) in:

- `GitHubClient.swift`: `currentUser()`, `listRepos(page:perPage:)`
- `GitHubClient+Issues.swift`: `listIssues`, `searchIssues`, `issue`,
  `issueComments`, `createIssue`, `createIssueComment`, `setIssueState`
- `GitHubClient+Pulls.swift`: `listPulls`, `pull`, `pullReviews`,
  `checkRuns`, `mergePull`, `submitPullReview`
- `GitHubClient+Actions.swift`: `workflowRuns`, `workflowRun`,
  `workflowRunJobs`, `rerunRun`, `rerunFailedJobs`, `cancelRun`, `rerunJob`,
  `jobLog`
- `GitHubClient+Runners.swift`: `runners(scope:)`,
  `removeRunner(scope:runnerID:)`

Then the exact extension is empty, because the methods already have the
required names, labels, argument types and return types:

```swift
import ForgeKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension GitHubClient: GitHubTransport {}
```

The protocol's requirements are all `async`; an actor's isolated methods can
witness them, so no `nonisolated` wrappers are needed. `request`,
`encodePath`, `repoPath`, `ensureOK` and the page wrappers stay internal.

Call sites do not change:

```swift
GitHubForge(client: githubClient)
```

## 6. Keychain and saved credentials

ForgeKit's `ForgeCredentialStore` keeps the existing storage contract:
generic password, service `com.phren.ios.forge`, account = `host.id`,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Credentials saved by the
old PhrenKit code load without migration.

The static API is unchanged:

```swift
try ForgeCredentialStore.save(credential)
let result = ForgeCredentialStore.read(host)   // .found/.missing/.locked/.unavailable/.invalidData
try ForgeCredentialStore.delete(host)
let hosts = ForgeCredentialStore.storedHosts()
```

For testability, ForgeKit also publishes `ForgeCredentialStoring` and
`ForgeKeychainCredentialStore` (the default Security implementation). The
static `ForgeCredentialStore` façade is what the app calls; use the protocol
only if you want to inject fake storage.

GitHub tokens are untouched: they remain in PhrenKit's `KeychainStore` with
service `com.phren.ios.github`. ForgeKit does not read or write that item.

## 7. Errors

ForgeKit's `ForgeError` replaces every use of `PhrenKitError` inside the forge
layer. It has the existing cases plus one new case:

```swift
case validation(String)   // local validation or Keychain failure
```

If PhrenKit has an exhaustive `switch` over `ForgeError`, add `.validation`
(or a `default`). The gitboy `ForgeError` cases and their
`errorDescription` wording are otherwise unchanged.

`GitHubError` is ForgeKit's copy (see step 4); its cases and wording are
unchanged.

## 8. Demo mode

PhrenKit's `DemoGate` was an app-level check called by `GitHubClient` and by
the gitboy transport. ForgeKit has no dependency on `DemoGate`:

- PhrenKit's own `GitHubClient` still calls `DemoGate.check()` in its
  `request` method, so GitHub requests keep the demo refusal.
- ForgeKit's `GitboyClient` no longer calls `DemoGate`. If Phren still needs
  gitboy requests to refuse in demo mode, gate at the screen/service layer
  that owns the demo switch, or wrap `GitboyClient` behind a PhrenKit façade
  that checks `DemoGate` first. Do not add a `DemoGate` dependency back into
  ForgeKit.

## 9. Tests

PhrenKit's forge tests move with ForgeKit and are deleted from PhrenKit:
`ForgeTests.swift`, `ForgeIssuesTests.swift`, `ForgePullsTests.swift`,
`ForgeRunsTests.swift`, `ForgeGitHubRunsTests.swift`,
`ForgeRunnersTests.swift`. The `StubURLProtocol` helper they used lived in
`GitHubClientTests.swift`; ForgeKit carries its own copy in
`Tests/ForgeKitTests/TestSupport.swift`, so PhrenKit's
`GitHubClientTests.swift` keeps its version for the client tests that stayed.

---

# Moving phren-apps from 0.1.0 to 0.2.0

Everything above describes the 0.1.0 adoption, which is done. These are the
changes the 0.2.0 version bump needs, in its own pull request.

## Required

1. **Bump the pin** to `exact: "0.2.0"` in `PhrenKit/Package.swift`,
   `PhrenLive/Package.swift` and `project.yml`.

2. **Add `pullDiff` to `GitHubClient`.** `GitHubTransport` has one new
   requirement. In `GitHubClient+Pulls.swift`:

   ```swift
   public func pullDiff(owner: String, repo: String, number: Int) async throws -> String {
       let path = try Self.repoPath(owner: owner, repo: repo) + "/pulls/\(number)"
       let (data, http) = try await request(path, accept: "application/vnd.github.diff")
       try Self.ensureOK(http, data: data, path: path)
       return String(decoding: data, as: UTF8.self)
   }
   ```

3. **Error wording in tests.** Any test that asserts "You're not signed in to
   this gitboy host." or "Your gitboy token needs the … scope." needs the new
   sentences (`Forge.swift`, `ForgeError.errorDescription`).

Nothing else is required: `FixtureForge` keeps compiling, because every new
`Forge` method has a default implementation.

## What the app can now delete or simplify

- **GitHub errors.** `GitHubForge` throws `ForgeError`, so `ForgeRetryView`'s
  missing-scope and sign-in handling and `ForgeRunnersView.accessSentence` now
  fire on GitHub screens too. The rewrite of 403/404 into `ForgeError` inside
  `GitHubClient+Runners.swift` can stay or go; both paths end in `ForgeError`.
- **Host checks become capability checks.**
  - `ForgeRunDetailView`: job cancel and play are `.cancelJob` and `.playJob`.
  - `ForgeHubView`: the account-wide runners link is `.accountRunners`.
  - `ForgeRepoView`: the pull requests row is `.pullRequests`.
- **Pasted tokens.** `GitboySignInView` saves a pasted token with
  `scopes: []`. Call `GitboyClient.tokenInfo()` after `currentUser()` and save
  its scopes and expiry instead.
- **The second copy of the GitHub client.** `GitHubHTTPTransport` now has
  what `GitHubClient.request` added on top of it: `preflight` (pass
  `{ try DemoGate.check() }`) and `etagKey`. `request`, `get`, `ensureOK`,
  `encodePath` and `repoPath` are public. `GitHubClient` can become an
  extension of `GitHubHTTPTransport` that adds only what ForgeKit does not
  have (`headSha`, `tree`, `blob`, `putFile`, `deleteFile`, `probeStore`, the
  GitHub App installation calls), and the duplicated endpoint files
  (`GitHubClient+Issues/Pulls/Actions/Runners.swift`) can be deleted.

## New screens the layer can now back

- The pull request conversation: `forge.comments(on:)`, `forge.comment(on:body:)`.
- The pull request's changes: `forge.diff(of:)` returns unified diff text.
- Agent sessions on gitboy: `forge.computers()`, `forge.agentSessions(on:)`,
  `forge.startAgentSession(on:computer:harness:)`, `forge.cancel(_:)`,
  `forge.myAgentSessions()`. Gate them on `.agentSessions`.

