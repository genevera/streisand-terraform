# DigitalOcean provider module — VM + SSH key + cloud firewall.
# Mirrors the genesis-digitalocean role (digital_ocean_sshkey +
# digital_ocean_droplet) and the ufw role on the host.

variable "name" {
  type    = string
  default = "streisand"
}
variable "region" {
  type    = string
  default = "nyc3"
}
variable "size" {
  type    = string
  default = "s-1vcpu-1gb"
}
variable "image" {
  type    = string
  default = "ubuntu-24-04-x64"
}
variable "ssh_public_key" { type = string }
variable "ssh_key_name" {
  type    = string
  default = "streisand"
}
variable "tags" {
  type    = list(string)
  default = ["streisand"]
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

resource "digitalocean_ssh_key" "streisand" {
  name       = var.ssh_key_name
  public_key = var.ssh_public_key
}

resource "digitalocean_droplet" "streisand" {
  name      = var.name
  image     = var.image
  region    = var.region
  size      = var.size
  tags      = var.tags
  user_data = var.user_data

  ssh_keys = [digitalocean_ssh_key.streisand.id]

  lifecycle {
    create_before_destroy = true
  }
}

resource "digitalocean_firewall" "streisand" {
  name = "${var.name}-firewall"

  droplet_ids = [digitalocean_droplet.streisand.id]

  dynamic "inbound_rule" {
    for_each = var.tcp_ports
    content {
      protocol         = "tcp"
      port_range       = tostring(inbound_rule.value)
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  }
  dynamic "inbound_rule" {
    for_each = var.udp_ports
    content {
      protocol         = "udp"
      port_range       = tostring(inbound_rule.value)
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

output "server_ip" {
  value       = digitalocean_droplet.streisand.ipv4_address
  description = "Public IPv4 of the provisioned droplet"
}
output "droplet_id" {
  value = digitalocean_droplet.streisand.id
}