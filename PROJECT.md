# Project Profile

## Purpose

This repository will contain a REST API that manages floor ownership for users
in radio groups. It is currently a challenge bootstrap with no implementation
stack selected.

## Architecture

- `REQUIREMENTS.MD`: source challenge brief.
- `OpenApiSpec.yaml`: supplied API contract.
- `README.md`: repository overview and links to the challenge documents.
- `opencode.json` and `.opencode/`: OpenCode harness configuration and agent link.
- `docs/agent-runs/`: version-controlled harness run journals.
- No application source or project files exist yet.

## Commands

| Purpose | Command |
|---|---|
| Build | Not available; no implementation has been selected. |
| Test | Not available; no test project exists. |
| Run | Not available; no application exists. |
| Migrations | Not available; no persistence technology has been selected. |
| CI | Not available; no pipeline exists. |
| Deployment | Not available; no deployment configuration exists. |

## Constraints

- Expose the behavior through the supplied OpenAPI contract.
- Allow at most one floor holder per radio group at a time.
- Permit a floor holder to release the floor so another user can obtain it.
- Floor control excludes audio broadcasting.
- The eventual application must be containerized with Docker and include run
  instructions.
- The challenge permits any implementation language; none is selected yet.
- Bonus features in the brief are optional and are not part of this bootstrap.

## Domain Language

- `Floor`: A temporary permission granting mutually exclusive use of a shared
  resource, represented here by the right to speak in a radio group.
- `Floor holder`: The user who currently owns the floor for a radio group.
- `Radio group`: The scope within which floor ownership is mutually exclusive.
- `Obtain floor`: Request the right to become the current floor holder.
- `Release floor`: Relinquish floor ownership so it can be obtained again.
- `User equipment (UE)`: The user's equipment unit through which a floor request
  is made.
- `Talk burst`: The period for which the floor is granted to speak.
