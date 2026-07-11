# JupyterHub notebook bootstrap (tiles cluster)

Recovery notes for the `datascience-notebook-ssh` JupyterHub environment on the
tiles cluster. The home dir is an NFS-backed PVC that **persists but is not
forever** -- when it gets wiped, this file (in git) is how you rebuild.

The image already bakes every tool (zsh, oh-my-zsh deps, kubectl, talosctl, op,
etc.) via `install-tools.ansible.yaml`. So bootstrap here is **not** installing
software -- it is just wiring up dotfiles, oh-my-zsh, and secrets in `$HOME`.

Context for agents/humans about the environment itself lives in `~/AGENTS.md`
(seeded from the image on every pod start -- do not edit it; it's overwritten).

## 1. Get the repo

```bash
git clone https://github.com/symmatree/dotfiles-symm.git ~/dotfiles-symm
cd ~/dotfiles-symm/ubuntu-zsh
```

## 2. Dotfiles + oh-my-zsh

`install.sh` stows `~/.zshrc`, `~/.gitconfig`, `~/.tmux.conf`, clones the zsh /
tmux plugins, and installs oh-my-zsh. In this container the tail-end
`sudo stow sudoers.d` and `chsh` steps are harmless-but-irrelevant (sudo is
already granted; chsh doesn't stick across pod restarts). If you'd rather not
run those, do the two essential steps by hand:

```bash
# stow the dotfiles (from ~/dotfiles-symm/ubuntu-zsh)
cd homedir && for d in */; do stow --dotfiles -t "$HOME" -S "${d%/}"; done && cd ..

# oh-my-zsh -- the one piece not baked into the image; keeps our ~/.zshrc
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc

# zsh custom plugins (if a fresh home)
git clone https://github.com/zsh-users/zsh-autosuggestions     ~/.zshcustom/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting ~/.zshcustom/plugins/zsh-syntax-highlighting
```

**Using zsh:** the JupyterHub terminal starts `bash` (default shell; `chsh` is
unreliable here). Just run `zsh` to get the full setup with aliases/theme.
`git config` ownership: uid is baked to 1024 to match the NFS squash, so git
works with no `safe.directory` entries -- do **not** re-add them to
`dot-gitconfig` (that cruft has crept in before).

## 3. Secrets (kubeconfig / talosconfig)

Design: **only you** create the 1Password session (needs your password/passkey
-- no agent can). Secrets land on disk with tight perms; agents then read the
*files* (`~/.kube/config`, `~/.talos/*.yaml`), never `op`, and nothing is
printed to chat. `refresh-secrets.sh` holds only `op://` paths, no secrets.

```bash
# first time on a fresh home: register the account
op account add --address my.1password.com --email symmetry@pobox.com
# every session (interactive -- this is the step only you can do):
eval "$(op signin)"

# then pull creds to disk (safe to re-run; safe for an agent to run while your
# session is live -- it still can't authenticate on its own):
~/dotfiles-symm/ubuntu-zsh/refresh-secrets.sh
```

This writes `~/.talos/{tiles-test,tiles}.yaml` and flatten-merges the two
kubeconfigs into `~/.kube/config` (keeping any pre-existing clusters). Verify:

```bash
kubectl config get-contexts
talosctl --talosconfig ~/.talos/tiles.yaml -n <NODE_IP> version
```

Talos note: use `--talosconfig <file>` explicitly -- merging/`TALOSCONFIG` is
unreliable for talos (cert validation). See
[tiles/docs/secrets.md](https://github.com/symmatree/tiles/blob/main/docs/secrets.md)
and [tiles/docs/dev-setup.md](https://github.com/symmatree/tiles/blob/main/docs/dev-setup.md)
for the upstream source of truth and the full `op://` reference list.
