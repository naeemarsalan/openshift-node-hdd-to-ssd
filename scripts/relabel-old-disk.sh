#!/usr/bin/env bash
# Relabel the OLD (HDD) RHCOS install's boot/root filesystems so the labels
# "boot" and "root" are unique to the new SSD install.
#
# The SSD's ESP grub.cfg has no bootuuid.cfg and falls back to
# `search --label boot`; RHCOS also refuses to boot with a duplicate "boot"
# label. The old disk's ESP pins by UUID, so it stays bootable as a fallback.
#
# Run as root on the node while it is still booted from the old disk.
# Usage: relabel-old-disk.sh /dev/<old-disk>      e.g. /dev/sdb
set -euo pipefail

OLD_DISK="${1:?usage: $0 /dev/<old-disk>}"

# Partition 3 is /boot (ext4) on RHCOS.
e2label "${OLD_DISK}3" hdd-boot

# Root is XFS and mounted; XFS can be relabelled online through any mount
# point of that filesystem (/var is on root in a default RHCOS layout).
xfs_io -c "label -s hdd-root" /var

lsblk -o NAME,FSTYPE,LABEL,UUID
