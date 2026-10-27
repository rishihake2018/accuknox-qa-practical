# Wisecow

Wisecow is a small Bash HTTP service that responds on port 4499 with a fortune displayed by `cowsay`. This repository also contains a non-root container image, Kubernetes manifests, GitHub Actions workflows, and independent application/system health-check tools.

## Architecture

- `wisecow.sh` serves the response on TCP port 4499 using Socat's fork-per-connection listener.
- `Dockerfile` installs `fortune`, `cowsay`, and Socat; the container runs as UID 10001.
- `k8s/` defines the `wisecow` namespace, a single-replica Deployment, ClusterIP Service, and an HTTPS Ingress for `wisecow.local`.
- `.github/workflows/docker-build.yml` builds pull requests and publishes main-branch images to GHCR.
- `.github/workflows/deploy.yml` can deploy a successfully published main-branch image to a separately reachable Kubernetes cluster.
- `scripts/` contains the Python HTTP health checker and Linux Bash system monitor.

## Prerequisites

- Docker Desktop with Docker Engine running.
- For Kubernetes steps: `kubectl` configured for the intended cluster.
- For HTTPS Ingress: an installed Ingress controller, `openssl`, and (for the Helm example) Helm.
- Python 3.10+ for running the HTTP checker and its tests (the checker itself uses only the standard library).
- Linux or WSL 2 Ubuntu for the system monitor. It is not a native PowerShell/CMD script.

## Build and run with Docker

From PowerShell in the repository directory:

```powershell
docker build -t ghcr.io/nyrahul/wisecow:latest .
docker run --rm -d --name wisecow -p 4499:4499 ghcr.io/nyrahul/wisecow:latest
curl.exe --fail http://localhost:4499/
docker inspect --format='{{.State.Health.Status}}' wisecow
docker stop wisecow
```

The application returns HTML containing a `<pre>` block. To run it in the foreground instead, omit `-d`. The image uses Debian slim, installs only its runtime dependencies, and runs unprivileged. Its Socat listener handles concurrent health probes and requests; its Docker health check requests the same HTTP endpoint.

## Kubernetes deployment

The deployment uses `ghcr.io/nyrahul/wisecow:latest` and `IfNotPresent`. Docker Desktop Kubernetes in this environment does **not** share images built by the host Docker CLI. A test Pod using the locally built image with `imagePullPolicy: Never` failed with `ErrImageNeverPull`. Building the image locally therefore does not update the image available to Kubernetes. Publish the new image to GHCR (or import it using a supported runtime-specific method) before changing the Deployment.

After the updated source has been committed and pushed to `main`, wait for the **Build and Publish Wisecow** workflow to succeed. The CI workflow first builds the local test image, runs its repeated/concurrent HTTP integration tests, then publishes `sha-<commit>` and `latest` to GHCR. Once published, update only the Wisecow Deployment (no cluster reset or unrelated resources):

```powershell
$sha = git rev-parse HEAD
kubectl apply -f k8s/deployment.yaml
kubectl set image deployment/wisecow wisecow="ghcr.io/nyrahul/wisecow:sha-$sha" -n wisecow
kubectl rollout status deployment/wisecow -n wisecow --timeout=180s
kubectl get pods -n wisecow -o wide
kubectl describe deployment wisecow -n wisecow
```

For private GHCR packages, configure an image-pull Secret before the rollout. Check `kubectl get pods -n wisecow` and `kubectl describe pod -n wisecow` to confirm the new image is running.

PowerShell:

```powershell
kubectl apply -f k8s/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/wisecow --timeout=60s
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml -f k8s/ingress.yaml
kubectl get pods,service,ingress -n wisecow
kubectl rollout status deployment/wisecow -n wisecow --timeout=180s
```

Port-forward the ClusterIP Service for local **HTTP** access; no Ingress controller is needed for this check:

```powershell
kubectl port-forward service/wisecow 4499:4499 -n wisecow
```

In another PowerShell window (after the updated image has been published and rolled out):

```powershell
curl.exe --fail http://localhost:4499/
```

The cluster has no preinstalled IngressClass by default in the environment where this README was prepared. Check before configuring HTTPS:

```powershell
kubectl get ingressclass
kubectl get pods -A
```

### Local HTTPS with an Ingress controller

The Ingress manifest expects an NGINX Ingress controller named/classed `nginx`, hostname `wisecow.local`, and TLS Secret `wisecow-tls`. Installing an Ingress controller changes cluster-wide resources. Review the controller's official installation instructions and rendered manifests and obtain cluster-owner approval before installation; do not remove or reset other workloads. For a Helm-based local setup, first review the chart output, then install into its own namespace:

```powershell
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm template ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --set controller.service.type=NodePort
# After reviewing the output:
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace --set controller.service.type=NodePort
kubectl get ingressclass
```

Create a self-signed certificate with a Subject Alternative Name (run in WSL/Ubuntu with OpenSSL, or in PowerShell if `openssl.exe` is installed):

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout wisecow.local.key -out wisecow.local.crt \
  -subj "/CN=wisecow.local" \
  -addext "subjectAltName=DNS:wisecow.local"
kubectl create secret tls wisecow-tls -n wisecow \
  --key=wisecow.local.key --cert=wisecow.local.crt
```

On Windows, run an elevated PowerShell window and add the host mapping:

```powershell
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value '127.0.0.1 wisecow.local'
```

Forward the controller's HTTPS port in a separate terminal (the service name may differ if the chart release was customized):

```powershell
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8443:443
```

Verify hostname routing and the self-signed certificate from another PowerShell window:

```powershell
curl.exe --resolve wisecow.local:8443:127.0.0.1 --cacert wisecow.local.crt https://wisecow.local:8443/
openssl s_client -connect 127.0.0.1:8443 -servername wisecow.local
```

`--resolve` supplies DNS routing for this request, so the hosts-file edit is only needed for browser-based testing. Keep the `.key` file private; it is ignored by Git and must never be committed. A self-signed certificate is suitable only for local testing and is not trusted by browsers or the public Internet by default. Production should use a publicly trusted certificate, commonly managed by cert-manager and an ACME issuer, with DNS and renewal configured.

Kubernetes Secrets are not automatically encrypted at rest in every cluster. Restrict access to this namespace and enable the cluster's Secret encryption-at-rest facility for production.

### Rollback and cleanup

```powershell
kubectl rollout undo deployment/wisecow -n wisecow
kubectl delete -f k8s/ingress.yaml -f k8s/service.yaml -f k8s/deployment.yaml
kubectl delete -f k8s/namespace.yaml
```

The last command deletes only the dedicated `wisecow` namespace and its resources; it does not target the sample Nginx deployment. Do not run it if you want to retain Wisecow.

## GitHub Actions, GHCR, and deployment

`docker-build.yml` builds on pull requests, pushes to `main`, and manual runs. Only authorized runs on `main` publish to `ghcr.io/nyrahul/wisecow`, using `sha-<full-commit-sha>` and `latest` tags. It uses the repository-provided `GITHUB_TOKEN` with read access to source and package-write access for the build job. Fork pull requests build without logging in or publishing.

After the first package publication, check the package's GHCR visibility in GitHub **Packages**. Make it public if unauthenticated clusters should pull it; for a private package, configure a least-privilege image-pull Secret in `wisecow` and reference it from the Pod spec. The workflow does not change repository/package visibility or GitHub permissions.

The optional deploy workflow runs only after a successful `main` build workflow and only when repository variable `ENABLE_K8S_DEPLOY` is set to the exact string `true`. Configure the `production` environment and a `KUBE_CONFIG` GitHub Actions secret containing a kubeconfig for a **remote, reachable** cluster with permission to manage the `wisecow` namespace and wait for Deployment rollouts. Restrict that credential to this deployment's minimum required access. GitHub-hosted runners cannot reach a developer's local Docker Desktop cluster. Do not expose the local Kubernetes API to the Internet to enable deployment. If no remote cluster and credentials are configured, deployment remains pending and the workflow skips it.

## Application health checker

The checker makes one request by default and requires no third-party package:

```powershell
python scripts/application_health_checker.py http://localhost:4499
python scripts/application_health_checker.py https://example.com/health --timeout 3
python scripts/application_health_checker.py http://localhost:4499 --count 5 --interval 10
```

Example:

```text
[2026-10-27T10:00:00+00:00] URL: http://localhost:4499 | UP | HTTP: 200 | response_time: 12.4 ms
```

Exit code is `0` only when every requested check is UP; it is `1` for an invalid/unreachable URL or unsuccessful HTTP status, and argparse uses `2` for invalid command-line options. URLs with embedded credentials are rejected. The script prints useful error details and never requires a hardcoded target.

Run the mocked unit tests from the repository root:

```powershell
python -m unittest tests.test_application_health_checker -v
```

The Docker-backed HTTP integration tests check successive and concurrent GET requests, complete response headers/body, Docker health-check status, and non-root/read-only-rootfs settings. Build the image first, then run them:

```powershell
python -m unittest tests.test_wisecow_http -v
```

## Linux system health monitor

Run from WSL 2 Ubuntu or another Linux host. It checks CPU (one-second sample), memory (MemAvailable), disk usage for `/`, and the running process count. Linux `/proc`, `awk`, `date`, `df`, `ps` (procps), and `sleep` are required; no Python packages are needed.

```bash
bash scripts/system_health_monitor.sh
bash scripts/system_health_monitor.sh --disk-path /var --cpu-threshold 75 --memory-threshold 85 --disk-threshold 90
bash scripts/system_health_monitor.sh --repeat --interval 30 --log-file "$HOME/wisecow-health.log"
```

Thresholds can also be set with `CPU_THRESHOLD`, `MEMORY_THRESHOLD`, `DISK_THRESHOLD`, `DISK_PATH`, `LOG_FILE`, and `INTERVAL`. A measured value must be **greater than** its threshold to trigger an alert. The monitor exits `0` when the pass(es) are healthy, `1` if any threshold is exceeded or a check fails, and `2` for invalid options or unsupported/missing prerequisites. `--test-alerts` safely substitutes 100% CPU, memory, and disk readings to demonstrate alerting without stressing the machine:

```bash
bash scripts/system_health_monitor.sh --test-alerts --cpu-threshold 80
```

This demonstration intentionally exits `1`. Repeated mode continues after alerts until interrupted with Ctrl+C. Process output is a count only; it does not print command arguments.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common Docker, Kubernetes, TLS, and WSL issues.

## Validation performed

Validation in the current Windows/Docker Desktop environment:

- Docker image build succeeded. Docker-backed integration tests passed for 20 successive requests, 12 concurrent requests under the Kubernetes CPU/memory limits, valid HTTP status/headers/body, Docker health status, UID 10001, and read-only root filesystem.
- Kubernetes API server dry-run accepted the updated Deployment with startup, readiness, and liveness HTTP probes. The currently running Pod is still the older GHCR image (`88ce...`), with previous probe failures/restarts. Docker Desktop Kubernetes cannot access the locally rebuilt image, so the fixed image and probe changes have **not** been rolled out to the live Pod. Port-forward stability in Kubernetes remains unverified until the updated commit is published and deployed.
- The Python unit suite passed all 6 mocked tests, including HTTP success/failure, connection failure, timeout, invalid URL, and embedded-credential rejection.
- Both Bash scripts passed `bash -n`. The system monitor's safe `--test-alerts` simulation reported all 3 expected alerts and returned its expected nonzero status.
- All 6 Kubernetes and GitHub Actions YAML files parsed successfully.
- HTTPS is **not tested/available yet**: this cluster has no IngressClass/controller, and no TLS Secret has been created.
- GitHub Actions, GHCR publication, and remote deployment were not run; they require an authorized GitHub workflow run and (for deployment) a configured reachable cluster and secrets.

## Assessment checklist

- [x] **TESTED** Updated image build and Docker health check.
- [x] **TESTED** 20 successive and 12 concurrent HTTP requests on the updated image with 200m CPU/128Mi memory limits.
- [x] **TESTED** HTTP response status, headers/body, non-root UID, and read-only root filesystem.
- [x] **TESTED** Kubernetes API dry-run accepts startup/readiness/liveness probe settings.
- [ ] **PENDING** Live Kubernetes rollout and port-forward verification: publish the new GHCR image, then update the Deployment. Current pod is still the older image; no claim that cluster resets are fixed.
- [x] **TESTED** Python health checker and all 6 mocked unit tests.
- [x] **TESTED** Bash syntax and safe system-monitor threshold alerts.
- [x] **TESTED** YAML parsing for Kubernetes and GitHub Actions files.
- [x] **COMPLETED** TLS Ingress/hostname configuration is present; **PENDING** controller installation, TLS Secret creation, and HTTPS endpoint verification.
- [x] **COMPLETED** GHCR build/publish workflow is present; **PENDING** an authorized GitHub Actions run and package visibility configuration.
- [x] **COMPLETED** gated remote deploy workflow is present; **PENDING** reachable cluster credentials and `ENABLE_K8S_DEPLOY=true`.
- [x] **PENDING** Repository visibility and access review by its owner; this implementation does not change them.
