#!/usr/bin/env bash
#
# verify-in-vm.sh -- run test-assemble.sh inside a throwaway KVM guest that HAS a
# btrfs-capable kernel. Needed because the notebook host's Talos kernel has no
# btrfs support (can't mount btrfs), while the assembly test must actually mount
# subvolumes. The guest boots an Ubuntu cloud image, cloud-init installs
# btrfs-progs + rsync, runs the assembly test, tees results to the serial
# console, and powers off. The host reads the serial log and greps the verdict.
#
# Prereqs (host): qemu-system-x86, /dev/kvm, cloud-image-utils, an already-
# downloaded cloud image at .vm/jammy.img. All installed/fetched by the caller.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/.vm"
IMG="$VM/jammy.img"
DISK="$VM/disk.qcow2"
SEED="$VM/seed.iso"
SERIAL="$VM/serial.log"

b64() { base64 -w0 "$1"; }

# Build cloud-init user-data: drop both scripts into the guest, install deps,
# run the test, capture verdict to the serial console, power off.
cat >"$VM/user-data" <<EOF
#cloud-config
write_files:
  - path: /root/assemble-btrfs.sh
    permissions: '0755'
    encoding: b64
    content: $(b64 "$HERE/assemble-btrfs.sh")
  - path: /root/test-assemble.sh
    permissions: '0755'
    encoding: b64
    content: $(b64 "$HERE/test-assemble.sh")
runcmd:
  - [ bash, -c, "echo '===VM-BOOTED==='> /dev/ttyS0" ]
  - [ bash, -c, "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq btrfs-progs rsync e2fsprogs > /dev/ttyS0 2>&1" ]
  - [ bash, -c, "cd /root && ./test-assemble.sh > /dev/ttyS0 2>&1; echo \"===TEST-EXIT=\$?===\" > /dev/ttyS0" ]
  - [ bash, -c, "poweroff" ]
EOF

cat >"$VM/meta-data" <<EOF
instance-id: btrfs-spike-1
local-hostname: btrfs-spike
EOF

cloud-localds "$SEED" "$VM/user-data" "$VM/meta-data"

# Fresh overlay disk each run so the base image stays pristine.
rm -f "$DISK"
qemu-img create -f qcow2 -b "$IMG" -F qcow2 "$DISK" 8G >/dev/null

: >"$SERIAL"
echo "### booting guest (serial -> $SERIAL) ..."
# user-mode net (for apt), KVM accel, serial to file, no graphics.
timeout 600 qemu-system-x86_64 \
	-enable-kvm -m 2048 -smp 2 \
	-drive file="$DISK",if=virtio,format=qcow2 \
	-drive file="$SEED",if=virtio,format=raw \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	-nographic -serial file:"$SERIAL" \
	-no-reboot 2>&1 | tail -3 || true

echo "### guest exited. verdict lines:"
grep -aE "===VM-BOOTED===|PASS:|FAIL:|ALL CHECKS PASSED|SOME CHECKS FAILED|===TEST-EXIT" "$SERIAL" || true
