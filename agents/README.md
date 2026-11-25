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

1. Exits if a tmux session `role-<role>` already exists, and says how to attach.
2. Clones any checkout that is missing, then switches every checkout to `main` and
   fast-forwards it. A checkout with uncommitted changes, or whose `main` cannot
   fast-forward, is left as it is, with a warning.
3. Restows the role package into the workspace, which also removes links to files
   the package no longer has.
4. Starts `claude --name <role> --remote-control <role>` in a new tmux session
   `role-<role>`, in the workspace. From a terminal it switches you to that session;
   run by an agent it stays detached, and the session shows up by name on
   claude.ai and in the Claude app.

A new role is a role package merged to its home repo's `main`; `role` reads only
`main`.

When a session is full, Seth exports its transcript and renames it `saved-<role>`,
so `<role>` is always the live one.

## `roles` skill

`skills/roles/SKILL.md` tells any Claude session on the machine how to start, find
and create roles.

## Setting up a machine

`ubuntu-zsh/install.sh` links `role` into `~/.local/bin` and the skill into
`~/.claude/skills/roles`. Where it has not run, as in the JupyterHub notebook (its
image runs only `install-tools.ansible.yaml`, and the home directory persists),
make the links by hand:

```bash
mkdir -p ~/.local/bin ~/.claude/skills
ln -sfn ~/dotfiles-symm/agents/role ~/.local/bin/role
ln -sfn ~/dotfiles-symm/agents/skills/roles ~/.claude/skills/roles
```

Before a role's first start, seed `~/roles/<role>/memory` if it starts from an
existing memory pool (see the `roles` skill). Claude may ask about trusting the
workspace or enabling MCP servers at a role's first start; answer in the session.

## Conduct

`conduct.md` is how to work with Seth, in every session on the machine, role or not:
`~/.claude/CLAUDE.md`, the user-level file Claude loads for every session, is a link
to it. Each rule is a line or two; the incidents behind each section are in
`conduct/`, read on demand. A repo's own `CLAUDE.md` or `AGENTS.md` holds only what
is particular to that repo.

`ubuntu-zsh/install.sh` links `conduct.md` to `~/.claude/CLAUDE.md`.
