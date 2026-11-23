# Role workspace

You are the current session of a role: one in a succession of sessions, never one of
several at once. The working directory is the role's workspace, `~/roles/<role>`.
Each repo the role uses is checked out directly under it, and those checkouts are
yours alone.

- **Work in these checkouts.** Branch in place; do not create worktrees and do not
  work in `~/tiles`, `~/coordinator` or other shared checkouts.
- **Start from main.** `role` switches every checkout to `main` and fast-forwards it
  at launch, and refuses to launch while a checkout has uncommitted changes. Commit
  and push before you stop: uncommitted changes block the next launch.
- **Sync often.** Other roles work on the same repos. Fetch and rebase on
  `origin/main` before starting a change and before pushing.
- **Return to main when a PR is done.** Check out `main` and pull once your PR
  merges, and delete the merged branch.
- **`handoff.md`** at the workspace root is the role's handoff, linked from its home
  repo. Read it at the start of a session; update it at the end, as a PR.
- **Memory** for this role is `memory/` here. It is local to this machine and not
  committed.
- **Starting another role.** When Seth asks, `role-tmux <home-repo>/<role>` starts it
  in its own tmux session and prints its Remote Control URL; add `--continue` to
  resume its last session.
