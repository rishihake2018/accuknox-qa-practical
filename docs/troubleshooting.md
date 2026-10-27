# Troubleshooting

## Docker build or response problems

- Confirm Docker Desktop is running with `docker info`.
- Inspect logs with `docker logs wisecow` and health state with `docker inspect --format='{{.State.Health.Status}}' wisecow`.
- Check that port 4499 is not already in use. Change the host-side mapping (for example `-p 4500:4499`) if needed.
- The image requires `fortune`, `cowsay`, and `socat`; these are installed by the Dockerfile.
- A local `docker build` does not necessarily make the image available to Docker Desktop Kubernetes. In this environment a `Never`-pull test reported `ErrImageNeverPull`; publish the image to GHCR or use the cluster runtime's supported image-import mechanism before rollout.

## Kubernetes Pod does not become Ready

Use `kubectl get pods -n wisecow`, `kubectl describe pod -n wisecow`, and `kubectl logs deployment/wisecow -n wisecow`. `ImagePullBackOff` generally means the image is unavailable to the cluster or the GHCR package is private. Check whether Docker Desktop Kubernetes shares the local image store; otherwise publish to a registry reachable by the cluster or import the image using the runtime's documented method. Do not alter unrelated namespaces or deployments.

Repeated `Readiness probe failed: EOF`, probe timeouts, or port-forward resets can indicate the Pod is still running the older, single-connection netcat/FIFO listener. That listener only accepted the next connection after its current handler finished, so overlapping probes or forwarded requests could see a closed/reset socket. The updated image uses a Socat fork-per-connection listener and returns complete HTTP/1.1 headers. The Deployment also has a startup probe and five-second readiness/liveness request timeouts; the probes still request the real application endpoint so server failures are not hidden.

Confirm the Pod's image ID and restart count before retrying port-forward. Locally built images are not visible to this Docker Desktop Kubernetes runtime. Once the new image is published, update only the Wisecow Deployment to its commit-SHA tag and wait for rollout:

```powershell
$sha = git rev-parse HEAD
kubectl apply -f k8s/deployment.yaml
kubectl set image deployment/wisecow wisecow="ghcr.io/nyrahul/wisecow:sha-$sha" -n wisecow
kubectl rollout status deployment/wisecow -n wisecow --timeout=180s
kubectl get pods -n wisecow -o wide
kubectl describe deployment wisecow -n wisecow
```

Only retry port-forward after the new Pod is Ready and its Image ID matches the published image:

```powershell
kubectl port-forward service/wisecow 4499:4499 -n wisecow
```

## Ingress or HTTPS does not work

Check `kubectl get ingressclass` and confirm the controller is running before expecting an Ingress to route traffic. Verify `kubectl get ingress -n wisecow` and `kubectl describe ingress wisecow -n wisecow`. Ensure the `wisecow-tls` Secret exists in the `wisecow` namespace and contains a certificate with `DNS:wisecow.local` in its SAN. Check the ingress controller's logs and verify the host resolves to the forwarded/controller address. Self-signed certificates require explicit trust (`curl --cacert`) and will not be publicly trusted.

## Health scripts

- `python -m unittest discover -s tests -v` runs network-independent checker tests.
- The system monitor is for Linux/WSL, not native PowerShell or CMD. In WSL, install procps if needed (`sudo apt install procps`) and run `bash scripts/system_health_monitor.sh --test-alerts`.
- A monitor exit status of `1` indicates a threshold alert or an unsuccessful system check. Exit status `2` indicates invalid arguments or missing prerequisites.
