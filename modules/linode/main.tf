# Linode provider module — instance + firewall + authorized SSH key.
# Mirrors the genesis-linode role and the ufw role on the host.

variable "name" {
  type    = string
  default = "streisand"
}
variable "region" {
  type    = string
  default = "us-east"
}
variable "type" {
  type    = string
  default = "g6-nanode-1"
}
variable "image" {
  type    = string
  default = "linode/ubuntu-24.04"
}
variable "ssh_public_key" { type = string }
variable "ssh_key_label" {
  type    = string
  default = "streisand"
}
variable "user_data" { type = string }

variable "tcp_ports" {
  type    = list(number)
  default = [22, 443, 636, 993, 4443, 8530, 8443, 9443]
}
variable "udp_ports" {
  type    = list(number)
  default = [443, 8757, 4443, 8530, 51820]
}

resource "linode_sshkey" "streisand" {
  label   = var.ssh_key_label
  ssh_key = var.ssh_public_key
}

resource "linode_instance" "streisand" {
  label           = var.name
  region          = var.region
  type            = var.type
  image           = var.image
  authorized_keys = [linode_sshkey.streisand.ssh_key]

  metadata {
    user_data = base64encode(var.user_data)
  }

  tags = ["streisand"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "linode_firewall" "streisand" {
  label = "${var.name}-firewall"

  dynamic "inbound" {
    for_each = var.tcp_ports
    content {
      label    = "streisand-tcp-${inbound.value}"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = tostring(inbound.value)
      ipv4     = ["0.0.0.0/0"]
    }
  }
  dynamic "inbound" {
    for_each = var.udp_ports
    content {
      label    = "streisand-udp-${inbound.value}"
      action   = "ACCEPT"
      protocol = "UDP"
      ports    = tostring(inbound.value)
      ipv4     = ["0.0.0.0/0"]
    }
  }

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  linodes = [linode_instance.streisand.id]
}

output "server_ip" {
  value       = tolist(linode_instance.streisand.ipv4)[0]
  description = "Public IPv4 of the provisioned Linode instance"
}
output "instance_id" {
  value = linode_instance.streisand.id
}