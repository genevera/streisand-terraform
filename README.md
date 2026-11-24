# Streisand — Terraform edition

Silence censorship. Automate the [effect](https://en.wikipedia.org/wiki/Streisand_effect).

This repository is a Terraform / OpenTofu rewrite of
[Streisand](https://github.com/StreisandEffect/streisand). There is no Ansible, no Vagrant, and
no `localhost` provisioning step: `terraform apply` creates the cloud VM, opens
the firewall, cloud-init bootstraps the OS, and the deploy module uploads and
runs the provisioning script over SSH. The result is a fully configured Streisand
server with OpenVPN, WireGuard, Shadowsocks, OpenConnect, Tor bridge, stunnel,
tinyproxy, ssh-forward, ad-blocking, nginx gateway, Let's Encrypt, and client
configs fetched back to your laptop.

Supported providers: **DigitalOcean, Google Cloud, AWS, Linode**. Azure and
Rackspace were dropped.

## Layout

```
streisand-terraform/
├── modules/
│   ├── streisand-server/   # cloud-init bootstrap + provision.sh bundle
│   ├── streisand-deploy/    # SSH upload / provision / artifact fetch
│   ├── service-ports/       # firewall ports implied by enabled services
│   ├── digitalocean/       # droplet + SSH key + cloud firewall
│   ├── gcp/                # instance + VPC + static IP + firewall
│   ├── aws/                # EC2 + VPC + security group + EIP
│   └── linode/             # instance + firewall
├── providers/
│   ├── digitalocean/       # root module — the first milestone
│   ├── google/
│   ├── aws/
│   └── linode/
├── tests/                  # tofu test unit tests (service-ports)
└── examples/               # per-provider .tfvars templates
```

## Quick start (DigitalOcean)

```sh
cd providers/digitalocean
export DIGITALOCEAN_TOKEN=...   # never commit this
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: server_name, region, size, ssh_public_key, ...
tofu init
tofu plan
tofu apply
```

After a successful apply you will have:

* a running droplet whose public IP is in `tofu output server_ip`
* client configs + gateway password under `./generated-docs/<server_name>/`
* the HTTPS gateway URL in `tofu output gateway_url`

Connect with the SSH command printed by `tofu output ssh_command`
(user `streisand-admin`, created by cloud-init with passwordless sudo; the
deploy automation logs in as the same user). A second, unprivileged account
`streisand` is created for routine non-root work, and the operator key is also
installed in `/root/.ssh/authorized_keys` as a recovery login (root SSH stays
enabled). Note: `streisand` is also the gateway's HTTP basic-auth username —
a different namespace from the OS account.

## Configuration

Every provider root exposes the same service toggles:

| Variable | Default | Service |
|---|---|---|
| `openvpn_enabled` | true | OpenVPN (direct + stunnel-wrapped) |
| `openconnect_enabled` | true | OpenConnect / ocserv |
| `shadowsocks_enabled` | true | Shadowsocks (v2ray optional) |
| `ssh_forward_enabled` | true | SSH forward / sshuttle user |
| `stunnel_enabled` | true | stunnel |
| `tinyproxy_enabled` | true | tinyproxy |
| `tor_enabled` | false | Tor bridge |
| `wireguard_enabled` | true | WireGuard |
| `cloudflared_enabled` | false | cloudflared DoH upstream |
| `ad_blocking_enabled` | false | ad-block lists |
| `vpn_clients` | 10 | number of generated client profiles |
| `streisand_domain` | "" | enables Let's Encrypt when set |

## Credentials

Never commit credentials. Use the provider-native environment variables:

* DigitalOcean: `DIGITALOCEAN_TOKEN`
* Google Cloud: `gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`
* AWS: `aws configure` or `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
* Linode: `LINODE_TOKEN`

## Testing

```sh
tofu test   # runs tests/ports.tftest.hcl against the service-ports module
```

## License

MIT (inherited from the original Streisand project).
## End-to-end smoke test

Plan-mode tests (`tofu test`) verify module wiring without credentials. To
verify a real deployment end-to-end, run a manual apply smoke test on at least
one provider (DigitalOcean recommended).

### Prerequisites

- Cloud account + credentials (see Credentials section)
- An SSH keypair (default `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`)
- OpenTofu >= 1.8.0

### Procedure (DigitalOcean example)

```sh
cd providers/digitalocean
export DIGITALOCEAN_TOKEN=...
cp terraform.tfvars.example terraform.tfvars
# edit: server_name, region, size, ssh_public_key (contents of ~/.ssh/id_rsa.pub)
tofu init
tofu apply -auto-approve
```

Expected outputs: `server_ip`, `gateway_url`, `artifacts_dir`, `ssh_command`.

### Verification

1. `ssh streisand-admin@<server_ip>` succeeds (use `tofu output ssh_command`).
2. `/var/www/streisand/` exists on the server with gateway files.
3. `generated-docs/<server_name>/` exists locally with VPN profiles.
4. Gateway URL responds over HTTPS: `curl -k https://<server_ip>/`.
5. At least one VPN service is listening: `ss -tlnp | grep 51820` (WireGuard).

### Teardown

```sh
tofu destroy -auto-approve
```

The same flow applies to `providers/google`, `providers/aws`, and
`providers/linode` with their respective credentials and variables
(`project` for GCP, `ami` optional for AWS).
