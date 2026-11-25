# CLAUDE.md -- dotfiles-symm

What is particular to this repo. How to work with Seth is
[`agents/conduct.md`](agents/conduct.md), which every session on a machine set up by
`ubuntu-zsh/install.sh` already has loaded as `~/.claude/CLAUDE.md`. A session that
does not (one on claude.ai/code, say) should read it first.

## Layout

- `ubuntu-zsh/` -- host bootstrap: `install.sh` stows `homedir/` into `~` and links
  the `agents/` tools; the Ansible playbooks install the toolchain. See its
  `README.md`, and `NOTES-notebook.md` for the JupyterHub notebook.
- `agents/` -- agent roles, their workspace rules and `conduct.md`. See its
  `README.md`.
- `pi-image/` -- the btrfs Pi image build; start at `PIPELINE.md`.
- `cubie-a7s/` -- Talos build inputs for the Radxa Cubie A7S; the board itself is
  documented in fables.

## Changes

- `main` takes PRs only, merged by rebase (no merge or squash commits). Keep branches
  linear: rebase onto `origin/main`, never merge it in.
- `pre-commit run --all-files` is the check CI runs (`.github/workflows/pre-commit.yaml`).
  The `shellcheck` hook needs `shellcheck` installed locally.
- `build-pi-image` runs on pushes touching `pi-image/`.
