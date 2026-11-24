# streisand-deploy module
#
# Drives post-boot provisioning over SSH from the operator machine:
#   1. wait for the cloud-init bootstrap to finish
#   2. upload provision.sh + rendered env.sh + ancillary files
#   3. execute provision.sh
#   4. fetch the client artifacts to ./generated-docs/<server_name>/
#
# All steps run through local-exec + ssh/scp so the exit status propagates
# to `terraform apply`. Re-running apply re-provisions (trigger = script
# hash); already-configured services are skipped by the idempotent script.

variable "server_ip" { type = string }
variable "ssh_user" {
  type    = string
  default = "root"
}
variable "ssh_port" {
  type    = number
  default = 22
}
variable "ssh_private_key_file" { type = string }
variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Operator public key; uploaded so provision.sh can install it in /root/.ssh/authorized_keys (root recovery login)."
}
variable "server_name" { type = string }
variable "boot_dir" {
  type    = string
  default = "/root"
}

# service configuration passed through to env.sh
variable "provider_name" { type = string }
variable "vpn_clients" {
  type    = number
  default = 10
}
variable "openvpn_enabled" {
  type    = bool
  default = true
}
variable "openconnect_enabled" {
  type    = bool
  default = true
}
variable "shadowsocks_enabled" {
  type    = bool
  default = true
}
variable "ssh_forward_enabled" {
  type    = bool
  default = true
}
variable "sshuttle_enabled" {
  type    = bool
  default = false
}
variable "stunnel_enabled" {
  type    = bool
  default = true
}
variable "tinyproxy_enabled" {
  type    = bool
  default = true
}
variable "tor_enabled" {
  type    = bool
  default = false
}
variable "wireguard_enabled" {
  type    = bool
  default = true
}
variable "cloudflared_enabled" {
  type    = bool
  default = false
}
variable "ad_blocking_enabled" {
  type    = bool
  default = false
}
variable "shadowsocks_v2ray_enabled" {
  type    = bool
  default = false
}
variable "streisand_domain" {
  type    = string
  default = ""
}
variable "streisand_admin_email" {
  type    = string
  default = ""
}
variable "upstream_dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "1.0.0.1"]
}
variable "cloudflared_port" {
  type    = number
  default = 5053
}

# asset library inputs (from streisand-server outputs)
variable "provision_script" { type = string }
variable "upload_files" {
  description = "Static asset bundle from streisand-server.upload_files"
  type        = map(string)
  default     = {}
}

variable "output_dir" {
  description = "Local directory for fetched client artifacts"
  type        = string
  default     = "generated-docs"
}

locals {
  enable_le = var.streisand_domain != "" ? "true" : "false"

  env_sh = templatefile("${path.module}/../streisand-server/templates/env.sh.tftpl", {
    provider           = var.provider_name
    server_name        = var.server_name
    ssh_port           = var.ssh_port
    vpn_clients        = var.vpn_clients
    enable_openvpn     = var.openvpn_enabled ? "true" : "false"
    enable_openconnect = var.openconnect_enabled ? "true" : "false"
    enable_shadowsocks = var.shadowsocks_enabled ? "true" : "false"
    enable_ssh_forward = var.ssh_forward_enabled ? "true" : "false"
    enable_sshuttle    = var.sshuttle_enabled ? "true" : "false"
    enable_stunnel     = var.stunnel_enabled ? "true" : "false"
    enable_tinyproxy   = var.tinyproxy_enabled ? "true" : "false"
    enable_tor         = var.tor_enabled ? "true" : "false"
    enable_wireguard   = var.wireguard_enabled ? "true" : "false"
    enable_cloudflared = var.cloudflared_enabled ? "true" : "false"
    enable_ad_blocking = var.ad_blocking_enabled ? "true" : "false"
    enable_v2ray       = var.shadowsocks_v2ray_enabled ? "true" : "false"
    enable_le          = local.enable_le
    domain             = var.streisand_domain
    admin_email        = var.streisand_admin_email
    upstream_dns       = join(" ", var.upstream_dns_servers)
    cloudflared_port   = var.cloudflared_port
    public_ip          = var.server_ip
  })

  local_staging = "${path.cwd}/.streisand-upload"

  trigger_hash = sha256(join("\n", [
    var.provision_script,
    var.ssh_public_key,
    local.env_sh,
    var.server_ip,
    jsonencode({
      openvpn     = var.openvpn_enabled
      openconnect = var.openconnect_enabled
      shadowsocks = var.shadowsocks_enabled
      ssh_forward = var.ssh_forward_enabled
      sshuttle    = var.sshuttle_enabled
      stunnel     = var.stunnel_enabled
      tinyproxy   = var.tinyproxy_enabled
      tor         = var.tor_enabled
      wireguard   = var.wireguard_enabled
      cloudflared = var.cloudflared_enabled
      ad_blocking = var.ad_blocking_enabled
      v2ray       = var.shadowsocks_v2ray_enabled
      vpn_clients = var.vpn_clients
      domain      = var.streisand_domain
    })
  ]))

  artifacts_dir = "${abspath(var.output_dir)}/${var.server_name}"
}

resource "local_file" "upload_provision" {
  filename = "${local.local_staging}/provision.sh"
  content  = var.provision_script
}

resource "local_file" "upload_env" {
  filename = "${local.local_staging}/streisand-env.sh"
  content  = local.env_sh
}

# provision.sh installs this into /root/.ssh/authorized_keys (recovery login).
resource "local_file" "upload_pubkey" {
  count    = var.ssh_public_key == "" ? 0 : 1
  filename = "${local.local_staging}/streisand_ssh_pubkey"
  content  = "${var.ssh_public_key}\n"
}


resource "local_file" "upload_files" {
  for_each = var.upload_files
  filename = "${local.local_staging}/${each.key}"
  content  = each.value
}
# 1. wait for cloud-init  2. upload  3. run  4. fetch artifacts
resource "null_resource" "provision" {
  triggers = {
    hash = local.trigger_hash
  }
  # the local-exec scp copies the whole staging dir; it must exist first
  depends_on = [
    local_file.upload_provision,
    local_file.upload_env,
    local_file.upload_files,
    local_file.upload_pubkey,
  ]
  provisioner "local-exec" {
    quiet = false
    environment = {
      S_HOST      = var.server_ip
      S_USER      = var.ssh_user
      S_PORT      = tostring(var.ssh_port)
      S_KEY       = pathexpand(var.ssh_private_key_file)
      S_BOOT      = var.boot_dir
      S_STAGE     = local.local_staging
      S_ARTIFACTS = local.artifacts_dir
    }
    command = <<-EOT
      set -euo pipefail
      # Shell functions, not command strings: expanding "$SSH" re-splits the
      # value, so the escaped quotes around the key path survive as literal
      # characters and ssh never loads the key it was given.
      ssh_run() {
        ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=15 -o LogLevel=ERROR -o ServerAliveInterval=30 \
            -i "$S_KEY" -p "$S_PORT" "$@"
      }
      scp_run() {
        scp -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=15 -o LogLevel=ERROR \
            -i "$S_KEY" -P "$S_PORT" "$@"
      }
      DEST="$S_USER@$S_HOST"

      echo "==> waiting for the SSH port on $S_HOST"
      # TCP probe only: the operator user does not exist until cloud-init's
      # users stage runs, so a per-user ssh here would loop on "permission
      # denied" for the entire bootstrap and then wedge.
      for i in $(seq 1 120); do
        # /dev/tcp is a bash extension; run it under bash explicitly.
        if bash -c 'exec 3<>/dev/tcp/"$S_HOST"/"$S_PORT"' 2>/dev/null; then break; fi
        sleep 10
        if [ "$i" = "120" ]; then echo "timed out waiting for SSH port on $S_HOST" >&2; exit 1; fi
      done

      echo "==> waiting for cloud-init to finish"
      # ssh exits 255 while sshd is still down; the status command fails
      # until cloud-init exists. Both are just "not ready" for this loop.
      for i in $(seq 1 90); do
        if ssh_run "$DEST" "command -v cloud-init >/dev/null && cloud-init status 2>/dev/null | grep -q 'status: done'" 2>/dev/null; then
          break
        fi
        sleep 10
        if [ "$i" = "90" ]; then echo "timed out waiting for cloud-init" >&2; exit 1; fi
      done

      # cloud-init created the operator account; this also proves its key works
      ssh_run "$DEST" true

      echo "==> uploading provisioning files"
      ssh_run "$DEST" "mkdir -p $S_BOOT"
      scp_run -r "$S_STAGE/." "$DEST:$S_BOOT/"
      ssh_run "$DEST" "chmod 700 $S_BOOT/provision.sh $S_BOOT/streisand-env.sh"

      echo "==> provisioning streisand (this takes a while; log: /var/log/streisand-provision.log)"
      # sudo -n: the operator user (streisand-admin, cloud-init NOPASSWD) cannot
      # write /etc or run apt directly; cloud-init status/keys are the same on
      # every provider.
      ssh_run "$DEST" "sudo -n env STREISAND_BOOT=$S_BOOT bash $S_BOOT/provision.sh"

      echo "==> fetching client artifacts"
      mkdir -p "$S_ARTIFACTS" "$S_ARTIFACTS/server-gateway"
      # root-owned files, so copy over a privileged pipe instead of plain scp
      ssh_run "$DEST" "sudo -n tar -cf - -C /var/www/streisand ." | tar -xf - -C "$S_ARTIFACTS/server-gateway"
      ssh_run "$DEST" "sudo -n tar -cf - -C $S_BOOT/streisand-local ." | tar -xf - -C "$S_ARTIFACTS/"
      ssh_run "$DEST" "sudo -n cat /var/log/streisand-provision.log" > "$S_ARTIFACTS/provision.log" || true
      echo "==> done: client configs in $S_ARTIFACTS"
    EOT
  }
}

output "artifacts_dir" {
  value       = local.artifacts_dir
  description = "Local directory containing fetched gateway files (VPN profiles, passwords)"
}

output "gateway_url" {
  value       = "https://${var.server_ip}"
  description = "Streisand gateway URL (auth: user streisand / fetched gateway password)"
}