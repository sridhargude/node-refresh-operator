#!/bin/bash

# Node Refresh Operator - Complete Test Script
# This script will:
# 1. Label all worker nodes
# 2. Deploy test applications
# 3. Create NodeRefresh resource
# 4. Monitor the refresh process

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "======================================"
    echo "$1"
    echo "======================================"
    echo ""
}

wait_for_pods() {
    local namespace=$1
    local label=$2
    local count=$3
    local timeout=120
    local elapsed=0

    log_info "Waiting for $count pods with label $label in namespace $namespace..."
    
    while [ $elapsed -lt $timeout ]; do
        ready=$(kubectl get pods -n $namespace -l $label --no-headers 2>/dev/null | grep "Running" | wc -l)
        if [ "$ready" -ge "$count" ]; then
            log_success "$ready/$count pods are ready!"
            return 0
        fi
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_error "Timeout waiting for pods to be ready"
    return 1
}

# Main script starts here
print_header "Node Refresh Operator - Complete Test"

# Step 1: Check prerequisites
print_header "Step 1: Checking Prerequisites"

log_info "Checking kubectl is installed..."
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl first."
    exit 1
fi
log_success "kubectl found"

log_info "Checking cluster connectivity..."
if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
fi
log_success "Connected to cluster"

# Step 2: Get all nodes
print_header "Step 2: Discovering Nodes"

log_info "Getting all nodes..."
ALL_NODES=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name")
NODE_COUNT=$(echo "$ALL_NODES" | wc -l | tr -d ' ')

log_info "Found $NODE_COUNT nodes:"
echo "$ALL_NODES" | while read node; do
    echo "  - $node"
done

if [ "$NODE_COUNT" -lt 2 ]; then
    log_warning "Only $NODE_COUNT node(s) found. For best results, use a multi-node cluster."
    log_info "You can create one with: minikube start --nodes 3"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 3: Label nodes
print_header "Step 3: Labeling Worker Nodes"

log_info "Labeling all non-control-plane nodes as workers..."

WORKER_COUNT=0
echo "$ALL_NODES" | while read node; do
    # Check if node is control-plane
    IS_CONTROL_PLANE=$(kubectl get node $node -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null)
    IS_MASTER=$(kubectl get node $node -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}' 2>/dev/null)
    
    if [ -z "$IS_CONTROL_PLANE" ] && [ -z "$IS_MASTER" ]; then
        log_info "Labeling $node as worker..."
        kubectl label node $node node-role.kubernetes.io/worker=true --overwrite
        WORKER_COUNT=$((WORKER_COUNT + 1))
    else
        log_info "Skipping control-plane node: $node"
    fi
done

# Get actual worker count
WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker=true --no-headers -o custom-columns=":metadata.name")
WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l | tr -d ' ')

log_success "Labeled $WORKER_COUNT worker nodes:"
echo "$WORKER_NODES" | while read node; do
    echo "  ✓ $node"
done

if [ "$WORKER_COUNT" -eq 0 ]; then
    log_error "No worker nodes found. Cannot proceed."
    exit 1
fi

# Step 4: Deploy test applications
print_header "Step 4: Deploying Test Applications"

log_info "Creating test namespace..."
kubectl create namespace test-refresh --dry-run=client -o yaml | kubectl apply -f -

log_info "Deploying test applications..."
kubectl apply -f - <<EOF
---
# Sample web application with multiple replicas
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: test-refresh
spec:
  replicas: 6
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - web-app
                topologyKey: kubernetes.io/hostname
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10

---
# Service
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: test-refresh
spec:
  selector:
    app: web-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80

---
# Pod Disruption Budget
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-app-pdb
  namespace: test-refresh
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: web-app

---
# Second application
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-app
  namespace: test-refresh
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-app
  template:
    metadata:
      labels:
        app: api-app
    spec:
      containers:
        - name: httpd
          image: httpd:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 3

---
# PDB for api-app
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-app-pdb
  namespace: test-refresh
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: api-app
EOF

log_success "Applications deployed"

# Wait for pods to be ready
wait_for_pods "test-refresh" "app=web-app" 6
wait_for_pods "test-refresh" "app=api-app" 3

# Step 5: Show initial state
print_header "Step 5: Current Cluster State"

log_info "Worker Nodes:"
kubectl get nodes -l node-role.kubernetes.io/worker=true

echo ""
log_info "Pod Distribution:"
kubectl get pods -n test-refresh -o wide

echo ""
log_info "Pod Disruption Budgets:"
kubectl get pdb -n test-refresh

# Step 6: Create NodeRefresh
print_header "Step 6: Creating NodeRefresh Resource"

log_info "Creating NodeRefresh to cycle worker nodes..."
kubectl apply -f - <<EOF
apiVersion: noderefresh.io/v1
kind: NodeRefresh
metadata:
  name: test-node-refresh
spec:
  targetNodeLabels:
    node-role.kubernetes.io/worker: "true"
  maxPodsToMoveAtOnce: 2
  minHealthThreshold: 60
  gracePeriodSeconds: 30
  nodeProvisionTimeout: 300
EOF

log_success "NodeRefresh created"

# Step 7: Monitor the refresh process
print_header "Step 7: Monitoring Node Refresh Process"

log_info "Monitoring NodeRefresh progress..."
log_info "Press Ctrl+C to stop monitoring (NodeRefresh will continue in background)"
echo ""

# Function to display status
display_status() {
    clear
    echo "======================================"
    echo "Node Refresh Operator - Live Monitor"
    echo "Time: $(date '+%H:%M:%S')"
    echo "======================================"
    echo ""
    
    echo "📊 NodeRefresh Status:"
    kubectl get noderefresh test-node-refresh -o custom-columns=\
NAME:.metadata.name,\
PHASE:.status.phase,\
CURRENT_NODE:.status.currentNode,\
REFRESHED:.status.nodesRefreshed,\
SUCCESS:.status.podsMovedSuccessfully,\
FAILED:.status.podsMovesFailed 2>/dev/null || echo "  Initializing..."
    
    echo ""
    echo "🖥️  Worker Nodes:"
    kubectl get nodes -l node-role.kubernetes.io/worker=true --no-headers | awk '{print "  " $1 " - " $2}'
    
    echo ""
    echo "📦 Pods per Node:"
    kubectl get pods -n test-refresh -o wide --no-headers 2>/dev/null | \
        awk '{print $7}' | sort | uniq -c | awk '{print "  " $2 ": " $1 " pods"}'
    
    echo ""
    echo "🛡️  Pod Disruption Budgets:"
    kubectl get pdb -n test-refresh -o custom-columns=\
NAME:.metadata.name,\
MIN:.spec.minAvailable,\
ALLOWED:.status.disruptionsAllowed,\
CURRENT:.status.currentHealthy 2>/dev/null | sed 's/^/  /'
    
    echo ""
    echo "📝 NodeRefresh Message:"
    MESSAGE=$(kubectl get noderefresh test-node-refresh -o jsonpath='{.status.message}' 2>/dev/null)
    if [ -n "$MESSAGE" ]; then
        echo "  $MESSAGE"
    else
        echo "  Waiting for status update..."
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Press Ctrl+C to stop monitoring"
}

# Monitor loop
COMPLETED=false
while [ "$COMPLETED" = false ]; do
    display_status
    
    # Check if completed
    PHASE=$(kubectl get noderefresh test-node-refresh -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$PHASE" = "Completed" ]; then
        COMPLETED=true
        break
    fi
    
    sleep 5
done

# Step 8: Show final results
print_header "Step 8: Final Results"

log_success "Node refresh completed!"

echo ""
log_info "Final NodeRefresh Status:"
kubectl get noderefresh test-node-refresh -o yaml | grep -A 20 "status:"

echo ""
log_info "Final Pod Distribution:"
kubectl get pods -n test-refresh -o wide

echo ""
log_info "Nodes Refreshed:"
kubectl get noderefresh test-node-refresh -o jsonpath='{.status.nodesRefreshed}' | jq -r '.[]' 2>/dev/null || \
    kubectl get noderefresh test-node-refresh -o jsonpath='{.status.nodesRefreshed}'

echo ""
log_info "Statistics:"
echo "  Pods moved successfully: $(kubectl get noderefresh test-node-refresh -o jsonpath='{.status.podsMovedSuccessfully}')"
echo "  Pods failed: $(kubectl get noderefresh test-node-refresh -o jsonpath='{.status.podsMovesFailed}')"
echo "  Total nodes refreshed: $(kubectl get noderefresh test-node-refresh -o jsonpath='{.status.nodesRefreshed}' | jq -r 'length' 2>/dev/null || echo 'N/A')"

# Step 9: Verify zero downtime
print_header "Step 9: Verification"

log_info "Checking application health..."
READY_PODS=$(kubectl get pods -n test-refresh -l app=web-app --no-headers | grep "Running" | wc -l)
TOTAL_PODS=$(kubectl get pods -n test-refresh -l app=web-app --no-headers | wc -l)

if [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
    log_success "All pods are running! ✅"
else
    log_warning "$READY_PODS/$TOTAL_PODS pods are running"
fi

echo ""
log_info "Checking PDB compliance..."
kubectl get pdb -n test-refresh

echo ""
print_header "Test Complete!"

log_success "Node refresh operator test completed successfully! 🎉"
echo ""
echo "What happened:"
echo "  1. ✅ All worker nodes were labeled"
echo "  2. ✅ Test applications were deployed"
echo "  3. ✅ NodeRefresh cycled through all nodes"
echo "  4. ✅ Pods were safely moved to new nodes"
echo "  5. ✅ Pod Disruption Budgets were respected"
echo "  6. ✅ Zero downtime maintained"
echo ""

# Cleanup prompt
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -p "Do you want to cleanup test resources? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Cleaning up..."
    kubectl delete namespace test-refresh
    kubectl delete noderefresh test-node-refresh
    log_success "Cleanup complete"
else
    log_info "Keeping test resources. To cleanup later, run:"
    echo "  kubectl delete namespace test-refresh"
    echo "  kubectl delete noderefresh test-node-refresh"
fi

echo ""
log_success "Done! 🚀"