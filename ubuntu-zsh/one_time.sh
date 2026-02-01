#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
SAVE_DIR=$(pwd)

sudo apt-get update &&
	sudo apt-get dist-upgrade -y &&
	DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
		--no-install-recommends \
		ansible \
		apt-transport-https ca-certificates \
		apt-utils dialog \
		sudo procps file git openssh-server \
		tree bsdmainutils \
		ubuntu-server aspell

ansible-playbook -v "$SAVE_DIR/install-tools.ansible.yaml" -i "localhost," --connection=local
