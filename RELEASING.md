# Releasing Microfish

A release is a git tag. Pushing the tag runs `.github/workflows/release.yml`, which builds, signs,
notarizes and publishes everything. Nothing is uploaded by hand.

## Versions

| Tag | Kind | `CFBundleShortVersionString` | `CFBundleVersion` (and `sparkle:version`) |
|---|---|---|---|
| `v0.1.0-beta.1` | beta, GitHub pre-release, appcast channel `beta` | `0.1.0-beta.1` | `10001` |
| `v0.1.0` | stable | `0.1.0` | `10099` |
| `v1.2.3` | stable | `1.2.3` | `1020399` |

Build number = `X*1000000 + Y*10000 + Z*100 + N` for a beta (N is 1 to 98) and `+ 99` for a stable, so a
stable always sorts after its own betas and before the next version's. Y and Z are 0 to 99.
`app/Scripts/version.py` is the one implementation (`python3 app/Scripts/version.py v1.2.3-beta.1`), and
it rejects anything else, so a typo in a tag fails the pipeline instead of publishing something odd.
Sparkle compares build numbers only: **a build number is never reused and never goes down**.

## Branches

- **`main`** is where work lands. Betas are tagged on `main` (or on a `release/X.Y` hotfix branch). The
  gate refuses a beta whose commit is on neither, so a tag on a stray branch or an unmerged pull request
  cannot release.
- **A stable is promoted from a soaked beta.** Once a beta has been used for a while, tag the same
  commit `vX.Y.Z` (no new code between the last beta and the stable). The pipeline refuses a stable tag
  if no `vX.Y.Z-beta.N` exists, and says so when the stable's commit differs from the newest beta's.
- **Hotfixes** for a shipped `X.Y` go on a branch `release/X.Y` cut from that stable's tag. Fix there,
  tag `vX.Y.(Z+1)-beta.1` on the branch, soak, then tag `vX.Y.(Z+1)`. A stable tag must be reachable from
  `main` or from `release/X.Y` of its own minor version; anything else is refused. Merge the fix back
  into `main` too.

## Cutting a beta

1. `main` is green on CI (cargo tests, helper tests, ad-hoc build, signature-tooling tests).
2. Optional but cheap: Actions, Release, "Run workflow", leave `dry_run` ticked, enter the tag you are
   about to push. It builds with an ad-hoc signature, skips notarization and publishing, and uploads
   the zip as an artifact. It runs in the secret-less environment `release-dry-run`.
3. Tag and push:
   ```sh
   git switch main && git pull
   git tag v0.1.0-beta.1
   git push origin v0.1.0-beta.1
   ```
   Push one tag at a time and wait for the run to finish: runs publish one by one, and a run that is
   waiting behind another is replaced if a third arrives (re-run it from the Actions tab).
   If the `release` environment has a required reviewer (below), the **build** job and the **publish**
   job each wait for your approval: Actions, the run, **Review deployments**, tick `release`, **Approve
   and deploy**. Check that the run is for the tag you pushed before approving.
4. Watch Actions, Release. When it is green: the GitHub release `Microfish 0.1.0-beta.1` is a
   pre-release with `Microfish-0.1.0-beta.1.zip`, and `appcast.xml` on the `appcast` branch has the item.
   People with "Get beta updates" on are offered it.

## Promoting a beta to stable

```sh
git fetch --tags
git tag v0.1.0 v0.1.0-beta.3        # same commit as the beta that soaked
git push origin v0.1.0
```
The release is built again from that commit (the zip is not the beta's zip: a stable has its own
version fields), published as the repository's **Latest** release, and added to the appcast without a
channel, so everyone gets it. `allow_unsoaked_stable` in the manual workflow run overrides the
promotion rule once; use it only for a tag that already exists and you have a reason for. A real manual
run must be started from the tag itself: Actions, Release, Run workflow, **Use workflow from: Tags**,
the tag, `dry_run` unticked (the environment's tag rule would refuse a branch anyway).

**"Latest" is only ever the highest stable.** A stable hotfix on an older minor (say `v0.1.2` when
`v0.2.0` is out) is published with `--latest=false`, so it does not take the badge or the README's
`releases/latest` link from `v0.2.0`; a beta never is Latest. The publish job decides this from the
published stables (`version.py is-latest`).

**The first public release should be a stable promoted from a beta.** `releases/latest` is a 404 until a
stable exists, and the README's install link points there. Soak `v0.1.0-beta.N` privately (or as a
pre-release), then tag `v0.1.0` on the same commit before telling anyone the repository exists. If a beta
must go out first, the README says where to look (the full releases list).

## What the pipeline does

`release.yml`, three jobs. The tag is resolved to one commit SHA by the first, and the others work on that
SHA only.

1. **gate** (Ubuntu): the tag is well-formed (`version.py`), exists, was not moved since the push that
   started the run, a beta or stable is on `main` (or a `release/*` branch; a stable: its own `release/X.Y`),
   and a stable has an earlier beta (`app/Scripts/release-gate.sh`). It outputs the **commit SHA**. The
   checkout is `fetch-depth: 0`, so every branch and tag is already local (no later `git fetch`, which
   would need credentials on a private repository).
2. **build** (`macos-26`, Apple silicon, the newest generally available image; Xcode is chosen by
   `app/Scripts/select-xcode.sh`: the newest SDK whose own linker links SkyLight, with `DEVELOPER_DIR` set so the
   engine's build.rs uses the same SDK (in October 2026 that is Xcode 26.x, SDK 26.5); environment `release`): check out that SHA and verify
   the tag still points at it (`verify-tag.sh`, through the GitHub API); install the pinned Rust toolchain
   (`RUST_VERSION` in the workflow, not "stable", so a stable promoted weeks after its beta is built by the
   same compiler); fetch the pinned Sparkle (SHA-256 checked);
   **build the engine and bridge (`build-engine.sh`, the only step that runs dependency code) before any key
   exists**; then import the Developer ID certificate into a temporary keychain; `app/Scripts/build-app.sh
   --skip-engine-build` (the helper with `swiftc`, assemble, sign inside-out with the hardened runtime and
   a secure timestamp, verify); `notarytool submit --wait` and fail with the log unless the result is
   `Accepted`; `stapler staple` and `validate`; `spctl -a -vv -t exec` (only the accepted/notarized lines
   are logged: the full output names the signing identity); zip with `ditto`; sign the zip for Sparkle
   (`sign_update`, key on stdin) and **verify that signature against the `SUPublicEDKey` inside the zip's
   own Info.plist** (`verify-ed-signature.swift`; a wrong secret fails the release here); upload the zip,
   the signature and the minimum macOS version as an artifact. An `always()` step deletes the keychain and
   key files.
3. **publish** (`macos-26`, because `sign_update` is a macOS tool; environment `release`; the only job with
   write access): check out the SHA, re-verify the artifact (version, public key, signature) and the tag,
   create the GitHub release with the zip (pre-release and never "Latest" for a beta; "Latest" only for
   the highest stable), **then** add the item to `appcast.xml` on branch `appcast` (created on first
   use), **sign the appcast** with the Sparkle key, verify that signature against `SUPublicEDKey`, and
   push. The order matters: nobody is offered an update whose file is not there yet. A re-run after the
   release exists compares the zip with the published one and stops if they differ.

What the build refuses (`build-app.sh`, `build-engine.sh`): an engine that does not carry
`net.webreceptor.microfish.engine` in its embedded Info.plist (no `microfish` cargo feature); a
versioned build signed ad hoc (only the dry run passes `--allow-adhoc`); a designated requirement that
lacks `certificate leaf[field.1.2.840.113635.100.6.1.13]` (the Developer ID Application marker, so a
different certificate type from the same team cannot satisfy it).

A dry run (`dry_run`, the default for a manual run) runs only the gate and build jobs, signs ad-hoc and
uploads the zip as a 7-day artifact; it needs no secrets (its jobs use the environment `release-dry-run`,
which has none) and also runs the signature self-test with a throwaway key.

### Rehearsing a release (real signature and notarization, nothing published)

A rehearsal runs the gate and build jobs exactly as a real release does: Developer ID signature, Apple
notarization, staple, Gatekeeper check, the Sparkle signature of the zip (verified against the app's
`SUPublicEDKey`), and the appcast item, signed and verified. Then it stops: no GitHub release, no push to
the `appcast` branch, no `v*` tag. Use it before the first release, and whenever the certificate or a
secret changes.

It needs the real secrets, so it runs in the `release` environment, and so it must run from a protected
tag: `rehearsal-N` on `main` (the environment allows tags `v*` and `rehearsal-*`; the tag ruleset protects
both). The repository is public and its Actions artifacts can be downloaded by anyone signed in to
GitHub, while a signed app carries the certificate's name (`codesign -dv` shows it), so the artifact is
encrypted to a key you make on your Mac:

```sh
git switch main && git pull
git tag rehearsal-2 && git push origin rehearsal-2              # the next unused number
pub="$(app/Scripts/rehearsal.sh keygen ~/microfish-rehearsal-2)" # private key stays in that folder
gh workflow run release.yml --ref rehearsal-2 -f rehearsal=true -f dry_run=false \
  -f tag=v0.1.0-beta.1 -f artifact_key="$pub"
```

`tag` is the version the build carries; it need not exist. If the environment has a required reviewer,
approve the **build** job (only it enters `release`; there is no publish job). Then:

```sh
gh run download <run-id> -n Microfish-rehearsal-encrypted -D ~/microfish-rehearsal-2/artifact
app/Scripts/rehearsal.sh open ~/microfish-rehearsal-2/artifact ~/microfish-rehearsal-2/rehearsal.key ~/microfish-rehearsal-2/files
```

`files/` holds `Microfish-<version>.zip`, `signature.txt`, `min-macos.txt` and the signed `appcast.xml`.
Delete the folder when you are done. Rehearsal tags can stay: they are never built by a push, and each
one only marks the commit that was rehearsed.

`build-app.sh` also runs on a Mac: `app/Scripts/build-app.sh --sign - --out /tmp/microfish-build` for an
ad-hoc build, or `MICROFISH_SIGN_IDENTITY="Developer ID Application" app/Scripts/build-app.sh ...` with
the certificate in your keychain. `--probe-min-macos` re-measures the lowest deployment target.

## The appcast

`SUFeedURL` is `https://raw.githubusercontent.com/elenaOnline/microfish/appcast/appcast.xml`. It is a
file on a branch of its own, not a release asset, because:

- GitHub's `releases/latest/download/` URL always points at the newest **stable** release. A beta would
  never reach beta testers, and moving the "latest" pointer for a beta would push betas on everyone.
  A branch file has no such coupling: one file lists stable and beta items, and Sparkle filters by channel.
- There is no bootstrap problem: the first release already ships a working feed URL, and the URL never
  changes, so old copies in the wild keep finding updates.
- Published release assets are never modified. Fixing the appcast is a commit on the branch, not a
  re-upload.

Each item has `sparkle:version` (build number), `sparkle:shortVersionString`,
`sparkle:minimumSystemVersion`, `sparkle:hardwareRequirements` (`arm64`), a short `<description>` that
links to the GitHub release, and an enclosure that points at the release asset with its
`sparkle:edSignature`. Betas carry `<sparkle:channel>beta</sparkle:channel>`. `app/Scripts/appcast.py`
adds an item idempotently, keeps newest first, and never drops an existing item.

**The feed is signed.** After the item is added, the publish job runs `sign_update` on `appcast.xml`
with the same EdDSA key as the archives: Sparkle rewrites the file (one line) and appends
`<!-- sparkle-signatures: edSignature: ... length: N -->`; the signature covers everything before that
comment. Microfish's Info.plist sets `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`, so an
installed copy refuses a feed whose signature does not verify against its `SUPublicEDKey`: someone who
can push to the `appcast` branch (or serve a copy of the file) can no longer offer an update without
the private key. Verified with Sparkle 2.10.1 in `app/Tests/update-e2e/run.sh --signed-feed`: a signed
feed updates normally; a feed edited after signing is refused ("The update feed is improperly signed");
see `notes/packaging.md` for the unsigned and wrong-key cases. Consequences:

- **Every change to `appcast.xml` must be signed again**, or every installed copy stops seeing updates.
  The workflow does it; a manual edit (rollback below) needs the command shown there.
- Release notes sit inside the feed (`--notes embedded`), because a signed feed cannot vouch for a link
  to a GitHub page.
- Rotating the EdDSA key re-signs the feed with the new key; see Key rotation.

## Rolling back a bad release

Sparkle never downgrades. Rolling back means two things:

1. **Stop offering it.** Remove its item from the appcast:
   ```sh
   git fetch origin appcast
   git worktree add -B appcast ../microfish-appcast origin/appcast
   python3 app/Scripts/appcast.py remove --appcast ../microfish-appcast/appcast.xml --tag v0.1.0
   # sign the feed again with the key in your login keychain (a feed without a valid signature is refused by every installed copy)
   app/Vendor/Sparkle/bin/sign_update --account microfish ../microfish-appcast/appcast.xml
   pub="$(app/Vendor/Sparkle/bin/generate_keys --account microfish -p)"
   swiftc -O app/Scripts/verify-ed-signature.swift -o /tmp/verify-ed-signature
   /tmp/verify-ed-signature feed ../microfish-appcast/appcast.xml --public-key "$pub"
   git -C ../microfish-appcast commit -am "appcast: pull 0.1.0"
   git -C ../microfish-appcast push origin appcast
   ```
   Then
   `gh release edit v0.1.0 --prerelease` (or `--draft`) so GitHub's "Latest" moves back to the previous
   stable. Do not delete or replace the asset: published assets are immutable, and old appcast copies
   or a mirror may still reference it.
2. **Fix forward with a higher build.** People who already updated stay on the bad build until
   something newer is offered: tag `vX.Y.(Z+1)` (through a beta if there is time). A stable `0.1.1` has a
   higher build than `0.1.0` and its betas. Never retag or republish an existing version.

## GitHub setup (once): the `release` environment, the tag ruleset, the secrets

**Why an environment, not repository secrets.** A repository secret is readable by any workflow run in the
repository, including one from a branch or tag whose workflow file somebody just changed. An environment
secret is handed only to a job that names the environment, and only if the run passes the environment's
rules: here, the run's ref must be a `v*` **tag**, and optionally you must approve it. So a modified
workflow on a branch gets nothing, and a leaked write token alone cannot ship a signed build. The cost for
a solo maintainer is one extra click per job (two per release) if you turn on the reviewer. Dry runs use
`release-dry-run`, which GitHub creates empty on first use.

**Current state (2026-10-28).** The repository is public, which makes environments, their tag rules,
required reviewers and rulesets free. All of the below exists, created through the GitHub API (the same
settings as the clicks): ruleset `Release tags` (Active; targets `v*` and `rehearsal-*`; creation, update,
deletion restricted; Repository admin bypass), environment `release` (tag rules `v*` and `rehearsal-*`,
required reviewer `elenaOnline`), and its six secrets. Check with
`gh api repos/elenaOnline/microfish/rulesets`, `gh api repos/elenaOnline/microfish/environments` and
`gh secret list --env release` (names only).

1. **Tag ruleset** (stops anyone but you creating, moving or deleting a release tag).
   https://github.com/elenaOnline/microfish/settings/rules, **New ruleset**, **New tag ruleset**.
   Ruleset Name `Release tags`; Enforcement status **Active**; under **Bypass list**, **Add bypass**,
   **Repository admin**, mode **Always allow**; under **Target tags**, **Add target**, **Include by
   pattern**, type `v*`, **Add**, and the same for `rehearsal-*`; under **Rules** tick **Restrict creations**, **Restrict updates** and
   **Restrict deletions**; **Create**. (As admin you bypass it, and you can still tag; a collaborator's or
   a stolen non-admin token cannot.)
2. **Environment.** https://github.com/elenaOnline/microfish/settings/environments, **New environment**,
   Name `release`, **Configure environment**. Under **Deployment branches and tags** choose **Selected
   branches and tags**, **Add deployment branch or tag rule**, Ref type **Tag**, Name pattern `v*`,
   **Add rule**; again for `rehearsal-*` (rehearsals, above). Under **Deployment protection rules** tick **Required reviewers**, add `elenaOnline`,
   **Save protection rules** (leave "Prevent self-review" off: you are the only maintainer). Leave the wait
   timer off. Optional but recommended: the reviewer rule; without it the tag rule and ruleset still hold.
3. **Secrets, in that environment.** On the same page, under **Environment secrets**, **Add environment
   secret** for each name in the table. Not under Secrets and variables, Actions, Repository secrets.
   If you already added repository secrets, delete them there afterwards.

Secrets (names only):

| Name | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | the Developer ID Application certificate with its private key, exported as `.p12`, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | the password set when exporting the `.p12` |
| `APPSTORE_CONNECT_API_KEY_P8` | contents of the App Store Connect API key file `AuthKey_<id>.p8` |
| `APPSTORE_CONNECT_API_KEY_ID` | that key's Key ID |
| `APPSTORE_CONNECT_API_ISSUER_ID` | the Issuer ID shown above the key list |
| `SPARKLE_ED_PRIVATE_KEY` | the Sparkle EdDSA private key (base64 text); signs the archives and the appcast |

Where each comes from:

- **Certificate**: Keychain Access, login keychain, My Certificates, "Developer ID Application: ...";
  right-click, Export, format Personal Information Exchange (.p12), choose a password. Then
  `base64 -i Certificate.p12 | pbcopy` and paste into the secret; delete the `.p12`.
- **API key**: appstoreconnect.apple.com, Users and Access, Integrations, App Store Connect API, Team
  Keys, Generate API Key (access: Developer). Download the `.p8` once; the Key ID is in its row, the
  Issuer ID above the table.
- **Sparkle key**: `app/Vendor/Sparkle/bin/generate_keys --account microfish` creates it in the login
  keychain; `... --account microfish -p` prints the public key, which goes into
  `app/Packaging/sparkle-public-key.txt` (one line, committed; builds of a tagged version refuse to run
  without it). Export the private key with `... --account microfish -x /tmp/microfish-ed.key`, paste the
  file's contents into the secret, then delete the file.

Nothing in the repository, the logs or the artifacts carries a key, a team ID or an identity hash: the
identity is looked up in the temporary keychain at build time and masked in the log.
The build and publish jobs of a real release declare `environment: release`; no other job and no dry run
sees these secrets, and a step only gets the ones it lists under `env:` (the engine build step gets none).

## Key rotation

- **Developer ID certificate** (expires after five years, or if replaced): export the new `.p12`, update
  the two secrets. The designated requirement is `identifier + anchor apple generic + team`, not the
  certificate, so a renewed certificate from the same team keeps the app's identity, its permission
  grants and Sparkle's check on the installed app.
  The same holds for a new certificate after the account's name changes (the name is fixed inside each
  certificate, so only builds signed with the new one show the new name): replace the two certificate
  secrets, run a rehearsal, and check that `codesign -d -r-` is unchanged and the leaf certificate's
  SHA-1 is the new one. **Do not revoke the old certificate**: revoking a Developer ID certificate stops
  every app signed with it from installing or launching. Leave it to expire; builds signed while it was
  valid keep working because they carry a secure timestamp.
- **App Store Connect key**: create a new one, update the three `APPSTORE_CONNECT_*` secrets, revoke the old.
- **Sparkle EdDSA key**: rotate only deliberately, and test it first. The key signs the appcast as well
  as the archives, and the app verifies the feed against its installed `SUPublicEDKey`: during a rotation
  the feed must be signed with the key the installed copies trust until the first update that carries the
  new key has been installed everywhere that matters. Installed copies verify updates
  against the `SUPublicEDKey` they already carry; Sparkle accepts a changed key only when the new app
  keeps the same Developer ID signature (as Sparkle's "Publishing an update" documents; not tested
  here). Do it
  through the throwaway-account update probe before a real rotation; a lost key without a rotation
  path strands every installed copy.
- **If a secret leaks**: revoke it at its source (certificate in the developer account, API key in App
  Store Connect), then replace the secret. Published releases stay valid.

## Limits of this setup

- Exercised for real on 2026-10-29: the rehearsals (`rehearsal-2` on the first certificate, `rehearsal-3` on the
  current one), then `v0.1.0-beta.1` (gate, build with notarization, publish with the signed appcast), the tag
  ruleset (admin bypass), the environment's tag rules and required reviewer, and `verify-tag.sh` against the
  GitHub API. Not yet exercised: a stable promotion, a `release/X.Y` hotfix, a re-run after a partial publish,
  and an installed copy taking a Sparkle update from this feed (the first beta-to-beta update).
- The current Developer ID certificate chains to Apple's original Developer ID intermediate, which expires on
  2027-02-01, and so does the certificate. Shipped builds keep working (secure timestamp, notarized), but no
  release can be signed with it after that date: make a replacement under the G2 intermediate before then
  (developer.apple.com, Certificates, +, Developer ID Application, Profile Type **G2 Sub-CA**), replace the two
  certificate secrets and rehearse. The designated requirement stays identical.
- Dependency licenses are listed from `cargo metadata` (`app/Scripts/licenses.py`), with the license
  files found in each crate. `cargo-about` would add a curated table for crates that ship no license
  file; swap it in if a notice is ever challenged.
