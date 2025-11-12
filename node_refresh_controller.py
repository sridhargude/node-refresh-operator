#!/usr/bin/env python3
"""
Kubernetes Node Refresh Operator
Zero-downtime node cycling with safe pod eviction
"""

import os
import time
import logging
from datetime import datetime, timedelta
from typing import Dict, List, Optional
from croniter import croniter

from kubernetes import client, config, watch
from kubernetes.client.rest import ApiException

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class NodeRefreshOperator:
    """Kubernetes Operator for zero-downtime node cycling"""
    
    def __init__(self):
        """Initialize the operator with Kubernetes clients"""
        try:
            config.load_incluster_config()
            logger.info("Loaded in-cluster configuration")
        except config.ConfigException:
            config.load_kube_config()
            logger.info("Loaded kubeconfig configuration")
        
        self.core_v1 = client.CoreV1Api()
        self.apps_v1 = client.AppsV1Api()
        self.policy_v1 = client.PolicyV1Api()
        self.custom_api = client.CustomObjectsApi()
        
        self.group = "noderefresh.io"
        self.version = "v1"
        self.plural = "noderefreshes"
        
        self.retry_delays = [30, 60, 120, 300]  # Retry delays in seconds
    
    def run(self):
        """Main operator loop - watch for NodeRefresh resources"""
        logger.info("Starting Node Refresh Operator...")
        
        w = watch.Watch()
        
        while True:
            try:
                for event in w.stream(
                    self.custom_api.list_cluster_custom_object,
                    group=self.group,
                    version=self.version,
                    plural=self.plural,
                    timeout_seconds=300
                ):
                    event_type = event['type']
                    obj = event['object']
                    
                    logger.info(f"Event: {event_type} for {obj['metadata']['name']}")
                    
                    if event_type in ['ADDED', 'MODIFIED']:
                        self.reconcile(obj)
                    
            except ApiException as e:
                logger.error(f"API Exception: {e}")
                time.sleep(10)
            except Exception as e:
                logger.error(f"Unexpected error in watch loop: {e}")
                time.sleep(10)
    
    def reconcile(self, obj: Dict):
        """Main reconciliation loop for NodeRefresh resource"""
        name = obj['metadata']['name']
        spec = obj['spec']
        status = obj.get('status', {})
        
        logger.info(f"Reconciling NodeRefresh: {name}")
        
        try:
            # Check if scheduled refresh is due
            if spec.get('refreshSchedule'):
                if not self._is_refresh_due(obj):
                    logger.info(f"Refresh not due for {name}")
                    return
            
            # Get current phase
            current_phase = status.get('phase', 'Idle')
            
            if current_phase == 'Idle':
                self._start_refresh(obj)
            elif current_phase == 'Provisioning':
                self._handle_provisioning(obj)
            elif current_phase == 'Draining':
                self._handle_draining(obj)
            elif current_phase == 'Validating':
                self._handle_validation(obj)
            elif current_phase == 'Completed':
                self._handle_completion(obj)
            elif current_phase == 'Failed':
                self._handle_failure(obj)
                
        except Exception as e:
            logger.error(f"Error reconciling {name}: {e}")
            self._update_status(obj, {
                'phase': 'Failed',
                'message': f"Reconciliation error: {str(e)}"
            })
    
    def _is_refresh_due(self, obj: Dict) -> bool:
        """Check if scheduled refresh is due"""
        spec = obj['spec']
        status = obj.get('status', {})
        
        schedule = spec.get('refreshSchedule')
        last_refresh = status.get('lastRefreshTime')
        
        if not schedule:
            return True
        
        cron = croniter(schedule, datetime.utcnow())
        next_run = cron.get_next(datetime)
        
        # Update next refresh time
        self._update_status(obj, {
            'nextRefreshTime': next_run.isoformat() + 'Z'
        })
        
        if not last_refresh:
            return True
        
        last_refresh_dt = datetime.fromisoformat(last_refresh.replace('Z', '+00:00'))
        return datetime.utcnow() >= next_run
    
    def _start_refresh(self, obj: Dict):
        """Start the node refresh process"""
        name = obj['metadata']['name']
        spec = obj['spec']
        
        logger.info(f"Starting node refresh for {name}")
        
        # Get target nodes
        target_nodes = self._get_target_nodes(spec['targetNodeLabels'])
        
        if not target_nodes:
            logger.warning(f"No nodes found matching labels for {name}")
            self._update_status(obj, {
                'phase': 'Completed',
                'message': 'No target nodes found',
                'totalNodes': 0
            })
            return
        
        logger.info(f"Found {len(target_nodes)} nodes to refresh")
        
        # Start with first node
        self._update_status(obj, {
            'phase': 'Provisioning',
            'currentNode': target_nodes[0].metadata.name,
            'totalNodes': len(target_nodes),
            'nodesRefreshed': [],
            'podsMovedSuccessfully': 0,
            'podsMovesFailed': 0,
            'message': f'Provisioning new node for {target_nodes[0].metadata.name}'
        })
    
    def _get_target_nodes(self, label_selector: Dict[str, str]) -> List:
        """Get nodes matching the label selector"""
        selector = ','.join([f"{k}={v}" for k, v in label_selector.items()])
        
        try:
            nodes = self.core_v1.list_node(label_selector=selector)
            return nodes.items
        except ApiException as e:
            logger.error(f"Error listing nodes: {e}")
            return []
    
    def _handle_provisioning(self, obj: Dict):
        """Handle node provisioning phase"""
        name = obj['metadata']['name']
        spec = obj['spec']
        status = obj.get('status', {})
        
        current_node = status.get('currentNode')
        logger.info(f"Provisioning new node to replace {current_node}")
        
        # In a real implementation, this would trigger node provisioning
        # via cloud provider API or node autoscaler
        # For this example, we'll simulate checking for available nodes
        
        # Get all ready nodes
        all_nodes = self.core_v1.list_node()
        ready_nodes = [n for n in all_nodes.items if self._is_node_ready(n)]
        
        # Check if we have capacity (at least one extra node)
        target_nodes = self._get_target_nodes(spec['targetNodeLabels'])
        
        if len(ready_nodes) > len(target_nodes):
            logger.info("Sufficient capacity available, proceeding to drain")
            self._update_status(obj, {
                'phase': 'Draining',
                'message': f'Draining node {current_node}'
            })
        else:
            logger.info("Waiting for additional capacity...")
            # In production, would trigger node scale-up here
            time.sleep(30)
    
    def _handle_draining(self, obj: Dict):
        """Handle node draining phase"""
        name = obj['metadata']['name']
        spec = obj['spec']
        status = obj.get('status', {})
        
        current_node = status.get('currentNode')
        logger.info(f"Draining node: {current_node}")
        
        # Check minimum health threshold across cluster
        if not self._check_cluster_health(spec.get('minHealthThreshold', 80)):
            logger.warning("Cluster health below threshold, pausing drain")
            self._update_status(obj, {
                'message': 'Paused: Cluster health below threshold'
            })
            time.sleep(60)
            return
        
        # Get pods on the node
        pods = self._get_pods_on_node(current_node)
        max_concurrent = spec.get('maxPodsToMoveAtOnce', 5)
        
        logger.info(f"Found {len(pods)} pods on node {current_node}")
        
        # Evict pods in batches
        success_count = 0
        failed_count = 0
        
        for i in range(0, len(pods), max_concurrent):
            batch = pods[i:i + max_concurrent]
            
            for pod in batch:
                if self._evict_pod(pod, spec.get('gracePeriodSeconds', 300)):
                    success_count += 1
                else:
                    failed_count += 1
            
            # Wait for pods to be rescheduled
            time.sleep(30)
            
            # Check if pods are healthy on new nodes
            if not self._verify_pods_healthy(batch):
                logger.error("Pods not healthy after eviction")
                failed_count += len(batch)
        
        # Update status
        total_success = status.get('podsMovedSuccessfully', 0) + success_count
        total_failed = status.get('podsMovesFailed', 0) + failed_count
        
        self._update_status(obj, {
            'phase': 'Validating',
            'podsMovedSuccessfully': total_success,
            'podsMovesFailed': total_failed,
            'message': f'Validating pod health after draining {current_node}'
        })
    
    def _handle_validation(self, obj: Dict):
        """Validate that pods are healthy after migration"""
        name = obj['metadata']['name']
        spec = obj['spec']
        status = obj.get('status', {})
        
        current_node = status.get('currentNode')
        logger.info(f"Validating pod health after draining {current_node}")
        
        # Check overall cluster health
        if self._check_cluster_health(spec.get('minHealthThreshold', 80)):
            logger.info(f"Validation successful for {current_node}")
            
            # Mark node as completed
            nodes_refreshed = status.get('nodesRefreshed', [])
            nodes_refreshed.append(current_node)
            
            # Check if there are more nodes to refresh
            total_nodes = status.get('totalNodes', 0)
            
            if len(nodes_refreshed) < total_nodes:
                # Get next node
                target_nodes = self._get_target_nodes(spec['targetNodeLabels'])
                remaining_nodes = [n for n in target_nodes 
                                 if n.metadata.name not in nodes_refreshed]
                
                if remaining_nodes:
                    next_node = remaining_nodes[0].metadata.name
                    logger.info(f"Moving to next node: {next_node}")
                    
                    self._update_status(obj, {
                        'phase': 'Provisioning',
                        'currentNode': next_node,
                        'nodesRefreshed': nodes_refreshed,
                        'message': f'Provisioning for next node: {next_node}'
                    })
                else:
                    self._finalize_refresh(obj, nodes_refreshed)
            else:
                self._finalize_refresh(obj, nodes_refreshed)
        else:
            logger.error("Validation failed - cluster health below threshold")
            self._update_status(obj, {
                'phase': 'Failed',
                'message': 'Validation failed: Cluster health below threshold'
            })
    
    def _finalize_refresh(self, obj: Dict, nodes_refreshed: List[str]):
        """Finalize the refresh process"""
        logger.info("All nodes refreshed successfully")
        
        self._update_status(obj, {
            'phase': 'Completed',
            'nodesRefreshed': nodes_refreshed,
            'lastRefreshTime': datetime.utcnow().isoformat() + 'Z',
            'message': f'Successfully refreshed {len(nodes_refreshed)} nodes'
        })
        
        # Reset to Idle if scheduled
        if obj['spec'].get('refreshSchedule'):
            time.sleep(5)
            self._update_status(obj, {'phase': 'Idle'})
    
    def _handle_completion(self, obj: Dict):
        """Handle completion phase"""
        spec = obj['spec']
        
        # If scheduled, move back to Idle
        if spec.get('refreshSchedule'):
            logger.info("Scheduled refresh completed, returning to Idle")
            self._update_status(obj, {'phase': 'Idle'})
    
    def _handle_failure(self, obj: Dict):
        """Handle failure with retry logic"""
        name = obj['metadata']['name']
        status = obj.get('status', {})
        
        retry_count = status.get('retryCount', 0)
        
        if retry_count < len(self.retry_delays):
            delay = self.retry_delays[retry_count]
            logger.info(f"Retrying after {delay}s (attempt {retry_count + 1})")
            
            time.sleep(delay)
            
            self._update_status(obj, {
                'phase': 'Idle',
                'retryCount': retry_count + 1,
                'message': f'Retrying (attempt {retry_count + 1})'
            })
        else:
            logger.error(f"Max retries exceeded for {name}")
            self._update_status(obj, {
                'message': 'Failed: Max retries exceeded'
            })
    
    def _get_pods_on_node(self, node_name: str) -> List:
        """Get all pods running on a specific node"""
        try:
            pods = self.core_v1.list_pod_for_all_namespaces(
                field_selector=f'spec.nodeName={node_name}'
            )
            
            # Filter out daemonsets and system pods
            filtered_pods = []
            for pod in pods.items:
                # Skip if owned by DaemonSet
                if self._is_daemonset_pod(pod):
                    continue
                # Skip system namespaces (optional)
                if pod.metadata.namespace in ['kube-system', 'kube-public']:
                    continue
                filtered_pods.append(pod)
            
            return filtered_pods
        except ApiException as e:
            logger.error(f"Error listing pods on node {node_name}: {e}")
            return []
    
    def _is_daemonset_pod(self, pod) -> bool:
        """Check if pod is managed by a DaemonSet"""
        if not pod.metadata.owner_references:
            return False
        
        for ref in pod.metadata.owner_references:
            if ref.kind == 'DaemonSet':
                return True
        return False
    
    def _evict_pod(self, pod, grace_period: int) -> bool:
        """Safely evict a pod with PDB respect"""
        namespace = pod.metadata.namespace
        name = pod.metadata.name
        
        logger.info(f"Evicting pod {namespace}/{name}")
        
        try:
            # Check if PDB exists for this pod
            if not self._check_pdb_allows_eviction(pod):
                logger.warning(f"PDB prevents eviction of {namespace}/{name}")
                time.sleep(30)
                # Retry check
                if not self._check_pdb_allows_eviction(pod):
                    return False
            
            # Create eviction
            eviction = client.V1Eviction(
                metadata=client.V1ObjectMeta(
                    name=name,
                    namespace=namespace
                ),
                delete_options=client.V1DeleteOptions(
                    grace_period_seconds=grace_period
                )
            )
            
            self.core_v1.create_namespaced_pod_eviction(
                name=name,
                namespace=namespace,
                body=eviction
            )
            
            logger.info(f"Successfully evicted {namespace}/{name}")
            return True
            
        except ApiException as e:
            if e.status == 429:  # Too Many Requests (PDB violation)
                logger.warning(f"PDB violation when evicting {namespace}/{name}")
                return False
            logger.error(f"Error evicting pod {namespace}/{name}: {e}")
            return False
    
    def _check_pdb_allows_eviction(self, pod) -> bool:
        """Check if Pod Disruption Budget allows eviction"""
        namespace = pod.metadata.namespace
        
        try:
            pdbs = self.policy_v1.list_namespaced_pod_disruption_budget(namespace)
            
            for pdb in pdbs.items:
                # Check if PDB selector matches pod labels
                if self._selector_matches_pod(pdb.spec.selector, pod):
                    # Check if disruptions are allowed
                    if pdb.status.disruptions_allowed > 0:
                        return True
                    else:
                        logger.warning(
                            f"PDB {pdb.metadata.name} prevents disruption"
                        )
                        return False
            
            # No matching PDB, eviction allowed
            return True
            
        except ApiException as e:
            logger.error(f"Error checking PDB: {e}")
            # Default to allow if we can't check
            return True
    
    def _selector_matches_pod(self, selector, pod) -> bool:
        """Check if label selector matches pod"""
        if not selector or not selector.match_labels:
            return False
        
        pod_labels = pod.metadata.labels or {}
        
        for key, value in selector.match_labels.items():
            if pod_labels.get(key) != value:
                return False
        
        return True
    
    def _verify_pods_healthy(self, pods: List) -> bool:
        """Verify that pods are running and healthy on new nodes"""
        for pod in pods:
            namespace = pod.metadata.namespace
            # Get pod owner to find replacement
            owner = self._get_pod_owner(pod)
            
            if not owner:
                continue
            
            # Wait for replacement pod to be ready
            max_wait = 60  # seconds
            waited = 0
            
            while waited < max_wait:
                try:
                    if owner['kind'] == 'ReplicaSet':
                        rs = self.apps_v1.read_namespaced_replica_set(
                            owner['name'], namespace
                        )
                        if rs.status.ready_replicas >= rs.spec.replicas:
                            break
                    elif owner['kind'] == 'StatefulSet':
                        sts = self.apps_v1.read_namespaced_stateful_set(
                            owner['name'], namespace
                        )
                        if sts.status.ready_replicas >= sts.spec.replicas:
                            break
                except ApiException:
                    pass
                
                time.sleep(5)
                waited += 5
            
            if waited >= max_wait:
                logger.error(f"Timeout waiting for pod replacement")
                return False
        
        return True
    
    def _get_pod_owner(self, pod) -> Optional[Dict]:
        """Get the pod's owner reference"""
        if not pod.metadata.owner_references:
            return None
        
        owner_ref = pod.metadata.owner_references[0]
        return {
            'kind': owner_ref.kind,
            'name': owner_ref.name
        }
    
    def _check_cluster_health(self, threshold: int) -> bool:
        """Check overall cluster health percentage"""
        try:
            # Get all pods
            all_pods = self.core_v1.list_pod_for_all_namespaces()
            
            total = len(all_pods.items)
            if total == 0:
                return True
            
            running = sum(1 for p in all_pods.items 
                         if p.status.phase == 'Running')
            
            health_pct = (running / total) * 100
            
            logger.info(f"Cluster health: {health_pct:.1f}% ({running}/{total})")
            
            return health_pct >= threshold
            
        except ApiException as e:
            logger.error(f"Error checking cluster health: {e}")
            return False
    
    def _is_node_ready(self, node) -> bool:
        """Check if node is in Ready state"""
        if not node.status.conditions:
            return False
        
        for condition in node.status.conditions:
            if condition.type == 'Ready':
                return condition.status == 'True'
        
        return False
    
    def _update_status(self, obj: Dict, status_update: Dict):
        """Update the status of NodeRefresh resource"""
        name = obj['metadata']['name']
        
        try:
            # Get current status
            current = self.custom_api.get_cluster_custom_object_status(
                group=self.group,
                version=self.version,
                plural=self.plural,
                name=name
            )
            
            current_status = current.get('status', {})
            current_status.update(status_update)
            
            # Add condition
            if 'phase' in status_update:
                condition = {
                    'type': status_update['phase'],
                    'status': 'True',
                    'lastTransitionTime': datetime.utcnow().isoformat() + 'Z',
                    'reason': status_update.get('message', ''),
                    'message': status_update.get('message', '')
                }
                
                conditions = current_status.get('conditions', [])
                conditions.append(condition)
                current_status['conditions'] = conditions[-10:]  # Keep last 10
            
            # Update status
            body = {'status': current_status}
            
            self.custom_api.patch_cluster_custom_object_status(
                group=self.group,
                version=self.version,
                plural=self.plural,
                name=name,
                body=body
            )
            
            logger.info(f"Updated status for {name}: {status_update}")
            
        except ApiException as e:
            logger.error(f"Error updating status for {name}: {e}")


def main():
    """Main entry point"""
    operator = NodeRefreshOperator()
    operator.run()


if __name__ == '__main__':
    main()
