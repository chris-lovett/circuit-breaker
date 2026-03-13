# consul-observability

An umbrella Helm chart that deploys a **monitoring and observability stack for
[Consul Service Mesh](https://developer.hashicorp.com/consul/docs/connect)**
on **OpenShift**.

| Component | Chart | Image tag |
|---|---|---|
| Prometheus Operator + Alertmanager | `prometheus-community/kube-prometheus-stack` | (operator-managed) |
| Grafana | included in kube-prometheus-stack | **12.3** |
| Loki | `grafana/loki` | **3.6.4** |
| Promtail | `grafana/promtail` | **3.6** |

Pre-built resources in this chart:

* **PodMonitor `consul-agents`** – scrapes Consul agent/server HTTP API metrics
* **PodMonitor `consul-mesh-envoy`** – scrapes Envoy sidecar admin stats on injected pods
* **ServiceMonitor `consul-services`** – optional, disabled by default
* **PrometheusRule `consul-rules`** – starter alerts (Raft leader missing, health query failures, member flapping)
* **Route `grafana`** – optional OpenShift Route for Grafana (edge TLS termination)

---

## Prerequisites

| Requirement | Version |
|---|---|
| Helm | ≥ 3.12 |
| OpenShift | ≥ 4.12 |
| Consul (via Helm) | ≥ 1.3 with `connectInject.enabled=true` |
| Prometheus Operator CRDs | pre-installed, **or** installed by this chart |

> **Note on SCCs** – By default all components run with `runAsNonRoot: true`,
> no fixed `runAsUser`/`fsGroup`, `capabilities: drop: ALL`, and
> `seccompProfile: RuntimeDefault`.  This is compatible with OpenShift's
> **restricted** SCC.  If Promtail cannot read container log files, you may
> need to grant a custom SCC that allows access to `/var/log/pods`; see
> [Tuning Promtail](#tuning-promtail) below.

---

## Installation

### 1. Add Helm repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo update
```

### 2. Resolve umbrella-chart dependencies

```bash
helm dependency update ./consul-observability
```

### 3. Install (or upgrade)

```bash
helm upgrade --install consul-observability ./consul-observability \
  --namespace observability \
  --create-namespace \
  --values ./consul-observability/values.yaml
```

To use a custom values file for secrets/overrides:

```bash
helm upgrade --install consul-observability ./consul-observability \
  --namespace observability \
  --create-namespace \
  -f ./consul-observability/values.yaml \
  -f ./my-overrides.yaml
```

### 4. Verify

```bash
# Prometheus targets
kubectl -n observability port-forward svc/consul-observability-kube-prometheus-stack-prometheus 9090

# Grafana (if no Route)
kubectl -n observability port-forward svc/consul-observability-grafana 3000:80
# Login: admin / changeme  (change via kube-prometheus-stack.grafana.adminPassword)

# OpenShift Route URL
oc -n observability get route consul-observability-grafana -o jsonpath='{.spec.host}'
```

---

## Configuration reference

All values live in `values.yaml`.  The most commonly tuned settings are:

### Consul scraping targets

| Value | Default | Description |
|---|---|---|
| `consul.namespace` | `consul` | Namespace where Consul is installed |
| `consul.agents.enabled` | `true` | Enable PodMonitor for agent metrics |
| `consul.agents.selectorLabels` | `app: consul, component: agent` | Labels to match consul agent/server pods |
| `consul.agents.portName` | `http` | Named port on the Consul pod (maps to 8500) |
| `consul.agents.metricsPath` | `/v1/agent/metrics` | Consul agent metrics path |
| `consul.meshEnvoy.enabled` | `true` | Enable PodMonitor for Envoy sidecar metrics |
| `consul.meshEnvoy.selectorLabels` | `app: consul, consul.hashicorp.com/connect-inject-status: injected` | Labels identifying injected pods |
| `consul.meshEnvoy.portName` | `envoy-admin` | Named port for the Envoy admin interface (19000) |
| `consul.meshEnvoy.metricsPath` | `/stats/prometheus` | Envoy Prometheus stats path |
| `consul.serviceMonitor.enabled` | `false` | Enable optional ServiceMonitor |

### Tuning ports and paths

If your Consul Helm install exposes metrics on a different port name or path,
override via `--set`:

```bash
# Change the agent metrics port name
--set consul.agents.portName=http-metrics

# Change the Envoy admin port name (e.g. if injector uses a different name)
--set consul.meshEnvoy.portName=envoy-metrics

# Move Envoy metrics to merged metrics endpoint (port 20200)
--set consul.meshEnvoy.portName=merged-metrics \
--set consul.meshEnvoy.metricsPath=/metrics
```

To list the actual named ports on your consul pods:

```bash
oc -n consul get pods -l app=consul -o jsonpath=\
  '{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: {range .ports[*]}{.name}={.containerPort} {end}{"\n"}{end}{"\n"}{end}'
```

### Storage

By default Prometheus and Loki use ephemeral/emptyDir storage.  For
production, configure persistent volumes:

```yaml
# values-production.yaml
kube-prometheus-stack:
  prometheus:
    prometheusSpec:
      storageSpec:
        volumeClaimTemplate:
          spec:
            storageClassName: gp3-csi
            resources:
              requests:
                storage: 50Gi

loki:
  singleBinary:
    persistence:
      enabled: true
      storageClass: gp3-csi
      size: 50Gi
```

### OpenShift Route

The Grafana Route is enabled by default.  To disable it or set a custom hostname:

```yaml
openshift:
  grafanaRoute:
    enabled: false          # disable entirely
    host: grafana.apps.example.com   # pin a specific hostname
    tls:
      termination: reencrypt  # edge | passthrough | reencrypt
```

### Grafana admin password

**Do not** commit plain-text passwords.  Override at install time:

```bash
helm upgrade --install consul-observability ./consul-observability \
  --set kube-prometheus-stack.grafana.adminPassword="$(openssl rand -base64 20)"
```

Or reference an existing Kubernetes Secret:

```yaml
kube-prometheus-stack:
  grafana:
    admin:
      existingSecret: grafana-admin-secret
      userKey: admin-user
      passwordKey: admin-password
```

---

## Tuning Promtail

Promtail runs as a DaemonSet and reads log files from `/var/log/pods`.
On OpenShift with the **restricted** SCC the container may not be able to
open host paths.  If promtail pods log `permission denied` errors:

**Option A – Custom SCC (recommended):**

```yaml
# promtail-scc.yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: promtail
allowHostDirVolumePlugin: true
allowPrivilegeEscalation: false
defaultAddCapabilities: []
requiredDropCapabilities: ["ALL"]
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
volumes:
  - configMap
  - emptyDir
  - hostPath
  - projected
  - secret
```

Then bind the promtail ServiceAccount to this SCC:

```bash
oc adm policy add-scc-to-user promtail \
  -z consul-observability-promtail \
  -n observability
```

**Option B – Disable Promtail and use OpenShift Logging instead:**

```yaml
promtail:
  enabled: false
```

---

## Prometheus selector labels

All monitors and rules in this chart carry `release: kps`.  The Prometheus
CR is configured to discover only resources with that label:

```yaml
kube-prometheus-stack:
  prometheus:
    prometheusSpec:
      serviceMonitorSelector:
        matchLabels:
          release: kps
      podMonitorSelector:
        matchLabels:
          release: kps
      ruleSelector:
        matchLabels:
          release: kps
```

If you add your own ServiceMonitors/PrometheusRules outside this chart,
add the `release: kps` label to them or broaden the selector to `{}`.

---

## Uninstall

```bash
helm uninstall consul-observability -n observability
# CRDs installed by kube-prometheus-stack are NOT deleted automatically:
kubectl get crds | grep monitoring.coreos.com | awk '{print $1}' | xargs kubectl delete crd
```

---

## License

See repository root `LICENSE`.
