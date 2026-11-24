# Agent roles

A role is a succession of Claude sessions, one at a time, that carries a line of work
forward: renovate, a cluster wrangler, flight hardware. Each role has a home repo, the
one closest to its work, and a workspace on the machine it runs on.

## Workspace

```
~/roles/<role>/                 working directory for the role's sessions
  CLAUDE.md, handoff.md, ...    links into the role package (below)
  .claude/settings.json         link into the role package
  .claude/settings.local.json   local; Claude writes it
  memory/                       the role's memory; local, not committed
  .lock                         held while a session runs
  <repo>/                       one checkout per repo the role uses
```

The checkouts belong to the role. Its sessions branch in them directly rather than
in worktrees, and sync with `origin/main` to work alongside other roles.

## Role package

`<home-repo>/agents/<role>/` is a stow package whose target is the workspace:

- `repos` -- the other repos the role checks out, one per line. The home repo and
  `dotfiles-symm` are always checked out. Not linked into the workspace.
- `CLAUDE.md` -- the role's guidance. It imports
  `@~/roles/<role>/dotfiles-symm/agents/workspace.md` (the rules every workspace
  shares) and whatever repo guidance and docs the role starts from, by absolute
  path, since Claude does not load a subdirectory's `CLAUDE.md` until it reads a
  file there.
- `handoff.md` -- the role's handoff.
- `.claude/settings.json` -- the role's project settings, at least
  `autoMemoryDirectory: ~/roles/<role>/memory`. The repos' own `.claude/settings.json`
  do not apply, since the working directory is the workspace.

Stow links each file separately (`--no-folding`), so `.claude/` and `memory/` stay
real directories and Claude's own writes land in the workspace, not the repo. Two
packages cannot provide the same file; settings shared by every role belong in
`~/.claude/settings.json`. MCP servers come from `~/.mcp.json`;
`enabledMcpjsonServers` in the role's settings picks which.

## `role`

```bash
role <home-repo>/<role> [claude args...]   # e.g. role tiles/renovate --continue
```

1. Clones any checkout that is missing.
2. Switches every checkout to `main` and fast-forwards it. It stops, listing each
   one, when a checkout has uncommitted changes or a local `main` that cannot
   fast-forward.
3. Restows the role package into the workspace, which also removes links to files
   the package no longer has.
4. Runs `claude` in the workspace under `flock`, so a second launch of the role
   exits while one is running.

## `role-tmux`

```bash
role-tmux <home-repo>/<role> [claude args...]   # e.g. role-tmux tiles/renovate --continue
```

Runs `role` in a new detached tmux session, `role-<role>`, with
`--remote-control <role>`, so a session can be started from another session or from
the phone and then reached through claude.ai or the Claude app. The tmux session
belongs to the tmux server, not to the caller. It prints the Remote Control URL once
claude is up, or what `role` printed if it stopped first. tmux refuses a second
`role-<role>` session.

Claude asks before trusting a new folder, and in a detached session nothing can
answer. Trust covers subfolders, so `~/roles` is trusted once and every workspace
under it inherits that.

A new role is a role package merged to its home repo's `main`; `role` reads only
`main`.

## `roles` skill

`skills/roles/SKILL.md` tells any Claude session on the machine how to start, resume,
find and create roles.

`ubuntu-zsh/install.sh` links `role` and `role-tmux` into `~/.local/bin`, and the
skill into `~/.claude/skills/roles`.
