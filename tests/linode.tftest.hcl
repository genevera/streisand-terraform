mock_provider "linode" {}
mock_provider "null" {}

run "plan" {
  command = plan

  module {
    source = "./providers/linode"
  }

  variables {
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuqVef4gMulZ0SD6oxaAkvu339yKwUcKyIEVxaDoqyR streisand-test"
  }

  override_resource {
    target = module.linode.linode_instance.streisand
    values = { ipv4 = ["1.2.3.4"]
    id = 123 }
  }

  assert {
    condition     = length(output.server_ip) > 0
    error_message = "server_ip must be non-empty"
  }
  assert {
    condition     = can(regex("streisand", output.artifacts_dir))
    error_message = "artifacts_dir must contain the server name"
  }
  assert {
    condition     = can(regex("^https://", output.gateway_url))
    error_message = "gateway_url must start with https://"
  }
  assert {
    condition     = can(regex("ssh", output.ssh_command))
    error_message = "ssh_command must contain ssh"
  }
}
