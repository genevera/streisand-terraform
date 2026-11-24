# Port-mapping tests for the service-ports module (provider-free).

run "default_ports" {
  command = plan

  module {
    source = "./modules/service-ports"
  }

  assert {
    condition     = contains(output.tcp_ports, 22)
    error_message = "SSH port must be open by default"
  }
  assert {
    condition     = contains(output.tcp_ports, 443)
    error_message = "the nginx gateway must listen on 443"
  }
  assert {
    condition     = contains(output.udp_ports, 51820)
    error_message = "WireGuard UDP 51820 must be open by default"
  }
  assert {
    condition     = contains(output.tcp_ports, 4443) && contains(output.udp_ports, 4443)
    error_message = "stunnel needs 4443 on TCP and UDP"
  }
  assert {
    condition     = contains(output.udp_ports, 8757)
    error_message = "OpenConnect needs UDP 8757"
  }
}

run "wireguard_off" {
  command = plan

  module {
    source = "./modules/service-ports"
  }

  variables {
    wireguard_enabled = false
  }

  assert {
    condition     = !contains(output.udp_ports, 51820)
    error_message = "disabling WireGuard must close UDP 51820"
  }
  assert {
    condition     = contains(output.tcp_ports, 443)
    error_message = "other services must keep their ports"
  }
}

run "all_off" {
  command = plan

  module {
    source = "./modules/service-ports"
  }

  variables {
    openvpn_enabled     = false
    openconnect_enabled = false
    shadowsocks_enabled = false
    stunnel_enabled     = false
    tor_enabled         = false
    wireguard_enabled   = false
  }

  assert {
    condition     = jsonencode(output.tcp_ports) == "[22,443]"
    error_message = "tcp mismatch: ${jsonencode(output.tcp_ports)}"
  }
  assert {
    condition     = jsonencode(output.udp_ports) == "[443]"
    error_message = "udp mismatch: ${jsonencode(output.udp_ports)}"
  }
}