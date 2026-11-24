# Google Cloud root module.
#
#   cd providers/google
#   tofu init
#   tofu apply -var-file=../../examples/google.tfvars

terraform {
  required_version = ">= 1.8.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "project" { type = string }
variable "region" {
  type    = string
  default = "us-east1"
}
variable "zone" {
  type    = string
  default = "us-east1-b"
}
variable "machine_type" {
  type    = string
  default = "e2-small"
}
variable "image" {
  type    = string
  default = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
}
variable "ssh_public_key" { type = string }
variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_rsa"
}
variable "service_account_email" {
  type    = string
  default = ""
}

variable "server_name" {
  type    = string
  default = "streisand"
}
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
variable "output_dir" {
  type    = string
  default = "generated-docs"
}

variable "upstream_dns_servers" {
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
  description = "Upstream DNS forwarders for dnsmasq and the nginx resolver."
}

module "streisand_server" {
  source                   = "../../modules/streisand-server"
  upstream_dns_servers     = var.upstream_dns_servers
  bootstrap_ssh_public_key = var.ssh_public_key
}

module "service_ports" {
  source              = "../../modules/service-ports"
  openvpn_enabled     = var.openvpn_enabled
  openconnect_enabled = var.openconnect_enabled
  shadowsocks_enabled = var.shadowsocks_enabled
  stunnel_enabled     = var.stunnel_enabled
  tor_enabled         = var.tor_enabled
  wireguard_enabled   = var.wireguard_enabled
}

module "gcp" {
  source                = "../../modules/gcp"
  name                  = var.server_name
  region                = var.region
  zone                  = var.zone
  machine_type          = var.machine_type
  image                 = var.image
  user_data             = module.streisand_server.bootstrap_user_data
  project               = var.project
  service_account_email = var.service_account_email
  tcp_ports             = module.service_ports.tcp_ports
  udp_ports             = module.service_ports.udp_ports
}

module "streisand_deploy" {
  source               = "../../modules/streisand-deploy"
  server_name          = var.server_name
  server_ip            = module.gcp.server_ip
  ssh_user             = "streisand-admin"
  ssh_port             = 22
  ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  ssh_public_key       = var.ssh_public_key
  # login user's home: the upload step scp's as the login user; the deploy
  # module elevates with sudo only for the run/fetch steps.
  boot_dir                  = "/home/streisand-admin/streisand-boot"
  provider_name             = "google"
  vpn_clients               = var.vpn_clients
  openvpn_enabled           = var.openvpn_enabled
  openconnect_enabled       = var.openconnect_enabled
  shadowsocks_enabled       = var.shadowsocks_enabled
  ssh_forward_enabled       = var.ssh_forward_enabled
  sshuttle_enabled          = var.sshuttle_enabled
  stunnel_enabled           = var.stunnel_enabled
  tinyproxy_enabled         = var.tinyproxy_enabled
  tor_enabled               = var.tor_enabled
  wireguard_enabled         = var.wireguard_enabled
  cloudflared_enabled       = var.cloudflared_enabled
  ad_blocking_enabled       = var.ad_blocking_enabled
  shadowsocks_v2ray_enabled = var.shadowsocks_v2ray_enabled
  streisand_domain          = var.streisand_domain
  streisand_admin_email     = var.streisand_admin_email
  provision_script          = module.streisand_server.provision_script
  upload_files              = module.streisand_server.upload_files
  output_dir                = var.output_dir
  upstream_dns_servers      = var.upstream_dns_servers
}

output "server_ip" {
  value       = module.gcp.server_ip
  description = "Static public IPv4 of the instance"
}
output "instance_id" {
  value = module.gcp.instance_id
}
output "gateway_url" {
  value       = module.streisand_deploy.gateway_url
  description = "HTTPS gateway URL (HTTP basic-auth user 'streisand' - not the OS user; password in generated-docs)"
}
output "artifacts_dir" {
  value       = module.streisand_deploy.artifacts_dir
  description = "Local directory with VPN profiles and the gateway password"
}
output "ssh_command" {
  value       = "ssh -i ${pathexpand(var.ssh_private_key_file)} streisand-admin@${module.gcp.server_ip}"
  description = "SSH command to the provisioned server"
}