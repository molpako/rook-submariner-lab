apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: __ROOK_CLUSTER_NAME__
  namespace: __ROOK_NAMESPACE__
spec:
  cephVersion:
    image: __CEPH_IMAGE__
    allowUnsupported: false
  dataDirHostPath: __ROOK_DATA_DIR__
  skipUpgradeChecks: true
  continueUpgradeAfterChecksEvenIfNotHealthy: true
  waitTimeoutForHealthyOSDInMinutes: 10
  mon:
    count: 1
    allowMultiplePerNode: true
  mgr:
    count: 1
    allowMultiplePerNode: true
  dashboard:
    enabled: true
  network:
    multiClusterService:
      enabled: true
      clusterID: __CLUSTER_ID__
  crashCollector:
    disable: true
  monitoring:
    enabled: false
  healthCheck:
    daemonHealth:
      mon:
        disabled: false
        interval: 45s
      osd:
        disabled: false
        interval: 60s
      status:
        disabled: false
        interval: 60s
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
      - name: "__NODE_NAME__"
        deviceFilter: "__ROOK_OSD_DEVICE_FILTER__"
