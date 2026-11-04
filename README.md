# ecommerce-blue-green

A demo store on AWS EC2 that releases automatically, with no downtime and automatic rollback.

## The problem and the fix

An e-commerce company has frequent deployment failures, manual server setup, and downtime during releases.

| Problem | Fix | Where |
|---|---|---|
| Manual server setup | Terraform creates the server; Ansible configures it | `terraform/`, `ansible/` |
| Frequent deployment failures | Automated tests, a smoke test before any traffic moves, and automatic rollback | `.github/workflows/`, `scripts/deploy.sh` |
| Downtime during releases | Blue-green deployment: nginx switches to the new version only once it passes its checks | `scripts/deploy.sh`, `nginx/` |
| Problems found too late | Prometheus alerts and a Grafana dashboard showing each release's traffic | `monitoring/` |

## How a release works

1. GitHub Actions runs the tests and builds the image.
2. Ansible applies the server configuration and runs `scripts/deploy.sh deploy <version>`.
3. The new version starts on the idle color while the live color keeps serving.
4. It must pass its health check and a smoke test covering the catalog and an order. If it fails, it never receives traffic.
5. nginx reloads and sends new requests to the new color. Its old workers finish requests already in flight.
6. For 30 seconds, requests through nginx confirm the release. Three failures switch traffic back automatically.
7. The previous color keeps running, so `deploy.sh rollback` can return to it in seconds.

## Measured results

From `evidence/release-scenarios.txt`: real releases on a `t3.small`, under steady traffic of 20 requests per
second from inside the server and 5 per second from a laptop over the internet.

| Scenario | Outcome | Failed requests, inside the server | Failed requests, laptop |
|---|---|---|---|
| Good release, v1.1.0 | Switched to green | 0 of 1,991 | 0 of 208 |
| Unhealthy release | Rejected, traffic never moved | 0 of 1,992 | 0 of 212 |
| Release that fails after going live | Rolled back automatically in about 4 seconds | 43 of 1,993 | 5 of 212 |
| Manual rollback to v1.0.0 | Switched in about 1 second | 0 of 1,993 | 0 of 213 |
| Good release, v1.4.0 | Switched to green | 0 of 1,994 | 0 of 212 |

A fault that only appears after going live can't be caught before the switch, so users see errors until the
rollback finishes. Rollback limits that window; it doesn't remove it.

These runs show no failed requests at these traffic levels on one server. They aren't a load test, and one server
is still a single point of failure.

## Deploy

On Windows, or anywhere with Terraform and AWS credentials:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

Then from WSL or Linux, on a network that allows outbound SSH:

```bash
mkdir -p ~/.ssh && install -m 600 ansible/id_ed25519 ~/.ssh/shop-key
cd ansible && ANSIBLE_CONFIG=./ansible.cfg APP_VERSION=v1.0.0 ansible-playbook playbook.yml
```

## Access

- Store: the `store_url` output
- Grafana: the `grafana_url` output, user `admin`, dashboard **Shop Releases**
- Grafana password: `terraform -chdir=terraform output -raw grafana_admin_password`

## Operating it

On the server:

```bash
sudo /opt/shop/scripts/deploy.sh status
sudo /opt/shop/scripts/deploy.sh rollback
sudo tail -30 /opt/shop/deploy-history.log
```

## Pipeline

Every push to `main` tests, builds and releases. Pull requests only test and build. Add these repository secrets
under Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `EC2_HOST` | The `public_ip` output |
| `EC2_SSH_KEY` | The contents of `ansible/id_ed25519` |
| `GRAFANA_ADMIN_PASSWORD` | The `grafana_admin_password` output |

To demonstrate rollback, open Actions → **Test, build and release** → **Run workflow** and choose a `bad_release`
fault. The run should fail while the live store keeps its previous version.

## Repeating the measurements

From the `ansible` directory in WSL or Linux. This makes real releases, including two deliberately bad ones:

```bash
bash ../scripts/run_release_scenarios.sh
```

## Tear down

```bash
terraform -chdir=terraform destroy
```
