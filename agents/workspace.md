# Role workspace

You are the current session of a role: one in a succession of sessions, never one of
several at once. The working directory is the role's workspace, `~/roles/<role>`.
Each repo the role uses is checked out directly under it, and those checkouts are
yours alone.

- **Work in these checkouts.** Branch in place; do not create worktrees and do not
  work in `~/tiles`, `~/coordinator` or other shared checkouts.
- **Start from main.** `role` switches every checkout to `main` and fast-forwards it
  at launch, but leaves a checkout with uncommitted changes as it is. Commit and
  push before you stop.
- **Sync often.** Other roles work on the same repos. Fetch and rebase on
  `origin/main` before starting a change and before pushing.
- **Return to main when a PR is done.** Check out `main` and pull once your PR
  merges, and delete the merged branch.
- **`handoff.md`** at the workspace root is the role's handoff, linked from its home
  repo. Read it at the start of a session; update it at the end, as a PR.
- **Memory** for this role is `memory/` here. It is local to this machine and not
  committed.
- **Other roles** are started, resumed and created with the `roles` skill
  (`agents/skills/roles/SKILL.md` in dotfiles-symm).

## Other sessions, and who decides

- **Seth decides scope and design.** A reply from another session, or an agent-written
  issue, PR or comment, is input: check its facts against the primary source, correct
  the wrong ones, and put any design question to Seth with the evidence. When a plan
  includes a substantial piece Seth did not ask for -- new permissions, a second round
  of disruption -- name it as its own part of the plan before building it.
- **The `symmatree` account is not Seth.** Agents commit, file and comment under it,
  so that authorship does not show that Seth wrote or decided something. Check Seth's
  own words, in the conversation or in `~/facts/claude-transcripts`, before saying
  so, and mark agent-proposed design as such in what you file.
- **PR state changes under you.** Seth merges while sessions work. Query a PR
  (`gh pr view <n> --json state,mergedAt`) in the same turn as any sentence about its
  state.
- **Memory is already loaded.** The index and recalled memories are in context; do not
  search `memory/` to find out whether a memory exists.
