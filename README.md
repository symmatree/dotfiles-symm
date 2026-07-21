# dotfiles-symm

Repo for easy access to my dotfiles as well as installation for primary
tools.

## JupyterHub notebook

For rebuilding the tiles `datascience-notebook-ssh` environment after a home-dir
wipe (dotfiles, oh-my-zsh, and loading kube/talos secrets from 1Password), see
[`ubuntu-zsh/NOTES-notebook.md`](ubuntu-zsh/NOTES-notebook.md). On-disk
credentials are refreshed via
[`ubuntu-zsh/refresh-secrets.sh`](ubuntu-zsh/refresh-secrets.sh) (holds only
`op://` reference paths, no secret material).

## Raspberry Pi host bootstrap

`ubuntu-zsh/` (Ansible + the `rpi-console` profile in `ubuntu-zsh/vars/`) is intended
as the **master** host bootstrap that the Symmatree Pi fleet converges onto -- the
PocketTerm35 handheld ("pipboy"), the rekon10 coordinator (Pi 4B), and the Pi Zero 2 W
pods. The device-specific host bootstraps in `symmatree/coordinator` (`host/ansible`)
and the tiles/jupyterhub copy are meant to become **subsets** of this master rather than
parallel reimplementations. Bring-up of the first such device (pipboy) is tracked in
[symmatree/tiles #599](https://github.com/symmatree/tiles/issues/599).

These devices take **routine abrupt power loss** and are often **offline**. The resilient base they run
is a **btrfs subvolume layout** (read-only `/usr`, read-write `/var` / `/home` / `/data`, snapshots — no
overlay); the shared pattern is `facts/topics/power-unstable-pi.md` and the drone-coordinator specifics
are [symmatree/coordinator #41](https://github.com/symmatree/coordinator/issues/41). Because that layout
can't come from a stock flash, this repo is also the intended home for the **fleet image-build pipeline**
(rpi-image-gen, [coordinator #96](https://github.com/symmatree/coordinator/issues/96)) — the layer that
builds the partitioned btrfs image each device boots, with the Ansible bootstrap above converging on top.

## Kubernetes

Ansible installs **`kubectl`** and **`kubectx`** (see `ubuntu-zsh/install-tools.ansible.yaml`). Credentials are not in this repo. For Symmatree **Tiles** clusters (test and prod), fetch kubeconfigs from 1Password and merge into `~/.kube/config` as described in **`https://github.com/symmatree/tiles/blob/main/docs/dev-setup.md`** (Kubeconfig section). The same merge pattern applies for other clusters so one `~/.kube/config` is not tied to a single project.
