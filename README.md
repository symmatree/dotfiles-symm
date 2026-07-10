# dotfiles-symm

Repo for easy access to my dotfiles as well as installation for primary
tools.

## Raspberry Pi host bootstrap

`ubuntu-zsh/` (Ansible + the `rpi-console` profile in `ubuntu-zsh/vars/`) is intended
as the **master** host bootstrap that the Symmatree Pi fleet converges onto -- the
PocketTerm35 handheld ("pipboy"), the rekon10 coordinator (Pi 4B), and the Pi Zero 2 W
pods. The device-specific host bootstraps in `symmatree/coordinator` (`host/ansible`)
and the tiles/jupyterhub copy are meant to become **subsets** of this master rather than
parallel reimplementations. Bring-up of the first such device (pipboy) is tracked in
[symmatree/tiles #599](https://github.com/symmatree/tiles/issues/599).

## Kubernetes

Ansible installs **`kubectl`** and **`kubectx`** (see `ubuntu-zsh/install-tools.ansible.yaml`). Credentials are not in this repo. For Symmatree **Tiles** clusters (test and prod), fetch kubeconfigs from 1Password and merge into `~/.kube/config` as described in **`https://github.com/symmatree/tiles/blob/main/docs/dev-setup.md`** (Kubeconfig section). The same merge pattern applies for other clusters so one `~/.kube/config` is not tied to a single project.
