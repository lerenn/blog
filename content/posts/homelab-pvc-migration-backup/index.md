---
title: "K8s Homelab: PVC Migration Strategies"
date: 2025-11-29T16:00:00+01:00
description: "Migrating PersistentVolumeClaims between storage classes and implementing backup strategies for VM disk images in a Kubernetes homelab"
tags: ["homelab", "kubernetes", "storage", "longhorn", "pvc", "backup", "migration", "kubevirt", "data-protection", "ansible"]
categories: ["homelab", "kubernetes"]
---

*This is the seventh post in our "K8s Homelab" series. Check out the [previous post](/posts/homelab-gaming-kubevirt/) to see how we deployed gaming VMs with KubeVirt and GPU passthrough.*

## The Storage Optimization Challenge

After deploying gaming VMs with KubeVirt, we faced a storage capacity challenge. The Windows system volume was configured with 3 replicas (x3) for high availability, consuming 384Gi of NVME storage (128Gi × 3 replicas) across the cluster. However, with only 256GB NVME drives on the Lenovo nodes and a 1TB drive on Tower, this was consuming too much space.

The challenge: **How do we optimize storage usage while maintaining data integrity and ensuring we can recover from failures?**

This post documents our journey of:
1. Migrating PVCs between storage classes (x3 replicas → x1 replica)
2. Implementing backup strategies for VM disk images
3. Using sparse copy techniques to minimize transfer time and storage

## Understanding Storage Replication Trade-offs

### The Original Configuration

Initially, we configured system volumes with 3 replicas for redundancy:

```yaml
# System storage (3 replicas, immediate binding)
lg-nvme-raw-x3-immediate-on-tower1:
  numberOfReplicas: 3
  diskSelector: "lg-nvme-raw"
  volumeBindingMode: Immediate
```

**Storage Usage**:
- Windows system: 128Gi × 3 replicas = **384Gi total**
- Linux system: 64Gi × 3 replicas = **192Gi total**
- **Total system storage: 576Gi**

### The Problem

With 256GB NVME drives on Lenovos and a 1TB drive on Tower, the 576Gi of system storage was consuming too much space. Additionally, since gaming VMs must run on `tower1` (where the GPU is), having replicas on other nodes didn't provide much benefit—if `tower1` fails, the VMs can't run anyway.

### The Solution: Single Replica with Backup

We decided to:
1. **Migrate to single replica** (x1) storage classes for system volumes
2. **Implement backup strategy** to protect against data loss
3. **Keep data volumes on HDD** (already x1 replica, acceptable performance)

**New Storage Usage**:
- Windows system: 128Gi × 1 replica = **128Gi total** (saves 256Gi!)
- Linux system: 64Gi × 1 replica = **64Gi total** (saves 128Gi!)
- **Total system storage: 192Gi** (saved 384Gi!)

## Challenge 1: PVC Migration Between Storage Classes

Migrating a PVC from one storage class to another requires copying the data, as Kubernetes doesn't support changing the storage class of an existing PVC.

### The Migration Process

The migration involves several steps:

1. **Stop the VMs** using the source PVC
2. **Create a new PVC** with the target storage class
3. **Copy data** from source to destination
4. **Update VM definitions** to use the new PVC
5. **Test the VMs** to ensure they work correctly
6. **Delete the old PVC** (after verification)

### Step 1: Create Migration Pod

We created a privileged pod that mounts both the source and destination PVCs:

```yaml
# cluster/data/migrate-windows-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-migrator
  namespace: gaming
spec:
  containers:
  - name: migrator
    image: quay.io/kubevirt/cdi-importer:latest
    securityContext:
      privileged: true
      runAsUser: 0
      runAsGroup: 0
      capabilities:
        add:
          - SYS_ADMIN
          - SYS_RAWIO
          - MKNOD
    command: ["/bin/bash", "-c"]
    args:
      - |
        echo "Finding source and destination block devices..."
        SOURCE_DEV=$(findmnt -n -o SOURCE /source 2>/dev/null | head -1)
        DEST_DEV=$(findmnt -n -o SOURCE /dest 2>/dev/null | head -1)
        echo "Starting sparse copy with dd (skipping zero blocks)..."
        dd if=$SOURCE_DEV of=$DEST_DEV bs=1M conv=sparse status=progress
        sync
        echo "Migration successful!"
    volumeMounts:
    - name: source
      mountPath: /source
    - name: dest
      mountPath: /dest
  volumes:
  - name: source
    persistentVolumeClaim:
      claimName: gaming-compat-system  # Old PVC
  - name: dest
    persistentVolumeClaim:
      claimName: gaming-compat-system-x1  # New PVC
  restartPolicy: Never
```

**Key Points**:
- **Privileged mode**: Required to access block devices
- **Root user**: Needed for device permissions
- **Sparse copy**: `conv=sparse` skips zero blocks, dramatically reducing copy time

### Step 2: Sparse Copy for Efficiency

The `conv=sparse` option in `dd` is crucial for VM disk images:

```bash
dd if=$SOURCE_DEV of=$DEST_DEV bs=1M conv=sparse status=progress
```

**Benefits**:
- **Faster migration**: Only copies actual data, not empty space
- **Example**: 128Gi disk with 71Gi used → copies only ~71Gi instead of 128Gi
- **Reduced network/storage I/O**: Less data to transfer

**How it works**:
- `dd` detects blocks of zeros in the source
- Skips writing those blocks to the destination
- Creates a sparse file that appears full-size but uses less storage

### Step 3: Update Storage Class Configuration

Before migration, we updated the Ansible configuration:

```yaml
# cluster/roles/gaming/defaults/main.yaml
gaming_compat_storage_class_system: lg-nvme-raw-x1-immediate-on-tower1
```

And created the new storage class:

```yaml
# cluster/data/lg-nvme-raw-x1-immediate-on-tower1-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: lg-nvme-raw-x1-immediate-on-tower1
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  diskSelector: "lg-nvme-raw"
  dataEngine: "v1"
```

### Step 4: Update VM Definitions

After successful migration, update the VM definitions to use the new PVC:

```yaml
# cluster/roles/gaming/templates/gaming-compat-live-vm.yaml.j2
volumes:
- name: system
  persistentVolumeClaim:
    claimName: gaming-compat-system-x1  # Updated to new PVC
```

## Challenge 2: Backing Up PVC Data

Before performing any migration, it's critical to have a backup. **This section documents a manual backup approach** that we implemented as a temporary solution until we can deploy a proper automated backup system (such as Velero or Longhorn snapshots).

**Important Note**: The backup method described here is **manual and requires operator intervention**. It's suitable for one-off backups before migrations or major changes, but **not intended as a long-term backup strategy**. A production-ready solution should include automated, scheduled backups with retention policies.

### Manual Backup Pod Design

**This is a manual backup process**—you must create the pod, wait for completion, and download the backup file. The backup pod mounts the source PVC and creates a sparse disk image:

```yaml
# cluster/data/backup-windows-pvc.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-backup
  namespace: gaming
spec:
  containers:
  - name: backup
    image: alpine:latest
    securityContext:
      privileged: true
      runAsUser: 0
      runAsGroup: 0
    command: ["/bin/sh", "-c"]
    args:
      - |
        apk add --no-cache util-linux coreutils gzip
        SOURCE_DEV=$(findmnt -n -o SOURCE /source 2>/dev/null | head -1)
        echo "Creating sparse backup image..."
        dd if=$SOURCE_DEV of=/backup/windows-system-backup.img bs=1M conv=sparse status=progress
        sync
        echo "Backup completed!"
        ls -lh /backup/windows-system-backup.img
        du -h /backup/windows-system-backup.img
        # Keep pod running for download
        sleep 3600
    volumeMounts:
    - name: source
      mountPath: /source
    - name: backup
      mountPath: /backup
  volumes:
  - name: source
    persistentVolumeClaim:
      claimName: gaming-compat-system
  - name: backup
    emptyDir: {}
  restartPolicy: Never
```

### Downloading the Backup (Manual Process)

**This is a manual step**—the backup pod will keep running for 1 hour to allow time for download. Once the backup is complete, download it to your local machine:

```bash
# Monitor backup progress
kubectl --kubeconfig=machines/data/kubeconfig logs -f pvc-backup -n gaming

# Download the backup file
kubectl --kubeconfig=machines/data/kubeconfig cp \
  gaming/pvc-backup:/backup/windows-system-backup.img \
  ./windows-system-backup.img

# Clean up the backup pod
kubectl --kubeconfig=machines/data/kubeconfig delete pod pvc-backup -n gaming
```

**Backup File Characteristics**:
- **Logical size**: 128Gi (full disk size)
- **Actual size**: ~71Gi (sparse file, only used blocks)
- **Format**: Raw disk image (can be used with `qemu-img` or `dd`)

### Restoring from Backup

To restore a backup, you can use the reverse process:

```bash
# Create restore pod (similar to backup pod, but reverse source/dest)
# Copy backup file to new PVC
dd if=/backup/windows-system-backup.img of=$DEST_DEV bs=1M conv=sparse
```

## Challenge 3: Storage Class Management

When migrating between storage classes, you need to manage the lifecycle of both old and new storage classes.

### Removing Unused Storage Classes

After migration, old storage classes can be removed:

```bash
# Delete storage class from cluster
kubectl delete storageclass lg-nvme-raw-x3-immediate-on-tower1

# Remove from inventory.yaml
# (manually edit the file to remove the storage class definition)
```

**Important**: Deleting a StorageClass does **not** delete existing PVCs that use it. PVCs are independent resources once bound to a PersistentVolume.

### Updating Inventory Configuration

Update the Ansible inventory to reflect the new storage classes:

```yaml
# inventory.yaml
storage_classes:
  - name: lg-nvme-raw-x1-immediate-on-tower1
    reclaimPolicy: Retain
    numberOfReplicas: "1"
    diskSelector: "lg-nvme-raw"
    volumeBindingMode: Immediate
```

## The Complete Migration Workflow

Here's the step-by-step process we followed:

### Phase 1: Preparation

1. **Stop VMs** using the source PVC:
   ```bash
   kubectl patch vm gaming-compat-live -n gaming --type merge -p '{"spec":{"running":false}}'
   kubectl patch vm gaming-compat-maintenance -n gaming --type merge -p '{"spec":{"running":false}}'
   ```

2. **Create backup** (optional but recommended):
   ```bash
   kubectl apply -f cluster/data/backup-windows-pvc.yaml
   # Wait for completion, then download
   ```

3. **Create new PVC** with target storage class:
   ```bash
   kubectl create -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: gaming-compat-system-x1
     namespace: gaming
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: lg-nvme-raw-x1-immediate-on-tower1
     resources:
       requests:
         storage: 128Gi
   EOF
   ```

### Phase 2: Data Migration

4. **Create migration pod**:
   ```bash
   kubectl apply -f cluster/data/migrate-windows-pod.yaml
   ```

5. **Monitor migration progress**:
   ```bash
   kubectl logs -f pvc-migrator -n gaming
   ```

6. **Verify completion**:
   ```bash
   kubectl get pod pvc-migrator -n gaming
   # Should show "Completed" status
   ```

### Phase 3: Switch VMs to New PVC

7. **Update VM definitions** temporarily:
   ```bash
   kubectl patch vm gaming-compat-live -n gaming --type json -p='[
     {"op": "replace", "path": "/spec/template/spec/volumes/0/persistentVolumeClaim/claimName", "value": "gaming-compat-system-x1"}
   ]'
   ```

8. **Test VM**:
   ```bash
   kubectl patch vm gaming-compat-maintenance -n gaming --type merge -p '{"spec":{"running":true}}'
   # Verify it boots correctly
   ```

### Phase 4: Finalize

9. **Update Ansible configuration** permanently:
   ```yaml
   # cluster/roles/gaming/defaults/main.yaml
   gaming_compat_storage_class_system: lg-nvme-raw-x1-immediate-on-tower1
   ```

10. **Re-run playbook** to update VM definitions:
    ```bash
    ansible-playbook -i inventory.yaml cluster/playbooks/configure.yaml --tags gaming
    ```

11. **Delete old PVC** (after verification):
    ```bash
    kubectl delete pvc gaming-compat-system -n gaming
    ```

## Storage Optimization Results

After migration, we achieved significant storage savings:

| Volume | Before (x3) | After (x1) | Savings |
|--------|-------------|------------|---------|
| Windows System | 384Gi | 128Gi | **256Gi** |
| Linux System | 192Gi | 64Gi | **128Gi** |
| **Total** | **576Gi** | **192Gi** | **384Gi** |

This freed up **384Gi of NVME storage**, allowing us to:
- Deploy additional workloads
- Have more headroom for system updates
- Reduce storage pressure on Lenovo nodes

## Backup Strategy Best Practices

**Current State**: We're using **manual backups** as a temporary measure. The process described above works well for one-off backups before migrations, but it requires manual intervention and is not suitable for regular, automated backups.

### Manual Backup Limitations

The current manual approach has several limitations:
- **Requires operator intervention**: Must manually create pods and download files
- **No scheduling**: Backups only happen when you remember to run them
- **No retention policy**: Old backups must be manually managed
- **No automation**: Cannot integrate with disaster recovery procedures
- **Single point of failure**: Backups stored locally on operator's machine

### Recommendations for Future Implementation

When implementing a proper automated backup solution, consider:

#### 1. Automated Backup Tools

- **Velero**: Industry-standard Kubernetes backup tool with scheduling, retention, and cloud storage integration
- **Longhorn Snapshots**: Native Longhorn feature for point-in-time snapshots
- **Custom CronJobs**: Kubernetes-native scheduled backup jobs

#### 2. Backup Frequency

- **System volumes**: Daily backups (or before major changes)
- **Data volumes**: Weekly backups (or based on change frequency)
- **Before migrations**: Always create a backup

#### 3. Retention Policies

- Keep at least one backup per major version
- Implement retention policies (e.g., keep daily for 7 days, weekly for 4 weeks, monthly for 12 months)
- Store backups in multiple locations (local + cloud)

#### 4. Verification and Testing

- Verify backup integrity after creation
- Test restore process periodically (quarterly disaster recovery drills)
- Document restore procedures
- Monitor backup job success/failure

#### 5. Sparse Files (Still Relevant)

- Always use `conv=sparse` when copying disk images
- Reduces backup size and transfer time
- Works well with compression (`gzip`)

**Next Steps**: We plan to implement Velero or Longhorn snapshots for automated, scheduled backups with proper retention policies. The manual backup process will remain available for ad-hoc backups, but automated backups will become the primary strategy.

## Lessons Learned

1. **Sparse Copy is Essential**: Using `conv=sparse` with `dd` dramatically reduces migration time and storage usage for VM disk images
2. **Backup Before Migration**: Always create a backup before migrating critical data—it's your safety net
3. **Storage Class Independence**: Deleting a StorageClass doesn't affect existing PVCs—they're bound to PVs, not storage classes
4. **Privileged Pods Required**: Accessing block devices requires privileged containers with root access
5. **Device Path Discovery**: Use `findmnt` to discover actual block device paths in Longhorn volumes (`/dev/longhorn/pvc-...`)
6. **Replication Trade-offs**: Single replica is acceptable when VMs must run on a specific node anyway
7. **Immediate Binding**: Using `Immediate` binding mode ensures PVCs are ready before VMs try to use them
8. **Test Before Delete**: Always test VMs with new PVCs before deleting old ones
9. **Ansible Idempotency**: Update Ansible configuration to reflect new storage classes for future deployments
10. **Monitor Migration**: Watch migration logs to catch issues early—large disk copies can take time

## What's Next?

With storage optimized and **manual backup procedures** in place, the next critical step is implementing **automated backup solutions**:

1. **Automated Backups**: Deploy Velero or Longhorn snapshots for scheduled, automated backups
2. **Backup Verification**: Add automated integrity checks for backups
3. **Cloud Storage Integration**: Store backups in cloud storage (S3, etc.) for off-site protection
4. **Retention Policies**: Implement automated retention policies (daily/weekly/monthly)
5. **Snapshot Management**: Explore Longhorn snapshot features for point-in-time recovery
6. **Disaster Recovery**: Document and test full cluster recovery procedures using automated backups
7. **Monitoring and Alerting**: Set up alerts for backup job failures

## Conclusion

Migrating PVCs between storage classes and implementing backup strategies are essential skills for managing a Kubernetes homelab. The key takeaways:

- **Sparse copy** (`conv=sparse`) is crucial for efficient VM disk image migration
- **Always backup** before major changes—it's your safety net (even if manual for now)
- **Storage class changes** require data migration—Kubernetes doesn't support in-place changes
- **Single replica** can be acceptable when VMs are node-specific
- **Privileged pods** are necessary for block device access
- **Test thoroughly** before deleting old resources
- **Manual backups are temporary**—automated backup solutions (Velero, Longhorn snapshots) should be implemented for production use

The manual backup process documented here serves as a **temporary solution** until we can implement a proper automated backup system. While it works well for one-off backups before migrations, a production-ready homelab requires automated, scheduled backups with retention policies and off-site storage.

With proper backup and migration procedures in place, you can confidently optimize storage usage while maintaining data protection and recovery capabilities.

---

*This is the seventh post in our "K8s Homelab" series. With storage optimized and backup strategies implemented, we're ready to continue building out the homelab infrastructure. In future posts, we'll cover additional storage optimizations, monitoring, and automation strategies.*

