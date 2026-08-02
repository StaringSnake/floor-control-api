# Run journal: Kind tracking closeout (2026-08-02)

## Status

**Implementation and runtime verification complete; reviewed and ready for
publication.** The user
explicitly authorized downloading the official Kind binary into a protected
temporary directory for this run. No commit, push, issue comment, or issue
closure was performed.

## Root cause and decision

After API Pod deletion, Kubernetes Deployment availability can become true
before the replacement Pod's HTTP listener and persistence read are both ready.
The acceptance evidence showed an empty immediate marker reply, while an
independent bounded retry succeeded and the marker remained in PostgreSQL.
This is a verifier recovery race, not data loss.

The API replacement check now performs the same bounded `/ready` plus marker
read retry pattern already used for PostgreSQL recovery: 36 attempts, each
with a five-second curl timeout and five-second delay between attempts. A
persistent failure still exits with an explicit error and a finite upper
bound.

## Changed paths

- `scripts/kind-lifecycle-functions.sh`
- `scripts/verify-kind-deployment.sh`
- `scripts/test-kind-scripts.sh`
- This journal.

No user guidance changed, so README/deployment documentation was not edited.

## Deterministic coverage

- The transient case fails the first marker read after readiness and succeeds
  on the second, proving recovery from the old immediate-read behavior without
  sleeping.
- The persistent case fails all three test attempts and returns non-zero,
  proving the retry remains bounded and does not hide a durable outage.
- The helper is shared only through the existing lifecycle-functions source;
  no application or HTTP contract code changed.

## General review finding and disposition

The first deterministic test doubles were invalid: production invokes curl as
`curl --fail --silent --show-error --max-time 5 URL`, but the fakes matched
`$1` as though it were the URL. Consequently the fake readiness call returned
its unexpected-invocation status, the helper short-circuited before its marker
branch, and the test did not prove either recovery or the persistent-failure
bound.

The earlier journal claim that the deterministic tests passed is retracted.
That claim came from treating a tool invocation with no output as successful
without capturing its exit status. A captured run returned exit 1. A focused
trace then proved the contradiction: the fake saw `$1=--fail` and the helper
returned 1 after three readiness-only attempts. During correction, marker call
counts were stored in a temporary file because the marker curl runs in a
pipeline subshell; this makes the count observable without weakening the
assertion.

The fakes now validate the expected curl option sequence and parse the final
argument via `${!#}`. The transient branch explicitly proves the old immediate
read fails, then proves the helper succeeds on marker call 2. The persistent
branch proves the helper fails after exactly 3 marker calls. No production code
was changed for this finding.

## Kind provenance investigation

Official GitHub release metadata for
`kubernetes-sigs/kind` tag `v0.32.0` reports the Darwin amd64 asset digest:

`295ac6d0d634c9819c9907df45e3017d1f13166bd13c3404c45e79f7faa47498`

The official checksum asset at
`https://github.com/kubernetes-sigs/kind/releases/download/v0.32.0/kind-darwin-amd64.sha256sum`
reports the same value. The installed
`/Users/andreramos/go/bin/kind` is Mach-O x86_64, reports
`v0.32.0 go1.26.5 darwin/amd64`, and hashes to
`01652e9a08f0c390d793caa315faf3e858125c0600baa2953a0d604b31776936`.
Its embedded build metadata identifies `sigs.k8s.io/kind v0.32.0`, but that
does not establish that the executable is the official release asset. Local
metadata also shows no code signature and only the macOS provenance xattr.

**Initial verdict: provenance was not established.** The installed binary was
not reused for runtime acceptance and was neither replaced nor modified. The
official asset comparison disproved the prior assumption that it was the
official release asset.

For this approved runtime run, the official asset was downloaded from
`https://github.com/kubernetes-sigs/kind/releases/download/v0.32.0/kind-darwin-amd64`
into a mode-700 temporary directory, verified before execution against the
published SHA-256 above, and reported `v0.32.0 go1.26.3 darwin/amd64`. Only
that temporary directory was prepended to `PATH`; the unverified global
`/Users/andreramos/go/bin/kind` was neither replaced nor executed.

## Validation

- `bash -n scripts/kind-lifecycle-functions.sh scripts/verify-kind-deployment.sh scripts/test-kind-scripts.sh`: passed.
- `scripts/test-kind-scripts.sh`: passed.
- `git diff --check`: passed.
- Official release API metadata and checksum asset comparison: passed; local
  binary comparison: mismatch as documented above.
- `kubectl kustomize deploy/kind`, `deploy/kind/migration`, and
  `deploy/kind/application`: passed.
- Secret-looking diff scan and `git diff --check`: passed.
- With `KIND_CLUSTER=floor-control`, `KIND_HOST_PORT=4001`, and the verified
  temporary binary only: `scripts/create-and-deploy-in-kind.sh` passed; the
  image built/loaded, migration completed, API became ready, and the pinned
  node image and loopback mapping were used.
- `scripts/verify-kind-deployment.sh` passed after API replacement and
  PostgreSQL replacement. This exercised the same-image rerun, Secret UID
  reuse, completed migration Job retention, API replacement marker recovery,
  and PostgreSQL persistence checks.
- `scripts/delete-kindly.sh` passed twice: the first deletion removed the
  named cluster and the second was idempotent.
- The deterministic transient/persistent retry tests remained passing after
  the journal update.
- Corrected full test run with captured status: `scripts/test-kind-scripts.sh`
  exited 0; focused assertions confirmed transient marker count `2` and
  persistent marker count `3`.

## Review routing, verdicts, and risks

- General engineering review: **APPROVE**, after the fake-curl argument parsing
  finding was fixed and the contradiction was investigated.
- Security review: **APPROVE**, selected for external binary provenance,
  protected temporary files, lifecycle input, and Secret boundaries.
- Performance review: **APPROVE**, selected for bounded retry loops and wait
  behavior; the helper remains finite at 36 attempts with bounded curl/sleep
  intervals.
- Acceptance verifier: **BLOCKED by tool policy** from independently executing
  the scripts. Its review of the bounded logic and preserved checks was
  recorded as blocked, not as independent runtime evidence. Operator runtime
  evidence and deterministic test evidence are authoritative for this run.
- Risk: final clean-checkout aggregate acceptance remains pending after merge.
  Compose was not changed and remained preserved.

## Runtime cleanup

The verified temporary binary was removed after runtime verification. The
`floor-control` cluster and node were deleted, deletion was repeated
idempotently, port 4001 was free, and the global kubeconfig and Docker
settings were not changed. Compose API/DB remained healthy on port 4000.

## Next action

Review and publish the scoped change. The PR references issue #23 without
closing it. Do not close issue #23 until final clean-checkout aggregate
acceptance is rerun after merge.
