# Google Cloud provider module — VPC + subnet + static public IP +
# firewall + compute instance. Mirrors the genesis-google role
# (gce-network) and the ufw role on the host.

variable "name" {
  type    = string
  default = "streisand"
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
  type = string
  # Family reference: resolves to the newest Ubuntu 24.04 LTS image at boot;
  # date-pinned names (ubuntu-24-04-v*) get garbage-collected by Canonical.
  default = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
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

resource "google_compute_network" "streisand" {
  name    = "${var.name}-network"
  project = var.project
}

resource "google_compute_subnetwork" "streisand" {
  name          = "${var.name}-subnet"
  project       = var.project
  region        = var.region
  network       = google_compute_network.streisand.id
  ip_cidr_range = "10.100.0.0/24"
}

resource "google_compute_address" "streisand" {
  name    = "${var.name}-ip"
  project = var.project
  region  = var.region
}

resource "google_compute_firewall" "streisand" {
  name    = "${var.name}-firewall"
  project = var.project
  network = google_compute_network.streisand.id

  dynamic "allow" {
    for_each = var.tcp_ports
    content {
      protocol = "tcp"
      ports    = [tostring(allow.value)]
    }
  }
  dynamic "allow" {
    for_each = var.udp_ports
    content {
      protocol = "udp"
      ports    = [tostring(allow.value)]
    }
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["streisand"]
}

resource "google_compute_instance" "streisand" {
  name         = var.name
  project      = var.project
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["streisand"]

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network    = google_compute_network.streisand.id
    subnetwork = google_compute_subnetwork.streisand.id
    access_config {
      nat_ip = google_compute_address.streisand.address
    }
  }

  # No ssh-keys metadata: the guest agent cannot create "admin" on noble
  # (preexisting group) and the operator user is provisioned by cloud-init.
  metadata = {
    user-data = var.user_data
  }

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

output "server_ip" {
  value       = google_compute_address.streisand.address
  description = "Static public IPv4 of the instance"
}
output "instance_id" {
  value = google_compute_instance.streisand.id
}