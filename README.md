# blog-haproxy-letsencrypt

Companion code for the blog post
[HAProxy with Let's Encrypt: Automated HTTPS Certificate Management](https://blog.bsdserver.nl/haproxy-with-lets-encrypt-automated-https-certificate-management/).

It builds the post's **Complete Production Setup** on one HAProxy node, with the zero-downtime
renewal from Method 3.

**HAProxy (the post's configuration):**
- `:80` answers ACME challenges and sends everything else to HTTPS with a 301.
- `:443` loads every certificate in `/etc/haproxy/certs/` with `strict-sni`, h2 and the post's
  security headers.
- Routing by Host:
  - `api.example.com` goes to `api_servers`;
  - `app.example.com` goes to `app_servers` (cookie persistence);
  - everything else goes to `web_servers`.
- Stats at `:8404/stats` (basic auth) and Prometheus `/metrics`.

**The ACME challenge server:**
- a systemd unit running `python3 -m http.server 8080` in `/var/www/letsencrypt`;
- HAProxy sends `/.well-known/acme-challenge/` there.

**Certificates:**
- `certbot certonly --webroot`, one lineage per entry in `haproxy_letsencrypt_certificates`;
- HAProxy stays up while they are requested.
- The first request needs a certificate in `/etc/haproxy/certs` before HAProxy can start. The role
  uses a temporary self-signed one, `_bootstrap.pem`, and removes it once the real certificates
  are in place.

**The post's deploy hook** (`/etc/letsencrypt/renewal-hooks/deploy/haproxy.sh`):
- it builds `<name>.pem` from `fullchain.pem` and `privkey.pem`;
- it updates a loaded certificate through the runtime API (`set ssl cert`, then
  `commit ssl cert` in a separate session), so no reload is needed;
- it reloads only for a certificate HAProxy has not loaded yet;
- with HAProxy stopped it only writes the file, which HAProxy loads when it starts.

`certbot renew` runs it from that directory, once per renewed certificate, so the timer passes no
`--deploy-hook`. `certbot certonly` does not run directory hooks, so the first request passes it.

**Renewal:** the post's `certbot-renewal.service` and `.timer`, run twice a day (`certbot renew`).

HAProxy comes from the official repositories:
- Ubuntu 24.04: `ppa:vbernat/haproxy-3.3`. 3.3 is the newest branch built for 24.04. It is
  short-lived and not LTS.
- Debian 13: haproxy.debian.net, 3.4 LTS.
- RHEL 9: AppStream (2.8), with certbot from EPEL, as in the post.
  - The role adds `RuntimeDirectory=haproxy` to the unit, because the RHEL unit does not create
    `/run/haproxy` for the admin socket.

## Requirements

- Terraform >= 1.6 and a Proxmox VE API token, if you want Terraform to create the VM.
- ansible-core >= 2.15 on your workstation.
- DNS for every name in `haproxy_letsencrypt_certificates` pointing at the HAProxy host, and port 80
  reachable from the internet.

## Quick start

```bash
# 1. VM (optional: any Ubuntu 24.04, Debian 13 or RHEL 9 host works)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init && terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory.yml

# 2. Your domains and backends in group_vars/all/vars.yml, the stats password in vault.yml
cd ../ansible
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml && ansible-vault encrypt group_vars/all/vault.yml

# 3. First against Let's Encrypt staging, then for real
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --ask-vault-pass \
  -e haproxy_letsencrypt_acme_server=https://acme-staging-v02.api.letsencrypt.org/directory
# For real certificates, remove the staging lineages first
# (certbot delete --cert-name <name>, rm /etc/haproxy/certs/<name>.pem).
ansible-playbook site.yml --ask-vault-pass

# 4. The post's checks
ansible-playbook ../tests/verify.yml --ask-vault-pass
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -dates
```

## Variables

All variables are in `ansible/roles/haproxy_letsencrypt/defaults/main.yml`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `haproxy_install_version` | `3.3` (Ubuntu), `3.4` (Debian) | HAProxy branch from the official repository |
| `haproxy_letsencrypt_certificates` | example.com + www, api.example.com, app.example.com | `name` (lineage and PEM name) and `domains` |
| `haproxy_letsencrypt_email` | `admin@example.com` | ACME account email |
| `haproxy_letsencrypt_acme_server` | `""` (Let's Encrypt production) | ACME directory, e.g. staging |
| `haproxy_letsencrypt_stats_password` | `vault_haproxy_letsencrypt_stats_password` | stats password (user `admin`) |
| `haproxy_letsencrypt_api_host` / `haproxy_letsencrypt_app_host` | `api.example.com` / `app.example.com` | Host names routed to the API and app servers |
| `haproxy_letsencrypt_web_servers`, `_api_servers`, `_app_servers` | the post's addresses | backend servers |
| `demo_backend_enabled` | `false` | DEMO: run header-echo servers on the HAProxy host (see `tests/demo-vars.yml`) |

Notes:
- The certbot package also ships its own `certbot.timer`. It does no harm next to the post's
  `certbot-renewal.timer`, because renewal is skipped until a certificate is due. You can
  disable one of the two.
- DNS-01 for wildcard certificates (Method 4 in the post) is not automated here; it needs
  credentials for your DNS provider.

## How it was tested

Without the real Let's Encrypt (see `tests/lab.sh`):
- **Pebble**, Let's Encrypt's test ACME server, issued the certificates.
- **pebble-challtestsrv** pointed every name at the HAProxy host.
- **Ubuntu 24.04 systemd container** with HAProxy 3.3.17 and certbot 2.9.0:
  - `site.yml` run twice; the second run reports `changed=0`;
  - `tests/verify.yml -e verify_renewal=true` passes.
- **`tests/verify.yml` covers:**
  - SNI for every name, and `strict-sni` rejecting an unknown name;
  - the HTTP redirect, while ACME challenges are still served over HTTP;
  - HSTS and `X-Forwarded-Proto`;
  - Host routing;
  - stats auth;
  - the renewal timer;
  - `certbot renew --dry-run`;
  - a forced `certbot renew` (no `--deploy-hook`): the hook runs exactly once and HAProxy serves the
    new certificate through the runtime API, without a reload.
- **CI** (`.gitlab-ci.yml`) runs yamllint, ansible-lint (production profile), `terraform fmt`,
  `validate` and tflint.

## License

MIT
