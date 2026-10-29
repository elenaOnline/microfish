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

- **`main`** is where work lands. Betas are tagged on `main`.
- **A stable is promoted from a soaked beta.** Once a beta has been used for a while, tag the same
  commit `vX.Y.Z` (no new code between the last beta and the stable). The pipeline refuses a stable tag
  if no `vX.Y.Z-beta.N` exists, and says so when the stable's commit differs from the newest beta's.
- **Hotfixes** for a shipped `X.Y` go on a branch `release/X.Y` cut from that stable's tag. Fix there,
  tag `vX.Y.(Z+1)-beta.1` on the branch, soak, then tag `vX.Y.(Z+1)`. A stable tag must be reachable from
  `main` or from `release/X.Y` of its own minor version; anything else is refused. Merge the fix back
  into `main` too.

## Cutting a beta

1. `main` is green on CI (cargo tests, helper tests, ad-hoc build).
2. Optional but cheap: Actions, Release, "Run workflow", leave `dry_run` ticked, enter the tag you are
   about to push. It builds with an ad-hoc signature, skips notarization and publishing, and uploads
   the zip as an artifact.
3. Tag and push:
   ```sh
   git switch main && git pull
   git tag v0.1.0-beta.1
   git push origin v0.1.0-beta.1
   ```
   Push one tag at a time and wait for the run to finish: runs publish one by one, and a run that is
   waiting behind another is replaced if a third arrives (re-run it from the Actions tab).
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
promotion rule once; use it only for a tag that already exists and you have a reason for.

## What the pipeline does

`release.yml`, three jobs:

1. **gate** (Ubuntu): the tag is well-formed (`version.py`), exists, a stable is on `main` or its
   `release/X.Y`, and has an earlier beta (`app/Scripts/release-gate.sh`).
2. **build** (`macos-26`, Apple silicon, the newest generally available image; Xcode is chosen by
   `app/Scripts/select-xcode.sh`, newest installed): fetch the pinned Sparkle (SHA-256 checked); import
   the Developer ID certificate into a temporary keychain; `app/Scripts/build-app.sh`
   (release build of the engine and bridge, the helper with `swiftc`, assemble, sign inside-out with the
   hardened runtime and a secure timestamp, then verify); `notarytool submit --wait` and fail with the log
   unless the result is `Accepted`; `stapler staple` and `validate`; `spctl -a -vv -t exec`; zip with
   `ditto`; sign the zip for Sparkle (`sign_update`, key on stdin); upload the zip, the signature and
   the minimum macOS version as an artifact. An `always()` step deletes the keychain and key files.
3. **publish** (Ubuntu, the only job with write access): create the GitHub release with the zip
   (pre-release and never "Latest" for a beta; Latest for a stable), **then** add the item to
   `appcast.xml` on branch `appcast` (created on first use). The order matters: nobody is offered an
   update whose file is not there yet. A re-run after the release exists compares the zip with the
   published one and stops if they differ.

A dry run (`dry_run`, the default for a manual run) runs only the gate and build jobs, signs ad-hoc and
uploads the zip as a 7-day artifact; it needs no secrets.

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
`sparkle:minimumSystemVersion`, `sparkle:hardwareRequirements` (`arm64`), a release-notes link to the
GitHub release, and an enclosure that points at the release asset with its `sparkle:edSignature`. Betas
carry `<sparkle:channel>beta</sparkle:channel>`. `app/Scripts/appcast.py` adds an item idempotently,
keeps newest first, and never drops an existing item.

## Rolling back a bad release

Sparkle never downgrades. Rolling back means two things:

1. **Stop offering it.** Remove its item from the appcast:
   ```sh
   git fetch origin appcast
   git worktree add -B appcast ../microfish-appcast origin/appcast
   python3 app/Scripts/appcast.py remove --appcast ../microfish-appcast/appcast.xml --tag v0.1.0
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

## Required secrets (names only)

Repository, Settings, Secrets and variables, Actions, New repository secret:

| Name | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | the Developer ID Application certificate with its private key, exported as `.p12`, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | the password set when exporting the `.p12` |
| `APPSTORE_CONNECT_API_KEY_P8` | contents of the App Store Connect API key file `AuthKey_<id>.p8` |
| `APPSTORE_CONNECT_API_KEY_ID` | that key's Key ID |
| `APPSTORE_CONNECT_API_ISSUER_ID` | the Issuer ID shown above the key list |
| `SPARKLE_ED_PRIVATE_KEY` | the Sparkle EdDSA private key (base64 text) |

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
Optional hardening: move the secrets into a GitHub Environment named `release` with required reviewers
and add `environment: release` to the `build` job.

## Key rotation

- **Developer ID certificate** (expires after five years, or if replaced): export the new `.p12`, update
  the two secrets. The designated requirement is `identifier + anchor apple generic + team`, not the
  certificate, so a renewed certificate from the same team keeps the app's identity, its permission
  grants and Sparkle's check on the installed app.
- **App Store Connect key**: create a new one, update the three `APPSTORE_CONNECT_*` secrets, revoke the old.
- **Sparkle EdDSA key**: rotate only deliberately, and test it first. Installed copies verify updates
  against the `SUPublicEDKey` they already carry; Sparkle accepts a changed key only when the new app
  keeps the same Developer ID signature (as Sparkle's "Publishing an update" documents; not tested
  here). Do it
  through the throwaway-account update probe before a real rotation; a lost key without a rotation
  path strands every installed copy.
- **If a secret leaks**: revoke it at its source (certificate in the developer account, API key in App
  Store Connect), then replace the secret. Published releases stay valid.

## Limits of this setup

- The workflows have not run on GitHub yet: they were validated with `actionlint` (and `shellcheck`),
  by running the shell steps locally against stand-in inputs, and by building the app with the same
  script. The first dry run is the real test.
- Dependency licenses are listed from `cargo metadata` (`app/Scripts/licenses.py`), with the license
  files found in each crate. `cargo-about` would add a curated table for crates that ship no license
  file; swap it in if a notice is ever challenged.
