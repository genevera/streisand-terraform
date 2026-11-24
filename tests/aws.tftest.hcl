mock_provider "aws" {}
mock_provider "null" {}

run "plan" {
  command = plan

  module {
    source = "./providers/aws"
  }

  variables {
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuqVef4gMulZ0SD6oxaAkvu339yKwUcKyIEVxaDoqyR streisand-test"
    ami            = "ami-12345678"
  }

  override_resource {
    target = module.aws.aws_eip.streisand
    values = { public_ip = "1.2.3.4" }
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
