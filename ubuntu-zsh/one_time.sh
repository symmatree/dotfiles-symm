#!/usr/bin/env bash
set -euxo pipefail
cd "$(dirname "$0")"
SAVE_DIR=$(pwd)

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y \
		--no-install-recommends \
		ansible \
		apt-transport-https ca-certificates \
		apt-utils dialog \
		sudo procps file git openssh-server \
		tree bsdmainutils \
		ubuntu-server aspell

EXTRA_VARS=""
if [ -n "${1:-}" ]; then
    EXTRA_VARS="-e @${SAVE_DIR}/vars/${1}.yaml"
fi
# shellcheck disable=SC2086
ansible-playbook -v "$SAVE_DIR/install-tools.ansible.yaml" -i "localhost," --connection=local $EXTRA_VARS

sudo apt-get dist-upgrade -y
sudo apt-get autoremove -y
