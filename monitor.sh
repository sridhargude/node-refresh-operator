#!/bin/bash

echo "=== Node Refresh Monitoring ==="
echo ""

while true; do
    clear
    echo "=== $(date) ==="
    echo ""
    
    echo "📊 NodeRefresh Status:"
    kubectl get noderefresh test-node-refresh -o custom-columns=\
NAME:.metadata.name,\
PHASE:.status.phase,\
CURRENT_NODE:.status.currentNode,\
NODES_REFRESHED:.status.nodesRefreshed,\
PODS_MOVED:.status.podsMovedSuccessfully,\
PODS_FAILED:.status.podsMovesFailed,\
MESSAGE:.status.message 2>/dev/null || echo "Not created yet"
    
    echo ""
    echo "🖥️  Nodes:"
    kubectl get nodes
    
    echo ""
    echo "📦 Pods Distribution:"
    kubectl get pods -n test-refresh -o wide | awk 'NR==1 || NR>1 {print $1, $3, $7}'
    
    echo ""
    echo "🛡️  Pod Disruption Budgets:"
    kubectl get pdb -n test-refresh -o custom-columns=\
NAME:.metadata.name,\
MIN_AVAILABLE:.spec.minAvailable,\
ALLOWED_DISRUPTIONS:.status.disruptionsAllowed,\
CURRENT:.status.currentHealthy,\
DESIRED:.status.desiredHealthy
    
    echo ""
    echo "📝 Recent Events:"
    kubectl get events -n test-refresh --sort-by='.lastTimestamp' | tail -5
    
    sleep 5
done
