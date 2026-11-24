# streisand-server module
#
# Library of assets shared by every provider deployment:
#   * bootstrap_user_data - cloud-config applied at instance creation
#     (gateway/firewall/base-service packages plus OS hardening: sshd, sysctl,
#     networkd/service0, dnsmasq base config, resolved stub off, unattended-upgrades).
#   * provision_script — the bash provisioning script
#     (uploaded and executed over SSH by the streisand-deploy module).
#   * ancillary files (wordlist, nginx.conf, docs templates, ad-block
#     tooling, ocserv PAM, apparmor override) uploaded alongside it.
#
# Service configuration is NOT part of the bootstrap because cloud-provider
# user_data caps (DigitalOcean: 16 KB) cannot hold the full provision script.

variable "upstream_dns_servers" {
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
  description = "Upstream forwarders rendered into the dnsmasq base config."
}

variable "bootstrap_ssh_public_key" {
  type        = string
  default     = ""
  description = "Operator public key authorized on the bootstrapped operator users (empty = create none)."
}

locals {
  sshd_config = file("${path.module}/files/sshd_config")
  netdev      = file("${path.module}/files/10-service0.netdev")
  network     = file("${path.module}/files/10-service0.network")
  serv_net    = file("${path.module}/files/service-net.conf")
  dnsmasq_conf = templatefile("${path.module}/templates/dnsmasq.conf.tftpl", {
    server_lines = join("\n", [for s in var.upstream_dns_servers : "server=${s}"])
  })

  # Operator logins, created by cloud-init when a key is supplied.
  # Never name a user "admin": noble ships a preexisting group "admin", so
  # useradd aborts (exit 9) and the user is uncreatable (cloud-init and the
  # GCE guest agent both hit this wall).
  bootstrap_users_yaml = var.bootstrap_ssh_public_key == "" ? "" : join("\n", [
    "users:",
    "  - name: streisand-admin",
    "    groups: [sudo, adm]",
    "    shell: /bin/bash",
    "    sudo: ALL=(ALL) NOPASSWD:ALL",
    "    lock_passwd: true",
    "    ssh_authorized_keys:",
    "      - ${var.bootstrap_ssh_public_key}",
    "  - name: streisand",
    "    groups: [adm]",
    "    shell: /bin/bash",
    "    lock_passwd: true",
    "    ssh_authorized_keys:",
    "      - ${var.bootstrap_ssh_public_key}",
  ])
}

locals {
  bootstrap_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    sshd_config_b64      = base64encode(local.sshd_config)
    service0_netdev_b64  = base64encode(local.netdev)
    service0_network_b64 = base64encode(local.network)
    service_net_b64      = base64encode(local.serv_net)
    dnsmasq_conf_b64     = base64encode(local.dnsmasq_conf)
    bootstrap_users_yaml = local.bootstrap_users_yaml
  })

  upload_files = {
    "nginx.conf"                             = file("${path.module}/files/nginx.conf")
    "header.html"                            = file("${path.module}/files/header.html")
    "footer.html"                            = file("${path.module}/files/footer.html")
    "adblocking/download-blocklists"         = file("${path.module}/files/adblocking/download-blocklists")
    "adblocking/transform-domain-list"       = file("${path.module}/files/adblocking/transform-domain-list")
    "adblocking/transform-host-list"         = file("${path.module}/files/adblocking/transform-host-list")
    "adblocking/download-blocklists.service" = file("${path.module}/files/adblocking/download-blocklists.service")
    "adblocking/download-blocklists.timer"   = file("${path.module}/files/adblocking/download-blocklists.timer")
    "english.txt"                            = file("${path.module}/files/english.txt")
    "ocserv-pam"                             = file("${path.module}/files/ocserv-pam")
    "apparmor-local-override"                = file("${path.module}/files/apparmor-local-override")
  }
}

output "bootstrap_user_data" {
  description = "Cloud-config user_data for instance creation (fits 16 KB)"
  value       = local.bootstrap_user_data
}

output "provision_script" {
  description = "Provisioning script uploaded to the server"
  value       = file("${path.module}/templates/provision.sh")
}

output "upload_files" {
  description = "Static files staged next to provision.sh on the server"
  value       = local.upload_files
}