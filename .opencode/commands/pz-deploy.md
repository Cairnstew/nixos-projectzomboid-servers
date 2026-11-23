---
description: Deploy an updated Project Zomboid modpack to desktop and/or server
agent: build
---

Load the `pz-deploy` skill and follow its workflow exactly.

Scope: $ARGUMENTS

Defaults when no argument is given: deploy to both `desktop` and `server`, use
the pack touched by the current diff (fall back to `viewpoint`), commit and push
the pz repo and each host's `flake.lock` bump, and ask before restarting the
server if it is active.

Do not start until you have read the skill and checked the preflight in Phase 0.
Deploy one host at a time and report every skipped or failed step.
