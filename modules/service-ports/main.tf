# Computes the public firewall port set implied by the enabled Streisand
# services.
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
variable "stunnel_enabled" {
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
variable "ssh_port" {
  type    = number
  default = 22
}

locals {
  # 636/tcp openvpn direct, 8757/udp openvpn udp, 443 tcp+udp sslh+gateway,
  # 993/tcp stunnel, 4443 tcp+udp ocserv, 8530 tcp+udp shadowsocks,
  # 51820/udp wireguard, 8443/tcp tor orport, 9443/tcp tor obfs4.
  tcp_ports = concat(
    [var.ssh_port, 443],
    var.openvpn_enabled ? [636] : [],
    var.openvpn_enabled && var.stunnel_enabled ? [993] : [],
    var.openconnect_enabled ? [4443] : [],
    var.shadowsocks_enabled ? [8530] : [],
    var.tor_enabled ? [8443, 9443] : [],
  )

  udp_ports = concat(
    [443],
    var.openvpn_enabled ? [8757] : [],
    var.openconnect_enabled ? [4443] : [],
    var.shadowsocks_enabled ? [8530] : [],
    var.wireguard_enabled ? [51820] : [],
  )
}

output "tcp_ports" {
  value = distinct(local.tcp_ports)
}

output "udp_ports" {
  value = distinct(local.udp_ports)
}