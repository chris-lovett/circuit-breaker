# circuit-breaker

A Helm chart that deploys an example two-tier application onto an **existing
Consul service mesh** running on **OpenShift**, and implements the
**circuit-breaker resiliency pattern** via Consul's L7 traffic-management
Custom Resource Definitions (CRDs).

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  OpenShift Namespace                                     │
│                                                          │
│  ┌─────────────────────┐       ┌──────────────────────┐  │
│  │  frontend Pod       │ mTLS  │  backend Pod (×2)    │  │
│  │  ┌───────────────┐  │──────▶│  ┌────────────────┐  │  │
│  │  │ fake-service  │  │       │  │  fake-service  │  │  │
│  │  └───────────────┘  │       │  └────────────────┘  │  │
│  │  ┌───────────────┐  │       │  ┌────────────────┐  │  │
│  │  │ envoy sidecar │  │       │  │  envoy sidecar │  │  │
│  │  └───────────────┘  │       │  └────────────────┘  │  │
│  └─────────────────────┘       └──────────────────────┘  │
│           │                                               │
│  ┌────────▼────────┐                                      │
│  │ OpenShift Route │  ──▶  external traffic               │
│  └─────────────────┘                                      │
└──────────────────────────────────────────────────────────┘

Consul CRDs
  • ProxyDefaults  (global)      – set default protocol to http
  • ServiceDefaults (frontend)   – set protocol to http
  • ServiceDefaults (backend)    – circuit-breaker + connection limits
  • ServiceIntentions            – allow frontend → backend
```

The **frontend** service receives incoming HTTP requests and fans them out to
the **backend** via its Envoy sidecar proxy.  The circuit-breaker is
configured on the *backend* `ServiceDefaults` resource and is enforced by
the Envoy proxy running inside each frontend Pod.

---

## Prerequisites

| Requirement | Version |
|---|---|
| OpenShift | 4.10 + |
| Consul on Kubernetes (`consul-k8s`) | 1.0 + |
| Helm | 3.10 + |
| Consul connect-inject enabled | — |
| Consul CRDs installed | `ServiceDefaults`, `ServiceIntentions`, `ProxyDefaults` |

> **Tip:** The [HashiCorp Consul Helm chart](https://github.com/hashicorp/consul-k8s)
> installs all required CRDs.  Follow the
> [OpenShift integration guide](https://developer.hashicorp.com/consul/docs/k8s/openshift)
> to deploy Consul on OpenShift before installing this chart.

---

## Quick Start

```bash
# 1. Create (or switch to) the target OpenShift project
oc new-project consul-demo

# 2. Install the circuit-breaker chart
helm install circuit-breaker ./helm/circuit-breaker \
  --namespace consul-demo \
  --wait

# 3. Get the frontend URL
oc get route circuit-breaker-frontend -n consul-demo \
  -o jsonpath='{.spec.host}{"\n"}'
```

---

## How the Circuit Breaker Works

The circuit-breaker is implemented using two complementary mechanisms provided
by Envoy (via Consul's `ServiceDefaults` CRD on the **backend** service):

### 1. Passive health checking (outlier detection)

Envoy tracks each backend Pod's response codes.  After
`consecutive5xx` (default **5**) consecutive HTTP 5xx responses, the Pod is
*ejected* from the load-balancing pool for `baseEjectionTime` (default **30 s**).
Ejected Pods are periodically retried; if they continue to fail the ejection
time grows.  Up to `maxEjectionPercent` (default **100 %**) of Pods may be
ejected simultaneously.

This is equivalent to a **half-open → open → half-open** state machine:

```
CLOSED ──(5xx threshold exceeded)──▶ OPEN
OPEN   ──(baseEjectionTime elapsed)──▶ HALF-OPEN (one probe request)
HALF-OPEN ──(probe succeeds)──▶ CLOSED
HALF-OPEN ──(probe fails)  ──▶ OPEN  (ejection time doubles)
```

### 2. Active connection-pool limits (fast-fail)

The `limits` block sets hard caps on the number of concurrent connections,
pending requests, and in-flight requests to the backend cluster.  Once a cap
is reached, Envoy returns **503 Service Unavailable** immediately rather than
queueing the request indefinitely.  This prevents cascading failures caused by
slow backends filling up the connection pool of callers.

---

## Configuration

All values are documented in [helm/circuit-breaker/values.yaml](helm/circuit-breaker/values.yaml).
The most important knobs are listed below.

### Consul

| Parameter | Description | Default |
|---|---|---|
| `consul.datacenter` | Consul datacenter name | `dc1` |
| `consul.namespace` | Consul namespace (Enterprise only) | `""` |

### Circuit breaker

| Parameter | Description | Default |
|---|---|---|
| `circuitBreaker.enabled` | Deploy Consul CRDs | `true` |
| `circuitBreaker.passiveHealthCheck.consecutive5xx` | Consecutive 5xx to eject a host | `5` |
| `circuitBreaker.passiveHealthCheck.baseEjectionTime` | Initial ejection duration | `30s` |
| `circuitBreaker.passiveHealthCheck.maxEjectionPercent` | Max % of hosts ejected | `100` |
| `circuitBreaker.passiveHealthCheck.interval` | Outlier-detection analysis interval | `10s` |
| `circuitBreaker.upstreamLimits.maxConnections` | Max concurrent TCP connections | `1024` |
| `circuitBreaker.upstreamLimits.maxPendingRequests` | Max pending requests | `512` |
| `circuitBreaker.upstreamLimits.maxConcurrentRequests` | Max in-flight requests | `1024` |
| `circuitBreaker.createIntentions` | Create ServiceIntentions (ACL deny default) | `true` |

### OpenShift

| Parameter | Description | Default |
|---|---|---|
| `openshift.createSCCRoleBinding` | Bind `anyuid` SCC to the ServiceAccount | `true` |
| `frontend.route.enabled` | Expose frontend via OpenShift Route | `true` |
| `frontend.route.tlsTermination` | TLS termination strategy | `edge` |

### Demo error injection

Set `backend.env[ERROR_RATE]` to a decimal between `0` and `1` to inject HTTP
500 errors into a percentage of backend responses.  This allows you to observe
the circuit breaker in action without modifying application code:

```bash
# Inject 100 % errors – should trip the circuit breaker within a few seconds
helm upgrade circuit-breaker ./helm/circuit-breaker \
  --namespace consul-demo \
  --reuse-values \
  --set 'backend.env[4].name=ERROR_RATE' \
  --set 'backend.env[4].value=1.0'
```

---

## Verifying the Circuit Breaker

```bash
# 1. Confirm Pods are running with Envoy sidecar injected (2 containers each)
oc get pods -n consul-demo

# 2. Check Consul CRD sync status
oc get servicedefaults,serviceintentions,proxydefaults -n consul-demo

# 3. Watch Envoy outlier-detection stats from the frontend sidecar
FRONTEND_POD=$(oc get pod -n consul-demo -l app.kubernetes.io/component=frontend \
  -o jsonpath='{.items[0].metadata.name}')

oc exec "$FRONTEND_POD" -c envoy-sidecar -n consul-demo -- \
  curl -s http://localhost:19000/clusters | grep -E "ejected|outlier"

# 4. Inject errors on the backend to trip the circuit breaker
oc set env deployment/circuit-breaker-backend ERROR_RATE=1.0 -n consul-demo

# 5. Restore normal operation
oc set env deployment/circuit-breaker-backend ERROR_RATE=0 -n consul-demo
```

---

## Chart Structure

```
helm/circuit-breaker/
├── Chart.yaml                         # Chart metadata
├── values.yaml                        # Default values
└── templates/
    ├── _helpers.tpl                   # Template helpers
    ├── NOTES.txt                      # Post-install notes
    ├── serviceaccount.yaml            # ServiceAccount
    ├── rolebinding-scc.yaml           # OpenShift anyuid SCC binding
    ├── deployment-backend.yaml        # Backend Deployment
    ├── service-backend.yaml           # Backend Service
    ├── deployment-frontend.yaml       # Frontend Deployment
    ├── service-frontend.yaml          # Frontend Service
    ├── route-frontend.yaml            # OpenShift Route (frontend)
    ├── proxydefaults.yaml             # Consul ProxyDefaults CRD
    ├── servicedefaults-backend.yaml   # Consul ServiceDefaults (circuit breaker)
    ├── servicedefaults-frontend.yaml  # Consul ServiceDefaults (frontend)
    └── serviceintentions.yaml         # Consul ServiceIntentions
```

---

## References

* [Consul Circuit Breaking (PassiveHealthCheck)](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-defaults#passivehealthcheck)
* [Consul Upstreams Connection Limits](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-defaults#limits)
* [Consul on OpenShift](https://developer.hashicorp.com/consul/docs/k8s/openshift)
* [Envoy Outlier Detection](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier)
* [fake-service](https://github.com/nicholasjackson/fake-service) – demo container used for both services