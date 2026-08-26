#!/usr/bin/env bash
# Reissue the *.nggocnn.io wildcard from the internal CA.
#
# Nothing renews this automatically - that is the cost of an internal CA over
# ACME. Run before the current certificate lapses, then re-run
# playbooks/33-traefik.yml to deploy it.
#
#   ./issue-wildcard.sh [days]
set -euo pipefail
cd "$(dirname "$0")"
DAYS="${1:-825}"   # 825 days is the ceiling browsers accept for locally-trusted roots
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
SECRETS=../../secrets/pki.sops.yaml
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The CA private key never touches disk unencrypted outside this temp dir.
python3 - "$SECRETS" "$WORK" <<'PY'
import subprocess, sys, yaml, pathlib, os
secrets, work = sys.argv[1], pathlib.Path(sys.argv[2])
d = yaml.safe_load(subprocess.run(["sops","-d",secrets], capture_output=True, text=True,
                                  check=True, env=os.environ).stdout)
for k, f in (("internal_ca_crt","ca.crt"), ("internal_ca_key","ca.key")):
    p = work / f
    p.write_text(d[k]); p.chmod(0o600)
PY

cat > "$WORK/ext.cnf" <<'EOF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
DNS.1 = *.nggocnn.io
DNS.2 = nggocnn.io
EOF

openssl genrsa -out "$WORK/wildcard.key" 2048
openssl req -new -key "$WORK/wildcard.key" -out "$WORK/wildcard.csr" \
  -subj "/C=VN/O=nggocnn homelab/CN=*.nggocnn.io"
openssl x509 -req -in "$WORK/wildcard.csr" \
  -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
  -out "$WORK/wildcard.crt" -days "$DAYS" -sha256 -extfile "$WORK/ext.cnf"

python3 - "$SECRETS" "$WORK" <<'PY'
import subprocess, sys, yaml, pathlib, os
secrets, work = sys.argv[1], pathlib.Path(sys.argv[2])
d = yaml.safe_load(subprocess.run(["sops","-d",secrets], capture_output=True, text=True,
                                  check=True, env=os.environ).stdout)
d["wildcard_crt"] = (work/"wildcard.crt").read_text()
d["wildcard_key"] = (work/"wildcard.key").read_text()
plain = work/"new.yaml"
plain.write_text(yaml.safe_dump(d, default_style="|", sort_keys=True))
enc = subprocess.run(["sops","-e",str(plain)], capture_output=True, text=True,
                     check=True, env=os.environ).stdout
pathlib.Path(secrets).write_text(enc)
PY

openssl x509 -in "$WORK/wildcard.crt" -noout -subject -dates
echo "Reissued. Run: ansible-playbook playbooks/33-traefik.yml"
