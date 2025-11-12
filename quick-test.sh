#!/bin/bash
# Quick Node Refresh Operator Test
# Usage: ./quick-test.sh

set -e

echo "🚀 Node Refresh Operator - Quick Test"
echo ""

# 1. Label all worker nodes
echo "📌 Step 1: Labeling worker nodes..."
kubectl get nodes --no-headers -o custom-columns=":metadata.name" | while read node; do
    # Skip control-plane nodes
    if kubectl get node $node -o jsonpath='{.metadata.labels}' | grep -q "control-plane\|master"; then
        echo "  ⏭️  Skipping control-plane: $node"
    else
        echo "  ✓ Labeling: $node"
        kubectl label node $node node-role.kubernetes.io/worker=true --overwrite
    fi
done

WORKER_COUNT=$(kubectl get nodes -l node-role.kubernetes.io/worker=true --no-headers | wc -l)
echo "  ✅ $WORKER_COUNT worker nodes labeled"
echo ""

# 2. Deploy test app
echo "📦 Step 2: Deploying test application..."
kubectl create namespace test-refresh --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

kubectl apply -f - > /dev/null <<EOF
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
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 3
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-app-pdb
  namespace: test-refresh
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: web-app
EOF

echo "  ⏳ Waiting for pods..."
kubectl wait --for=condition=ready pod -l app=web-app -n test-refresh --timeout=120s > /dev/null 2>&1
echo "  ✅ Application ready"
echo ""

# 3. Show initial state
echo "🖥️  Step 3: Initial pod distribution:"
kubectl get pods -n test-refresh -o wide --no-headers | awk '{print "  " $1 " → " $7}'
echo ""

# 4. Create NodeRefresh
echo "🔄 Step 4: Creating NodeRefresh..."
kubectl apply -f - > /dev/null <<EOF
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
EOF

echo "  ✅ NodeRefresh created"
echo ""

# 5. Monitor progress
echo "👀 Step 5: Monitoring (30 seconds)..."
echo ""

for i in {1..6}; do
    PHASE=$(kubectl get noderefresh test-node-refresh -o jsonpath='{.status.phase}' 2>/dev/null || echo "Starting")
    MESSAGE=$(kubectl get noderefresh test-node-refresh -o jsonpath='{.status.message}' 2>/dev/null || echo "Initializing...")
    
    echo "  [$(date +%H:%M:%S)] Phase: $PHASE"
    echo "               Message: $MESSAGE"
    
    if [ "$PHASE" = "Completed" ]; then
        break
    fi
    
    sleep 5
done

echo ""

# 6. Show results
echo "📊 Step 6: Results:"
kubectl get noderefresh test-node-refresh -o custom-columns=\
PHASE:.status.phase,\
NODES_REFRESHED:.status.nodesRefreshed,\
PODS_MOVED:.status.podsMovedSuccessfully,\
PODS_FAILED:.status.podsMovesFailed

echo ""
echo "📦 Final pod distribution:"
kubectl get pods -n test-refresh -o wide --no-headers | awk '{print "  " $1 " → " $7}'

echo ""
echo "✅ Test complete!"
echo ""
echo "To cleanup: kubectl delete namespace test-refresh && kubectl delete noderefresh test-node-refresh"