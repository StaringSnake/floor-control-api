# Run journal: local Kind deployment documentation (2026-08-02)

## Status

**Completed for issue #22 documentation; pending publication.**
Issue #21 is merged. Issue #23 remains open until this change is merged and
its aggregate criteria are verified.

## Issue criteria and decisions

- README covers prerequisites, create/verify/access/status/log/cleanup commands,
  Compose port conflict, persistence/data loss, immutable images, Secret
  generation/reuse without values, one-replica/local-only limits, and recovery.
- Existing scripts are the source of truth; no behavior changed. Merged #21
  runtime evidence was reused; no Kind cluster was recreated.
- Secret values remain outside source/output. Deletion is destructive and
  ownership-guarded.

## Changed paths

- `README.md`
- `deploy/kind/README.md`
- This journal.

## Validation

- Issue #22 body/comments read with `gh`; no comments added.
- Script help/options checked against current script sources.
- `bash -n scripts/create-and-deploy-in-kind.sh scripts/delete-kindly.sh scripts/verify-kind-deployment.sh`: passed.
- `scripts/test-kind-scripts.sh`: passed.
- `git diff --check`: passed.
- README inspection block `bash -n` check: passed; topic/reference/security
  scans passed, including confirmation that ambient Secret and kubeconfig
  commands are absent.
- Second-pass scan passed: no ambient `kubectl` lifecycle/inspection commands or
  `kind export kubeconfig` instructions remain in changed documentation.
- Script static tests and `git diff --check` were rerun after removing the
  obsolete migration/API/port-forward blocks.
- Final medium-finding validation passed: the README shell block is syntactically
  valid, all `KIND_*` defaults are quoted and consistently referenced by Kind,
  kubectl, and curl commands, and override/reference/topic scans passed.
- Clean-cluster deployment, migration, readiness, representative access,
  rerun, persistence, and cleanup evidence was previously recorded by #21;
  `verify-kind-deployment.sh` covers the reusable checks.

## Review and risks

- General engineering review required; security review selected for Secret
  handling and destructive deletion; performance skipped because this is
  documentation-only and has no hot-path change.
- Risks: Docker/Kind host compatibility; local hostPath data is lost on cluster
  deletion; one replica and local-only PostgreSQL are not production-ready.

## Aggregated review findings and dispositions

- **HIGH — unsafe manual Secret workflow:** removed the ambient-context manual
  Secret commands. Documentation now directs users to the supported script,
  which isolates kubeconfig handling, fails closed, applies required ownership
  labels, and never exposes values.
- **MEDIUM — dirty-input wording:** clarified that unrelated untracked/docs
  changes are allowed, while tracked or untracked files under build or
  `deploy/kind/` inputs stop deployment.
- **MEDIUM — kubeconfig mutation:** replaced `kind export kubeconfig` guidance
  with copy/paste-safe `kind get kubeconfig` output to a mode-700/mode-600
  temporary location and explicit `kubectl --kubeconfig` use/removal. The
  lifecycle scripts themselves do not mutate the user's kubeconfig.
- **HIGH — duplicated ambient migration/API inspection workflow:** removed the
  manual migration, API, and port-forward command blocks. The deployment README
  now directs users to the supported lifecycle and the root README's protected
  inspection block; no ambient-context kubectl user instruction remains.
- **MEDIUM — hardcoded inspection targets:** parameterized the protected block
  with quoted `${KIND_CLUSTER:-floor-control}`, `${KIND_NAMESPACE:-floor-control}`,
  and `${KIND_HOST_PORT:-4000}` defaults. The resolved cluster, namespace, and
  port now drive kubeconfig export, every explicit kubectl call, and every curl
  URL consistently.

General and security reviewers were selected for final approval. Performance
remains skipped because this is documentation-only and has no hot-path change.

## Next action

General engineering review: **APPROVE**. Security review: **APPROVE**.
Performance review: **SKIPPED** because this is documentation-only with no hot
path. Acceptance verifier: **ACCEPT**; all issue criteria pass. No Kind
recreation was needed; documentation and script/static checks passed.

Residual risks are local Docker/Kind compatibility, intentionally destructive
cluster deletion, one-replica/local PostgreSQL scope, and legacy ambient
`kind export kubeconfig` hints printed by the create script. The docs use safe
standalone kubeconfig inspection; the script hint is a follow-up outside this
documentation acceptance change unless CI proves a blocker.

Create the feature branch, publish the approved paths, and merge before issue
#23 aggregate verification. Do not close #23 in this run.
