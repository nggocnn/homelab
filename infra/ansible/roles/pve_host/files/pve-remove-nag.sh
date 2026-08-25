#!/bin/sh
# Idempotently neuter the "no valid subscription" dialog in the PVE web UI.
# Re-applied automatically after every proxmox-widget-toolkit upgrade via the
# APT hook in /etc/apt/apt.conf.d/99-pve-no-nag.
set -e
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
[ -f "$JS" ] || exit 0
grep -q 'orig_cmd(); return;' "$JS" && exit 0
sed -i "s/\(checked_command: function *(orig_cmd) *{\)/\1 orig_cmd(); return;/" "$JS"
exit 0
