#!/usr/bin/env bash
# Refresh on-disk cluster credentials from 1Password.
#
# SECURITY MODEL
#   Only YOU can create the 1Password session (op account add + `eval $(op
#   signin)` needs your password/passkey -- no agent can do that). This script
#   only *reads* from an already-active session and lands secrets on disk with
#   tight perms. Coding agents then consume the files (~/.kube/config etc.);
#   they never touch `op` and no secret is ever printed to the terminal/chat.
#
#   Contains only `op://` reference paths -- no secret material -- so it is safe
#   to keep in the public repo.
#
# USAGE
#   eval "$(op signin)"      # you, interactively -- see NOTES-notebook.md
#   ./refresh-secrets.sh     # or `bash ubuntu-zsh/refresh-secrets.sh`
#
# Source of truth for the op:// paths and merge pattern:
#   https://github.com/symmatree/tiles/blob/main/docs/dev-setup.md
#   https://github.com/symmatree/tiles/blob/main/docs/secrets.md
set -euo pipefail
umask 077

# --- preconditions ---------------------------------------------------------
command -v op >/dev/null 2>&1 || {
	echo "ERROR: 1Password CLI (op) not found." >&2
	exit 1
}
if ! op whoami >/dev/null 2>&1; then
	cat >&2 <<'EOF'
ERROR: no active 1Password session.

Sign in first (interactive -- only you can do this):
    op account add --address my.1password.com --email <you@example.com>   # first time only
    eval "$(op signin)"

Then re-run this script.
EOF
	exit 1
fi
echo "1Password session OK: $(op whoami | tr '\n' ' ')"

VAULT="tiles-secrets"

# Read an op reference into a file via a .part temp, so a failed/empty read
# never truncates an existing good file. Never echoes the secret.
read_to_file() {
	local ref="$1" dest="$2" mode="${3:-600}"
	local tmp="${dest}.part"
	mkdir -p "$(dirname "$dest")" # umask 077 above -> new dirs are 700
	if op read "$ref" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
		chmod "$mode" "$tmp"
		mv -f "$tmp" "$dest"
		echo "  wrote $dest"
	else
		rm -f "$tmp"
		echo "  SKIP  $dest (op read failed or empty: $ref)" >&2
		return 1
	fi
}

# --- talosconfigs ----------------------------------------------------------
# Per secrets.md these are used with `talosctl --talosconfig <file>` (merging is
# unreliable for talos), so keep them as separate per-cluster files.
echo "Talos configs -> ~/.talos/"
read_to_file "op://$VAULT/tiles-test-talosconfig/notesPlain" "$HOME/.talos/tiles-test.yaml" || true
read_to_file "op://$VAULT/tiles-talosconfig/notesPlain" "$HOME/.talos/tiles.yaml" || true

# --- kubeconfigs -----------------------------------------------------------
# Land each as a staging file, then flatten-merge into ~/.kube/config, keeping
# any other-project clusters already present there (see ordering note below).
echo "Kube configs -> staging, then merge into ~/.kube/config"
mkdir -p "$HOME/.kube" # umask 077 above -> 700
got_kube=0
if read_to_file "op://$VAULT/tiles-test-kubeconfig/notesPlain" "$HOME/.kube/tiles-test.yaml"; then got_kube=1; fi
if read_to_file "op://$VAULT/tiles-kubeconfig/notesPlain" "$HOME/.kube/tiles.yaml"; then got_kube=1; fi

if [ "$got_kube" = 1 ]; then
	# kubectl merge is first-file-wins. List the freshly-pulled tiles files
	# FIRST so a refresh (cluster rebuild / cert rotation) actually overrides
	# the stale tiles entries already in ~/.kube/config. The existing config
	# goes last: its other-project clusters have no key collision, so they are
	# still preserved.
	parts=()
	[ -f "$HOME/.kube/tiles-test.yaml" ] && parts+=("$HOME/.kube/tiles-test.yaml")
	[ -f "$HOME/.kube/tiles.yaml" ] && parts+=("$HOME/.kube/tiles.yaml")
	[ -f "$HOME/.kube/config" ] && parts+=("$HOME/.kube/config")
	KUBECONFIG="$(
		IFS=:
		echo "${parts[*]}"
	)" kubectl config view --flatten >"$HOME/.kube/config.merged"
	chmod 600 "$HOME/.kube/config.merged"
	mv -f "$HOME/.kube/config.merged" "$HOME/.kube/config"
	echo "  merged ~/.kube/config (contexts below)"
	kubectl config get-contexts -o name | sed 's/^/    /'
fi

echo "Done. Verify: kubectl config get-contexts ; talosctl --talosconfig ~/.talos/tiles.yaml version --client"
