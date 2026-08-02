# Run journal: Kind tracking closeout (2026-08-02)

## Status

**Completed.** Final post-merge clean-checkout acceptance passed all eight issue
#23 criteria with no gaps. The user explicitly authorized the journal-only
closeout publication, merge, and ticket completion.

## Clean-checkout acceptance follow-up (issue #23)

The subsequent clean-checkout acceptance failed only at the PostgreSQL Pod
replacement check: the API floor-holder marker was absent after recovery. The
runtime evidence included PostgreSQL DNS/connection outage logs and timeout
sweep releases. This is expected domain behavior, not proof of volume data
loss: the configured floor timeout is 30 seconds, the worker sweeps at half
that interval, and `Floors.expire_expired/2` deletes expired ownership rows.
The API marker is consequently a valid API Pod replacement witness but not a
durable PostgreSQL storage witness after a recovery window.

The verifier-only correction keeps the API marker check unchanged and creates
a uniquely named acceptance table/row immediately before PostgreSQL Pod
replacement. It checks that exact row with bounded in-pod `psql` retries, then
drops the table best-effort from the exit trap. The generated identifier is
strictly validated and SQL identifiers are double-quoted; the generated marker
literal is SQL-quoted before being passed to `psql`. The command uses the Pod's
database environment for password authentication
inside the Pod, so no credential is read, printed, or committed. Deterministic
tests cover command construction, unsafe identifier rejection, successful
check, and cleanup despite an exec failure.

This follow-up required a current-tree Kind rerun from a clean checkout with
the previously authorized, checksum-verified temporary Kind v0.32.0 binary.
Review routing remains general engineering, security, and performance.

### Follow-up verification result

The current-tree runtime rerun passed with the checksum-verified temporary
Kind v0.32.0 binary, including same-image rerun, API Pod replacement,
PostgreSQL Pod replacement, and the direct PostgreSQL marker check. The named
cluster was deleted twice and the temporary binary was removed. Compose API/DB
remained healthy on port 4000. The local `mix test` command was also attempted
but is not an acceptance blocker for this verifier-only change: the repository
test configuration targets `localhost:5432`, while the preserved Compose DB
does not publish that port; 60 database-backed tests failed to connect and 16
non-database tests passed. The deterministic Kind script suite passed.

### Aggregated security/performance finding dispositions

- **Marker ownership/collision (security correctness): fixed.** The verifier
  now publishes table/value state and sets `postgres_marker_created=1` only
  after the `CREATE TABLE` plus insert command succeeds. Cleanup drops only
  when that ownership flag is set, and always resets all marker state. A
  deterministic simulated collision/create failure proves cleanup emits no
  `DROP TABLE`, so an existing table cannot be removed.
- **Kubernetes wait transport bound (performance reliability): revised.** The
  verifier does not impose a premature request timeout on `kubewatch`; it
  retains `wait --timeout=180s` and uses the shared 190-second outer process
  timeout. A fake-kubectl test asserts the absence of a transport cap and the
  exact outer/inner wait budgets.
- **PostgreSQL retry duration (performance): fixed.** Marker create/check/drop
  use a dedicated `postgres_kube` wrapper with `--request-timeout=5s`, rather
  than the generic 30-second request bound. The nine-attempt loop allows
  five seconds of recovery delay per retry: at most approximately 175 seconds
  for marker polling, plus the explicit 180-second Pod readiness wait. The
  deterministic suite verifies the 5-second wrapper and exact marker retry
  behavior remains bounded.

### Final outer-bound re-review

The earlier 30-second `kubectl` request bound was insufficient because it
could interrupt a legitimate 180-second condition wait. The final design
removes that request bound from verifier `kubewatch` calls and wraps each
long wait in the shared `run_with_timeout` process-tree helper. The deployment
and PostgreSQL readiness waits retain `kubectl wait --timeout=180s` and have a
190-second outer budget, allowing ten seconds for orderly process-tree
termination/reaping. The helper targets only the spawned PID and descendants;
it sends TERM, waits two seconds, then KILLs remaining descendants and reaps
the root. A success, a normal nonzero wait, and a TERM-ignoring descendant are
covered without long test sleeps.

Marker creation now sends one explicit `BEGIN; CREATE TABLE; INSERT; COMMIT;`
command with `ON_ERROR_STOP=1`, so table creation and row insertion commit
together. The marker state is published only after that command succeeds.
Marker create/check/cleanup execs each have a 15-second outer budget, a
5-second kubectl request bound, `PGCONNECT_TIMEOUT=5`, `statement_timeout=10s`,
and `lock_timeout=5s`. Cleanup remains best-effort but is bounded. The
  polling budget is nine attempts with five-second delays: at most about 175
  seconds after the explicit 180-second readiness wait.

Final deterministic and runtime validation passed. Runtime acceptance observed
one transient Kubernetes exec-stream error while the replacement container
was settling, then succeeded within the bounded retry budget. The PostgreSQL
marker was removed after acceptance, confirming cleanup. Pending re-review is
limited to the general engineering, security, and performance reviewers.

The final deterministic command `scripts/test-kind-scripts.sh` exited with
status **0**. It now asserts no request timeout on the 180-second waits, the
190-second outer wrapper, the nine-attempt PostgreSQL budget, missing-`ps`
preflight failure, and missing-`pgrep` preflight failure. Bash syntax,
Kustomize rendering, manual secret scan, and `git diff --check` also exited
successfully.

The final general finding was resolved by adding an explicit `pgrep` preflight
to `verify-kind-deployment.sh`, matching the process-tree cleanup dependency
already checked by create/delete and documented in both lifecycle READMEs.

### Final review and acceptance disposition

- General engineering review: **APPROVE**; scope, evidence, ownership state,
  and cleanup behavior were reviewed after the final `pgrep` preflight fix.
- Security review: **APPROVE**; SQL quoting, transaction atomicity, credential
  boundaries, temporary files, and executable prerequisites were reviewed.
- Performance review: **APPROVE**; the 190-second outer wait budget, 15-second
  bounded database operations, nine-attempt PostgreSQL recovery budget, and
  no-premature-transport-timeout design were reviewed.
- Acceptance verifier: **BLOCKED by tool policy** from independent runtime
  execution, but statically confirmed all acceptance criteria. Operator fresh
  runtime and deterministic evidence are authoritative for this run.
- Post-merge requirement: rerun the complete clean-checkout issue #23
  acceptance after merge. Issue #23 must remain open until that evidence is
  recorded.

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
- `README.md`
- `deploy/kind/README.md`
- This journal.

README and `deploy/kind/README.md` document the `ps` prerequisite used by the
verifier's timeout helper.

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
- Performance review: **APPROVE**, selected for the shared outer process-tree
  timeout, `ps`/`pgrep` prerequisites, and nine-attempt PostgreSQL recovery
  budget. The API marker retry remains 36 attempts with bounded curl/sleep
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

## Final post-merge clean-checkout acceptance

The acceptance verifier verdict is **ACCEPT**. All eight issue #23 criteria
passed with no gaps on a fresh clean checkout:

- official checksum-verified temporary Kind binary was used;
- Swagger/OpenAPI returned HTTP 200;
- PostgreSQL and one API Pod became ready;
- migration ordering was verified;
- the API was reached through the loopback NodePort;
- API Pod replacement and PostgreSQL Pod replacement both preserved the
  expected persistence evidence;
- same-image reuse was safe;
- no marker tables remained after cleanup;
- deletion and repeated deletion were idempotent;
- README commands passed;
- no repository artifacts were left;
- preserved Compose API/DB services remained healthy; and
- no secrets were disclosed.

The acceptance evidence was collected after the code-bearing PR #30 had been
merged, from a fresh clean checkout of the resulting main branch. The checked
out tree was clean before and after verification. The named Kind cluster was
deleted, deletion was repeated to prove idempotence, and the temporary Kind
binary was removed. Compose remained healthy on port 4000 and no generated
artifacts remained in the repository.

The code-bearing PR #30 had final general engineering, security, and
performance review verdicts of **APPROVE**. This journal-only closeout changes
no product or operational behavior, so no new conditional review was needed.

Residual non-blockers are limited to local Kind/Docker compatibility and the
intentional destructive deletion of the temporary verification cluster.
Issue #23 is therefore complete and may be closed by the merged closeout PR.
