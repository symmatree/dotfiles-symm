# dotfiles

## Ansible

Basically just using Ansible as a fancy scripting engine, not least
because I like its consistent handling for custom apt repos.

## Current stuff

* Need to download id_jupyterhub ssh key manually
* Need to delete/move .zshrc and .gitconfig to let stow replace them
* If we miss any vscode deps then have to `sudo apt --fix-broken install`

## WSL-specific

After install, `code` is `/mnt/c/Users/symmetry/AppData/Local/Programs/Microsoft VS Code/bin/code`. On Bifrost where it works, we have
`/home/symmetry/.vscode/cli/servers/.../server/bin/remote-cli/code`

Need to comment out the 'is code a command' test and rerun to force the install.
