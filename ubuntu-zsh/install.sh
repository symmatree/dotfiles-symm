#!/usr/bin/env bash
set -euxo pipefail
cd "$(dirname "$0")"
SAVE_DIR=$(pwd)

# If you just installed, add account and log in via `eval $(op signin)`
op whoami

cd "${SAVE_DIR}/homedir"
for d in */; do
	[ -d "$d" ] || continue
	echo "Stowing ${d}"
	(stow --dotfiles -t "${HOME}" -S "$d")
done

cd "${SAVE_DIR}/etc"
echo "Stowing sudoers.d"
sudo stow --target /etc/sudoers.d -v -S sudoers.d

old_umask=$(umask)
echo "Setting restrictive umask"
umask 0077

if ! test -d "$HOME/.zshcustom/plugins/zsh-autosuggestions"; then
	mkdir -p "$HOME/.zshcustom/plugins"
	git clone https://github.com/zsh-users/zsh-autosuggestions "$HOME/.zshcustom/plugins/zsh-autosuggestions"
fi

if ! test -d "$HOME/.zshcustom/plugins/zsh-syntax-highlighting"; then
	mkdir -p "$HOME/.zshcustom/plugins"
	git clone https://github.com/zsh-users/zsh-syntax-highlighting "$HOME/.zshcustom/plugins/zsh-syntax-highlighting"
fi

if ! test -d "$HOME/.tmux/plugins/tpm"; then
	mkdir -p "$HOME/.tmux/plugins"
	git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
fi

if [ -d "$HOME/.oh-my-zsh" ]; then
	echo "oh-my-zsh installed, skipping"
else
	echo "Installing oh my zsh"
	sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
	cd "${SAVE_DIR}"
fi

echo "Restoring old umask $old_umask"
umask "$old_umask"

if [ "$(basename "$SHELL")" != "zsh" ]; then
	echo "Changing default shell to zsh"
	chsh -s "$(which zsh)"
fi
