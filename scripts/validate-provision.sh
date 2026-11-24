#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# provision.sh is a static template bundled by the streisand-server module
# (modules/streisand-server/templates/provision.sh). Syntax-check it directly.
echo "==> syntax-checking provision.sh"
bash -n "$ROOT/modules/streisand-server/templates/provision.sh"
echo "provision.sh passes bash -n"

# Cloud-init user_data must be pure ASCII: providers wrap it in MIME
# multipart parts that some data sources decode as latin-1, and cloud-init's
# YAML loader then rejects the mojibake, silently discarding the whole part
# (observed on DigitalOcean + cloud-init 26.2: "unacceptable character #x0080",
# merged config {} — packages/write_files/runcmd all skipped).
echo "==> checking cloud-init template is pure ASCII"
if grep -qP '[^\x00-\x7F]' "$ROOT/modules/streisand-server/templates/cloud-init.yaml.tftpl"; then
  echo "FAIL: non-ASCII bytes in cloud-init.yaml.tftpl (breaks user_data MIME decoding)" >&2
  grep -nP '[^\x00-\x7F]' "$ROOT/modules/streisand-server/templates/cloud-init.yaml.tftpl" >&2
  exit 1
fi

# Render + parse the template: valid YAML, no duplicate packages, and the
# unconditionally-required packages actually present.
echo "==> rendering cloud-init template and checking packages"
python3 - "$ROOT" <<'PY'
import sys, yaml
root = sys.argv[1]
s = open(f"{root}/modules/streisand-server/templates/cloud-init.yaml.tftpl").read()
assert len(s.encode()) < 16384, "user_data exceeds DigitalOcean 16 KB cap"
for v in ("sshd_config_b64", "service0_netdev_b64", "service0_network_b64", "service_net_b64", "dnsmasq_conf_b64"):
    s = s.replace("${%s}" % v, "Zm9v")
need = {"dnsmasq", "sslh", "ufw", "apache2-utils", "nginx", "markdown"}
# Parse both render paths: a root with no bootstrap key renders the users
# stanza empty; the others fill it. A malformed stanza would make cloud-init
# discard the entire part (SCHEMA_ERROR), so both variants are parsed.
variants = {
    "no-users": "",
    "operator": "\n".join([
        "users:",
        "  - name: streisand-admin",
        "    groups: [sudo, adm]",
        "    shell: /bin/bash",
        "    sudo: ALL=(ALL) NOPASSWD:ALL",
        "    lock_passwd: true",
        "    ssh_authorized_keys:",
        "      - ssh-ed25519 AAAA test",
        "  - name: streisand",
        "    groups: [adm]",
        "    shell: /bin/bash",
        "    lock_passwd: true",
        "    ssh_authorized_keys:",
        "      - ssh-ed25519 AAAA test",
    ]),
}
for label, users_yaml in variants.items():
    cfg = yaml.safe_load(s.replace("${bootstrap_users_yaml}", users_yaml))
    pkgs = cfg["packages"]
    assert len(pkgs) == len(set(pkgs)), f"{label}: duplicate package entries"
    missing = need - set(pkgs)
    assert not missing, f"{label}: missing packages: {missing}"
    assert any("DNSStubListener=no" in (f.get("content") or "")
               for f in cfg["write_files"]), f"{label}: resolved drop-in missing"
    if users_yaml:
        names = [u["name"] for u in cfg["users"]]
        assert names == ["streisand-admin", "streisand"], f"{label}: users stanza wrong: {names}"
print(f"cloud-init template OK: {len(pkgs)} packages, {len(s)} bytes, both user variants parse")
PY

# Also run tofu validate in each provider root (offline).
for provider in digitalocean google aws linode; do
  dir="$ROOT/providers/$provider"
  echo "==> tofu validate: $provider"
  cd "$dir"
  tofu init -input=false >/dev/null 2>&1
  tofu validate >/dev/null
done

echo "All providers validate; provision.sh is valid bash"
