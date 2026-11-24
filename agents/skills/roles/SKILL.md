---
name: roles
description: Start, resume or create one of Seth's agent roles (renovate, tiles wrangler, flight hardware, ...) in its own tmux session with Remote Control, so he can reach it from claude.ai or his phone. Use when Seth asks to start, launch, spin up, resume or create a role or "a guy" for some line of work.
---

# Roles

A role is a succession of Claude sessions, one at a time, with a workspace at
`~/roles/<role>` and a package at `<home-repo>/agents/<role>/` (symmatree repos).
How the pieces work: `~/dotfiles-symm/agents/README.md`.

## Start or resume a role

```bash
role-tmux <home-repo>/<role>              # the next session in the role
role-tmux <home-repo>/<role> --continue   # resume its last session
```

Only when Seth asks. It starts the role in a detached tmux session `role-<role>`,
not as your child, and prints the Remote Control URL. Give Seth the URL.

When it fails, report what it printed:

- **uncommitted changes in a checkout** -- the role's last session left work in
  `~/roles/<role>/<repo>`. Show Seth `git -C <checkout> status` and ask; do not commit,
  stash or discard it.
- **duplicate session `role-<role>`** or **already running** -- the role is up. Say so;
  `tmux capture-pane -p -t role-<role> | grep -o 'https://claude.ai/code/[^ ]*'`
  recovers its URL.
- **no `<home-repo>/agents/<role>`** -- the package is not on `main`.
- **Remote Control has not shown up**, with a "trust this folder" prompt in the output
  -- the workspace is not under a trusted folder. `~/roles` is normally trusted once,
  from a keyboard; tell Seth.

## Find existing roles

Packages on `main`, in each repo that has an `agents/` directory:

```bash
for r in $(gh repo list symmatree --no-archived --json name -q '.[].name'); do
  out=$(gh api "repos/symmatree/$r/contents/agents" -q ".[] | select(.type==\"dir\") | \"$r/\" + .name" 2>/dev/null) && echo "$out"
done
```

`~/roles/` holds the workspaces created on this machine.

## Create a role

A role exists once its package is merged to its home repo's `main`; `role` reads
only `main`. Ask Seth what the role is for and which repo is its home if he has not
said. Then open a PR in the home repo adding `agents/<role>/`:

- `CLAUDE.md` -- the role's guidance: imports, then what the role is responsible
  for in Seth's words.

  ```
  # Role: <role>

  @~/roles/<role>/dotfiles-symm/agents/workspace.md
  @~/roles/<role>/<home-repo>/CLAUDE.md
  @~/roles/<role>/handoff.md
  ```

  plus `@~/roles/<role>/<repo>/...` for any other repo guidance (`AGENTS.md`) or
  docs the role starts from.
- `handoff.md` -- for whoever is the role's next session: read at the start, updated
  at the end as a PR. Durable facts graduate to docs, work to issues. If the role
  already has a handoff elsewhere, move it here and fix the links to it.
- `repos` -- other repos to check out, one per line; the home repo and
  `dotfiles-symm` are always checked out.
- `.claude/settings.json` --

  ```json
  {
    "autoMemoryDirectory": "~/roles/<role>/memory",
    "enabledMcpjsonServers": ["github"]
  }
  ```

  with the MCP servers from `~/.mcp.json` the role uses.

Example: `tiles/agents/renovate/`.

Before the role's first start, seed its memory if Seth wants it to start from an
existing pool: copy that repo's memory directory (the `autoMemoryDirectory` in the
repo's `.claude/settings.json`) to `~/roles/<role>/memory`. The role sweeps it with
Seth from there.

After the PR merges, start it as above.
