# dotfiles-symm

Repo for easy access to my dotfiles as well as installation for primary
tools.

## Kubernetes

Ansible installs **`kubectl`** and **`kubectx`** (see `ubuntu-zsh/install-tools.ansible.yaml`). Credentials are not in this repo. For Symmatree **Tiles** clusters (test and prod), fetch kubeconfigs from 1Password and merge into `~/.kube/config` as described in **`https://github.com/symmatree/tiles/blob/main/docs/dev-setup.md`** (Kubeconfig section). The same merge pattern applies for other clusters so one `~/.kube/config` is not tied to a single project.
