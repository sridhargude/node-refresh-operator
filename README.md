# Kubernetes Node Refresh Operator

A production-ready Python-based Kubernetes Operator that performs zero-downtime node cycling by safely migrating workloads to new nodes while respecting Pod Disruption Budgets and maintaining application availability.

## Features

✅ **Zero-Downtime Node Cycling** - Safely refreshes infrastructure nodes every N days  
✅ **Pod Disruption Budget Awareness** - Respects PDBs to maintain application availability  
✅ **Graduated Rollout** - Moves pods in controlled batches with health validation  
✅ **Automatic Retry Logic** - Handles transient failures with exponential backoff  
✅ **Scheduled Refreshes** - Supports cron-based automated node cycling  
✅ **Health Monitoring** - Validates cluster health before proceeding with operations  
✅ **Comprehensive Logging** - Detailed operation logs for debugging and auditing  

## Architecture

The operator watches for `NodeRefresh` custom resources and executes a safe node cycling workflow:

1. **Provisioning**: Ensures additional capacity exists before draining nodes
2. **Draining**: Evicts pods in controlled batches respecting PDBs
3. **Validation**: Verifies pods are healthy on new nodes before proceeding
4. **Iteration**: Repeats for each target node until all are refreshed

## Installation

### 1. Install the CRD

```bash
kubectl apply -f node-refresh-crd.yaml
```

### 2. Build and Push Operator Image

```bash
# Build the operator image
docker build --platform linux/amd64 -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/node-refresh-operator:v1.0.0 .


# Push to your registry
docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/node-refresh-operator:v1.0.0
```

### 3. Deploy the Operator

Update the image in `deployment.yaml`:

```yaml
image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/node-refresh-operator:v1.0.0
```

Deploy all resources:

```bash
kubectl apply -f deployment.yaml
```

Verify the operator is running:

```bash
kubectl get pods -n kube-system -l app=node-refresh-operator
kubectl logs -n kube-system -l app=node-refresh-operator -f 
```

## Usage

### Manual One-Time Refresh

Create a `NodeRefresh` resource for immediate execution:

```yaml
apiVersion: noderefresh.io/v1
kind: NodeRefresh
metadata:
  name: worker-nodes-refresh
spec:
  targetNodeLabels:
    topology.kubernetes.io/region: "us-central1"
  maxPodsToMoveAtOnce: 5
  minHealthThreshold: 80
  gracePeriodSeconds: 300
```

Apply and monitor:

```bash
kubectl apply -f node-refresh.yaml
kubectl get noderefresh worker-nodes-refresh -o yaml
kubectl get noderefresh worker-nodes-refresh -w
```

### Scheduled Automated Refresh

For automatic node cycling every 3 days:

```yaml
apiVersion: noderefresh.io/v1
kind: NodeRefresh
metadata:
  name: scheduled-refresh
spec:
  targetNodeLabels:
    environment: production
  refreshSchedule: "0 2 */3 * *"  # Every 3 days at 2 AM
  maxPodsToMoveAtOnce: 5
  minHealthThreshold: 85
```

### Conservative Database Node Refresh

For stateful workloads requiring extra care:

```yaml
apiVersion: noderefresh.io/v1
kind: NodeRefresh
metadata:
  name: database-refresh
spec:
  targetNodeLabels:
    workload-type: database
  maxPodsToMoveAtOnce: 1
  minHealthThreshold: 95
  gracePeriodSeconds: 600
  refreshSchedule: "0 3 * * 0"  # Weekly on Sundays
```

## Configuration Reference

### Spec Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `targetNodeLabels` | map[string]string | Yes | - | Label selector for nodes to refresh |
| `maxPodsToMoveAtOnce` | integer | No | 5 | Maximum pods to evict concurrently |
| `minHealthThreshold` | integer (0-100) | No | 80 | Minimum cluster health percentage |
| `refreshSchedule` | string | No | - | Cron expression for scheduled refreshes |
| `gracePeriodSeconds` | integer | No | 300 | Pod termination grace period |
| `nodeProvisionTimeout` | integer | No | 600 | Timeout for new node provisioning |

### Status Fields

| Field | Description |
|-------|-------------|
| `phase` | Current phase: Idle, Provisioning, Draining, Validating, Completed, Failed |
| `currentNode` | Node currently being refreshed |
| `nodesRefreshed` | List of successfully refreshed nodes |
| `totalNodes` | Total number of nodes to refresh |
| `podsMovedSuccessfully` | Count of successfully migrated pods |
| `podsMovesFailed` | Count of failed pod migrations |
| `lastRefreshTime` | Timestamp of last completed refresh |
| `nextRefreshTime` | Scheduled time for next refresh |
| `message` | Human-readable status message |

## Monitoring

### Check Operator Health

```bash
# View operator logs
kubectl logs -n kube-system -l app=node-refresh-operator -f

# Check operator pod status
kubectl get pods -n kube-system -l app=node-refresh-operator
```

### Monitor NodeRefresh Resources

```bash
# List all NodeRefresh resources
kubectl get noderefresh

# Watch status changes
kubectl get noderefresh -w

# View detailed status
kubectl describe noderefresh <name>

# Check status in YAML format
kubectl get noderefresh <name> -o yaml
```

### View Status with Custom Columns

```bash
kubectl get noderefresh -o custom-columns=\
NAME:.metadata.name,\
PHASE:.status.phase,\
CURRENT:.status.currentNode,\
REFRESHED:.status.nodesRefreshed,\
TOTAL:.status.totalNodes,\
SUCCESS:.status.podsMovedSuccessfully,\
FAILED:.status.podsMovesFailed
```

## Best Practices

### 1. Always Use Pod Disruption Budgets

Define PDBs for critical applications:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2  # or use maxUnavailable: 1
  selector:
    matchLabels:
      app: my-app
```

### 2. Configure Pod Anti-Affinity

Spread pods across nodes to maintain availability:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: my-app
          topologyKey: kubernetes.io/hostname
```

### 3. Set Appropriate Health Checks

Ensure pods have readiness and liveness probes:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5

livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 20
```

### 4. Start Conservative

Begin with conservative settings:

- Low `maxPodsToMoveAtOnce` (1-3)
- High `minHealthThreshold` (90-95)
- Longer `gracePeriodSeconds` (300-600)

### 5. Test in Non-Production First

Validate the operator behavior in staging before production deployment.

### 6. Monitor Metrics

Track these key metrics:
- Node refresh completion time
- Pod eviction success rate
- Cluster health during refresh
- Application latency/errors during refresh

## Troubleshooting

### Operator Not Starting

```bash
# Check operator logs
kubectl logs -n kube-system -l app=node-refresh-operator

# Verify RBAC permissions
kubectl auth can-i get nodes --as=system:serviceaccount:kube-system:node-refresh-operator
```

### Refresh Stuck in Draining Phase

**Possible causes:**
- Pod Disruption Budget preventing eviction
- Pods without proper owner references
- Insufficient cluster capacity

**Solutions:**
```bash
# Check PDB status
kubectl get pdb --all-namespaces

# Check for pods that can't be evicted
kubectl get pods --all-namespaces --field-selector status.phase=Running

# Manually check node drain
kubectl drain <node-name> --dry-run=server
```

### Health Threshold Not Met

```bash
# Check overall pod health
kubectl get pods --all-namespaces --field-selector status.phase!=Running

# Identify unhealthy pods
kubectl get pods --all-namespaces -o json | \
  jq '.items[] | select(.status.phase != "Running") | .metadata.name'
```

### Eviction Failures

```bash
# Check specific pod eviction error
kubectl get events --all-namespaces | grep -i evict

# Verify PDB allows disruptions
kubectl get pdb -A -o json | \
  jq '.items[] | {name: .metadata.name, allowed: .status.disruptionsAllowed}'
```

## Advanced Configuration

### Custom Retry Logic

Modify `retry_delays` in the operator code:

```python
self.retry_delays = [30, 60, 120, 300, 600]  # 5 retry attempts
```

### Integration with Cloud Providers

The operator includes hooks for cloud provider integration in `_handle_provisioning()`. Implement custom logic for:

- AWS Auto Scaling Groups
- GCP Managed Instance Groups
- Azure Virtual Machine Scale Sets

### Metrics and Alerting

Add Prometheus metrics by integrating the `prometheus_client` library:

```python
from prometheus_client import Counter, Gauge

evictions_total = Counter('node_refresh_evictions_total', 'Total pod evictions')
refresh_duration = Gauge('node_refresh_duration_seconds', 'Time to refresh node')
```


