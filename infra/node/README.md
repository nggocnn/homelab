# Unattended Proxmox VE

## Target configuration

| | pve-01 | pve-02 | pve-03 |
| --- | --- | --- | --- |
| FQDN | `pve-01.nggocnn.internal` | `pve-02.nggocnn.internal` | `pve-03.nggocnn.internal` |
| IP | `10.10.10.11/24` | `10.10.10.12/24` | `10.10.10.13/24` |

**`.internal` for node identity:** ICANN permanently reserved it from root-zone
delegation, so it can never collide and doesn't depend on renewing a domain name registration.

## Files

| File | Role |
| --- | --- |
| [`answer.toml`](./answer.toml) | Master answer file. |
| [`first-boot.sh`](./first-boot.sh) | Runs once on first boot. Baked into ISO. |

---

## Step 0 — Before you touch anything

**Verify SSH keys:** `root-ssh-keys` in `answer.toml` is an array — put in the public key there:

```bash
cat ~/.ssh/*.pub               # put public key into `root-ssh-keys` in `answer.toml`
ssh-keygen -lf ~/.ssh/id_ed25519.pub    # confirms you hold the private half
```

With `DO_SSH_HARDEN=1` there is no password fallback over SSH.
A wrong key means three nodes reachable only from the physical console.

**BIOS on all three machines**:

| Setting | Value | Why |
| --- | --- | --- |
| Intel Virtualization Technology (VT-x) | Enabled | KVM won't start without it |
| VT-d | Enabled | required by the IOMMU flag in first-boot.sh |
| Enhanced Power Saving Mode | **Disabled** | caps link negotiation, deepens idle states |
| After Power Loss | Power On | node returns by itself after an outage |
| Wake on LAN | Enabled | remote power-on |
| Secure Boot | either | PVE 9 supports Secure Boot |

---

## Step 1 — Setup build host

Setup required tools:

```bash
sudo wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -O /usr/share/keyrings/proxmox-archive-keyring.gpg

# expect 136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
sha256sum /usr/share/keyrings/proxmox-archive-keyring.gpg

sudo tee /etc/apt/sources.list.d/pve-install-repo.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

sudo apt update
sudo apt install -y proxmox-auto-install-assistant xorriso whois
```

Download the ISO:

```bash
wget https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso -O proxmox-ve_9.2-1.iso
```

---

## Step 2 — Generate three answer files

Generate the root password hash with `mkpasswd` - from the `whois` package.

```bash
cd ./infra/node
mkpasswd -m yescrypt > root-password.hash
chmod 600 root-password.hash
```

Now derive the three per-node files. `answer.toml` and `root-password.hash` are the only
inputs; nothing else is hand-edited.

```bash
rm -f answer-*.toml

HASH=$(cat root-password.hash)
for n in 01 02 03; do
  sed -e "s|^fqdn = .*|fqdn = \"pve-$n.nggocnn.internal\"|" \
      -e "s|^cidr = .*|cidr = \"10.10.10.$((10#$n + 10))/24\"|" \
      -e "s|^root-password-hashed = .*|root-password-hashed = \"$HASH\"|" \
      answer.toml > answer-$n.toml
  chmod 600 answer-$n.toml
done

grep -H '^fqdn\|^cidr' answer-0*.toml
```

Expect `.11/.12/.13` against `pve-01/02/03.nggocnn.internal`.

---

## Step 3 — Build three ISOs

```bash
rm -f pve-*.iso         # cleanup before build

for n in 01 02 03; do
  proxmox-auto-install-assistant validate-answer answer-$n.toml || break
  proxmox-auto-install-assistant prepare-iso proxmox-ve_9.2-1.iso \
    --fetch-from iso \
    --answer-file answer-$n.toml \
    --on-first-boot first-boot.sh \
    --output pve-$n.iso
done

for n in 01 02 03; do proxmox-auto-install-assistant inspect-iso pve-$n.iso; done
```

Expect fetch mode `iso` **and** an answer file listed.

---

## Step 4 — Write the sticks

**Label each stick physically before writing.**

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,LABEL,FSTYPE
```

```bash
sudo dd if=pve-01.iso of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync
sync
```

Update `/dev/sdX` with whole device (`/dev/sdb`), not a partition (`/dev/sdb1`).

Recover an unlabeled stick's identity:

```bash
sudo mount -o ro /dev/sdX /mnt && grep -rh 'fqdn' /mnt --include='*.toml'; sudo umount /mnt
```

Verify a write:

```bash
SZ=$(stat -c %s pve-01.iso); sha256sum pve-01.iso
sudo dd if=/dev/sdX bs=1M iflag=fullblock status=none | head -c $SZ | sha256sum
```

---

## Step 5 — Install

- Stick in, power on, **F12**, boot the USB, take the default **Automated Installation**
- It wipes `nvme0n1`, installs, reboots, then runs `first-boot.sh` doing an `apt full-upgrade`.

### Verify each node

```bash
ssh root@10.10.10.11

NIC=$(ls /sys/class/net | grep -m1 ^en)
ethtool --show-eee "$NIC"            # EEE status: disabled
ethtool -k "$NIC" | grep -E 'tcp-segmentation|generic-(segmentation|receive)'   # all off
journalctl -t pve-nic-fix
tail -50 /var/log/pve-first-boot.log
apt update                           # no 401 from the enterprise repo
pveversion
```

The `full-upgrade` installs a newer kernel and the IOMMU flags only apply on the next boot;
`first-boot.sh` does not reboot.

---

## Step 6 — Hand over to Ansible

`first-boot.sh` runs once and then nothing owns what it set — upgrades quietly undo parts
of it. [`infra/ansible`](../ansible) takes ownership and forms the cluster:

```bash
cd ../ansible
ansible-playbook playbooks/00-host.yml     # make first-boot's work permanent
ansible-playbook playbooks/01-cluster.yml  # form cluster `pve` on pve-01
```
