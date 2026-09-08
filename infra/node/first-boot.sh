#!/usr/bin/env bash
# =============================================================================
#  Proxmox VE first-boot hook  (runs once, ordering = "fully-up")
#  Embedded into the ISO via:
#     proxmox-auto-install-assistant prepare-iso ... --on-first-boot first-boot.sh
# =============================================================================

set -u
exec > >(tee -a /var/log/pve-first-boot.log) 2>&1
echo "=== pve first-boot start: $(date -Is) ==="

# ----------------------------------------------------------------------------
# TOGGLES
# ----------------------------------------------------------------------------
DO_NIC_FIX=1          # e1000e EEE + offload workaround (the unit-hang fix)
DO_REPOS=1            # switch enterprise -> no-subscription, kill the apt error
DO_UPGRADE=1          # apt full-upgrade on first boot
DO_PACKAGES=1         # ethtool, lm-sensors, intel-microcode, etc.
DO_SSH_HARDEN=1       # root login by key only (needs root-ssh-keys in answer.toml)
DO_HOSTS=1            # static /etc/hosts entries for all three nodes
DO_TUNING=1           # swappiness, journal cap, C-state guard
DO_IOMMU=1            # PCIe passthrough ready; harmless if unused
DO_NO_NAG=1           # suppress the "No valid subscription" dialog in the web UI

# Your cluster - used by DO_HOSTS
declare -A NODES=(
  [pve-01]=10.10.10.11
  [pve-02]=10.10.10.12
  [pve-03]=10.10.10.13
)
DOMAIN="nggocnn.internal"

# ----------------------------------------------------------------------------
# helper: append kernel parameters on either bootloader
#   ZFS root  -> systemd-boot, /etc/kernel/cmdline, proxmox-boot-tool refresh
#   ext4/LVM  -> GRUB, /etc/default/grub, update-grub
# ----------------------------------------------------------------------------
add_cmdline() {
  local param="$1" key="${1%%=*}"
  if [ -f /etc/kernel/cmdline ]; then
    grep -q -- "$key" /etc/kernel/cmdline && return 0
    sed -i "1 s|\$| $param|" /etc/kernel/cmdline
    proxmox-boot-tool refresh
  elif [ -f /etc/default/grub ]; then
    grep -q -- "$key" /etc/default/grub && return 0
    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 $param\"|" /etc/default/grub
    update-grub
  fi
  echo "kernel cmdline: added $param (takes effect after reboot)"
}

# ----------------------------------------------------------------------------
# 1. Intel e1000e "Detected Hardware Unit Hang" workaround
# ----------------------------------------------------------------------------
# The I219-LM in the P330 Tiny wedges its TX ring under load.
# Intel has acknowledged TSO as the trigger; EEE/LPI renegotiation makes it worse on some switches.
# Turn off both, on every boot AND every time the link device reappears (EEE resets on renegotiation).
if [ "$DO_NIC_FIX" = 1 ]; then
  echo "--- installing e1000e workaround ---"

  cat > /usr/local/sbin/pve-nic-fix <<'FIXEOF'
#!/bin/bash
# Disable EEE + TX offloads on Intel NICs known to hit the e1000e unit hang.
shopt -s nullglob
for path in /sys/class/net/*; do
  ifc=${path##*/}
  [ -e "$path/device/driver" ] || continue          # skip lo, bridges, veth, taps
  drv=$(basename "$(readlink -f "$path/device/driver")")
  case "$drv" in
    e1000e|e1000) ;;
    *) continue ;;
  esac
  /usr/sbin/ethtool --set-eee "$ifc" eee off        &>/dev/null
  /usr/sbin/ethtool -K "$ifc" tso off gso off gro off &>/dev/null
  logger -t pve-nic-fix "EEE + tso/gso/gro disabled on $ifc (driver=$drv)"
done
FIXEOF
  chmod 755 /usr/local/sbin/pve-nic-fix

  cat > /etc/systemd/system/pve-nic-fix.service <<'EOF'
[Unit]
Description=Disable EEE/TSO on Intel e1000e NICs (hardware unit hang workaround)
After=network-pre.target
Wants=network-pre.target
Before=networking.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-nic-fix

[Install]
WantedBy=multi-user.target
EOF

  # Re-apply whenever the NIC (re)appears - covers driver resets and hotplug.
  cat > /etc/udev/rules.d/70-pve-nic-fix.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", ENV{ID_NET_DRIVER}=="e1000e", TAG+="systemd", ENV{SYSTEMD_WANTS}+="pve-nic-fix.service"
EOF

  systemctl daemon-reload
  systemctl enable pve-nic-fix.service
  udevadm control --reload-rules
  /usr/local/sbin/pve-nic-fix          # apply right now, don't wait for a reboot
fi

# ----------------------------------------------------------------------------
# 2. Repositories: enterprise -> no-subscription
# ----------------------------------------------------------------------------
if [ "$DO_REPOS" = 1 ]; then
  echo "--- repositories ---"
  SUITE=$(. /etc/os-release && echo "$VERSION_CODENAME")   # trixie on PVE 9

  # deb822 layout (PVE 9): disable rather than delete, so upgrades stay sane.
  for f in /etc/apt/sources.list.d/pve-enterprise.sources \
           /etc/apt/sources.list.d/ceph.sources; do
    [ -f "$f" ] || continue
    grep -q '^Enabled:' "$f" || echo 'Enabled: false' >> "$f"
    sed -i 's/^Enabled:.*/Enabled: false/' "$f"
  done
  # legacy .list layout (PVE 8)
  for f in /etc/apt/sources.list.d/pve-enterprise.list \
           /etc/apt/sources.list.d/ceph.list; do
    [ -f "$f" ] && sed -i 's/^deb /#deb /' "$f"
  done

  cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $SUITE
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

  apt-get update
fi

# ----------------------------------------------------------------------------
# 3. Packages + updates
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

if [ "$DO_PACKAGES" = 1 ]; then
  echo "--- packages ---"
  apt-get install -y --no-install-recommends \
    ethtool lm-sensors smartmontools nvme-cli \
    intel-microcode \
    htop iotop iftop iperf3 tmux vim curl jq \
    chrony
  systemctl enable --now chrony      # tight clocks matter for corosync
  yes | sensors-detect --auto >/dev/null 2>&1 || true
fi

if [ "$DO_UPGRADE" = 1 ]; then
  echo "--- full-upgrade ---"
  apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
fi

# ----------------------------------------------------------------------------
# 3b. Subscription nag dialog
# ----------------------------------------------------------------------------
# Patches the client-side check in proxmox-widget-toolkit.
if [ "$DO_NO_NAG" = 1 ]; then
  echo "--- subscription nag ---"

  cat > /usr/local/sbin/pve-no-nag <<'NAGEOF'
#!/bin/bash
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
[ -f "$JS" ] || exit 0
grep -q 'orig_checked_command' "$JS" && exit 0          # already patched

sed -i.bak -e 's#\(^ *checked_command: *function *(orig_cmd) *{$\)#\1orig_cmd();},orig_checked_command:function(orig_cmd){#' "$JS"

if ! grep -q 'orig_checked_command' "$JS"; then
  cp -f "$JS.bak" "$JS"
  logger -t pve-no-nag "PATTERN NOT FOUND - upstream JS changed, no patch applied"
  exit 1
fi

systemctl restart pveproxy.service
logger -t pve-no-nag "patched $JS and restarted pveproxy"
NAGEOF
  chmod 755 /usr/local/sbin/pve-no-nag

  # Re-apply after any package operation that replaces the toolkit.
  cat > /etc/apt/apt.conf.d/99-pve-no-nag <<'EOF'
DPkg::Post-Invoke { "[ -x /usr/local/sbin/pve-no-nag ] && /usr/local/sbin/pve-no-nag >/dev/null 2>&1 || true"; };
EOF

  /usr/local/sbin/pve-no-nag || echo "!! nag patch skipped - see: journalctl -t pve-no-nag"
fi

# ----------------------------------------------------------------------------
# 4. SSH: keys only for root
# ----------------------------------------------------------------------------
if [ "$DO_SSH_HARDEN" = 1 ] && [ -s /root/.ssh/authorized_keys ]; then
  echo "--- ssh hardening ---"
  install -d -m 755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-pve-hardening.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  if sshd -t; then
    systemctl reload ssh || systemctl reload sshd
  else
    echo "!! sshd config test failed, reverting"
    rm -f /etc/ssh/sshd_config.d/10-pve-hardening.conf
  fi
else
  echo "--- ssh hardening SKIPPED (no authorized_keys - you'd lock yourself out) ---"
fi

# ----------------------------------------------------------------------------
# 5. /etc/hosts for all cluster members
# ----------------------------------------------------------------------------
# corosync resolves node names
if [ "$DO_HOSTS" = 1 ]; then
  echo "--- /etc/hosts ---"
  for n in "${!NODES[@]}"; do
    ip=${NODES[$n]}
    grep -qE "[[:space:]]$n(\$|[[:space:].])" /etc/hosts && continue
    echo "$ip $n.$DOMAIN $n" >> /etc/hosts
  done
fi

# ----------------------------------------------------------------------------
# 6. Small tunings
# ----------------------------------------------------------------------------
if [ "$DO_TUNING" = 1 ]; then
  echo "--- tuning ---"
  echo 'vm.swappiness = 10' > /etc/sysctl.d/99-pve-local.conf
  sysctl -p /etc/sysctl.d/99-pve-local.conf >/dev/null

  # Cap the journal so a chatty VM can't eat the root filesystem.
  install -d /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=1G\n' > /etc/systemd/journald.conf.d/size.conf
  systemctl restart systemd-journald
fi

# ----------------------------------------------------------------------------
# 7. IOMMU
# ----------------------------------------------------------------------------
if [ "$DO_IOMMU" = 1 ]; then
  echo "--- iommu ---"
  add_cmdline "intel_iommu=on"
  add_cmdline "iommu=pt"
  printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' > /etc/modules-load.d/vfio.conf
fi

echo "=== pve first-boot done: $(date -Is) ==="