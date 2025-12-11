---
title: "K8s Homelab: Gaming VMs with KubeVirt and GPU"
date: 2025-11-29T14:00:00+01:00
description: "Deploying gaming VMs on Kubernetes using KubeVirt with NVIDIA RTX 3080 GPU passthrough, dual-mode operation (live/maintenance), and automated lifecycle management"
tags: ["homelab", "kubernetes", "kubevirt", "gpu", "passthrough", "virtualization", "gaming", "windows", "linux", "ansible", "cdi", "longhorn"]
categories: ["homelab", "kubernetes"]
---

*This is the sixth post in our "K8s Homelab" series. Check out the [previous post](/posts/homelab-lgtm-stack/) to see how we deployed the observability stack with Loki, Grafana, Tempo, and Mimir.*

## From Physical Gaming PC to Kubernetes-Native VMs

The original goal of this homelab project was to migrate my gaming setup from a physical PC with QEMU/Libvirt VMs to a Kubernetes-native solution. The gaming PC (Tower) had an NVIDIA RTX 3080 GPU that needed to be passed through to VMs, and I wanted the flexibility to run gaming sessions with full GPU access or maintenance tasks without GPU overhead.

This post documents the journey of deploying KubeVirt on our Kubernetes cluster, configuring GPU passthrough, setting up dual-mode VM operation (live with GPU vs maintenance without), and automating the entire lifecycle with Ansible.

## The Challenge: Gaming VMs in Kubernetes

Running gaming VMs in Kubernetes presents several unique challenges:

1. **GPU Passthrough**: Direct PCI device access for NVIDIA RTX 3080 (VGA + Audio)
2. **Dual-Mode Operation**: VMs must run in two modes:
   - **Live Mode**: With GPU, 80% of node resources, must run on `tower1`
   - **Maintenance Mode**: Without GPU, minimal resources, can run anywhere
3. **Storage Strategy**: Different storage classes for system, cache, and data volumes
4. **Node Affinity**: Live mode VMs must run on `tower1` (where the GPU is)
5. **Resource Management**: Live mode should evict other pods, maintenance mode should not
6. **ISO Management**: Ability to mount installation ISOs for initial setup

## The Architecture: Dual-Mode VM Design

The solution uses four VirtualMachine resources:

### Linux Gaming VM (Bazzite)

- **`gaming-live`**: Live mode with GPU passthrough
  - 13 cores, 26GB RAM (80% of tower1's resources)
  - GPU: NVIDIA RTX 3080 (VGA + Audio)
  - Storage: System (64Gi, 3 replicas), Cache (128Gi, 1 replica), Data (2Ti, 1 replica)
  - Node affinity: Required on `tower1`
  - Priority: `gaming-priority` (can evict other pods)

- **`gaming-maintenance`**: Maintenance mode without GPU
  - 2 cores, 4GB RAM
  - No GPU devices
  - Same storage volumes
  - Node affinity: Preferred on `tower1` (but can run elsewhere)
  - Normal priority (won't evict pods)

### Windows Gaming VM (Windows 11)

- **`gaming-compat-live`**: Live mode with GPU passthrough
  - 13 cores, 26GB RAM
  - GPU: NVIDIA RTX 3080 (VGA + Audio)
  - Hyper-V features enabled for Windows compatibility
  - Storage: System (1Ti, 3 replicas), Data (256Gi, 1 replica)
  - Node affinity: Required on `tower1`
  - Priority: `gaming-priority`

- **`gaming-compat-maintenance`**: Maintenance mode without GPU
  - 2 cores, 4GB RAM
  - No GPU devices
  - Same storage volumes
  - Node affinity: Preferred on `tower1`
  - Normal priority

## Storage Classes: Tailored for Gaming Workloads

Longhorn storage classes were configured with specific requirements:

### Gaming Storage Classes

```yaml
# System storage (3 replicas, immediate binding)
lg-nvme-raw-x3-immediate-on-tower1:
  numberOfReplicas: 3
  diskSelector: "lg-nvme-raw"
  volumeBindingMode: Immediate  # Changed from WaitForFirstConsumer

# Cache storage (1 replica, immediate binding)
lg-nvme-raw-x1-immediate-on-tower1:
  numberOfReplicas: 1
  diskSelector: "lg-nvme-raw"
  volumeBindingMode: Immediate

# Data storage (1 replica, immediate binding)
lg-hdd-raw-x1-immediate-on-tower1:
  numberOfReplicas: 1
  diskSelector: "lg-hdd-raw"
  volumeBindingMode: Immediate

# ISO storage (1 replica, immediate binding for CDI uploads)
lg-nvme-raw-x1-immediate:
  numberOfReplicas: 1
  volumeBindingMode: Immediate
```

**Key Changes**:

- All storage classes now use `Immediate` binding mode instead of `WaitForFirstConsumer`
- This ensures PVCs bind immediately, allowing VMs to schedule without waiting for pod creation
- `diskSelector` is used instead of `nodeSelector` (disks are already tagged and only on `tower1`)
- ISO uploads require `Immediate` binding because CDI's upload process needs the PVC to be bound before the upload pod can start

## Implementation: KubeVirt and CDI Deployment

### Step 1: KubeVirt Operator Installation

KubeVirt is deployed via the operator pattern:

```yaml
# cluster/roles/gaming/tasks/install.yaml
- name: Install KubeVirt operator
  kubernetes.core.k8s:
    state: present
    src: "https://github.com/kubevirt/kubevirt/releases/download/{{ kubevirt_version }}/kubevirt-operator.yaml"
```

### Step 2: KubeVirt Custom Resource with GPU Passthrough and managedTap

The KubeVirt CR enables the `HostDevices` and `VideoConfig` feature gates, registers the GPU, and enables the `managedTap` network binding plugin:

```yaml
# cluster/roles/gaming/templates/kubevirt-cr.yaml.j2
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  configuration:
    developerConfiguration:
      featureGates:
      - HostDevices
      - VideoConfig
    network:
      binding:
        managedtap:
          domainAttachmentType: managedTap
    permittedHostDevices:
      pciHostDevices:
      - pciVendorSelector: "10de:2206"  # NVIDIA RTX 3080 VGA
        resourceName: "nvidia.com/rtx3080"
      - pciVendorSelector: "10de:1aef"  # NVIDIA RTX 3080 Audio
        resourceName: "nvidia.com/rtx3080-audio"
```

**Feature Gates**:

- `HostDevices`: Enables GPU passthrough functionality
- `VideoConfig`: Enables advanced video device configuration (allows VNC to coexist with GPU passthrough)

The `managedTap` binding plugin (available in KubeVirt v1.4.0+) allows VMs to communicate directly with external DHCP servers, enabling them to get IP addresses from the router's DHCP server instead of Kubernetes-managed IPs.

### Step 3: CDI (Containerized Data Importer)

CDI handles VM image management and ISO uploads:

```yaml
- name: Install CDI operator
  kubernetes.core.k8s:
    state: present
    src: "https://github.com/kubevirt/containerized-data-importer/releases/download/{{ cdi_version }}/cdi-operator.yaml"

- name: Create CDI Custom Resource
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: cdi.kubevirt.io/v1beta1
      kind: CDI
      metadata:
        name: cdi
        namespace: cdi
      spec: {}
```

## Challenge 1: GPU Passthrough Configuration

GPU passthrough requires several components working together:

### 1. Host Configuration (tower1)

The host must have IOMMU enabled and the GPU bound to VFIO:

```yaml
# machines/roles/build-pxe-files/templates/butane/tower1.bu.j2
kernel_arguments:
  - intel_iommu=on
  - iommu=pt
  - vfio-pci.ids=10de:2206,10de:1aef
```

### 2. KubeVirt Feature Gate

The `HostDevices` feature gate must be enabled in the KubeVirt CR.

### 3. VM Device Configuration

VMs reference the GPU via the resource name:

```yaml
devices:
  hostDevices:
  - name: gpu-vga
    deviceName: nvidia.com/rtx3080
  - name: gpu-audio
    deviceName: nvidia.com/rtx3080-audio
```

## Challenge 2: Networking Configuration

KubeVirt networking was one of the trickiest parts. The goal was to have VMs get IP addresses directly from the router's DHCP server on the Lab VLAN network, rather than using Kubernetes pod networking.

### The Solution: Bridge Networking with managedTap

The solution uses Multus CNI with a bridge network and KubeVirt's `managedTap` binding plugin:

#### 1. Host Bridge Setup

A systemd service on `tower1` creates and configures a bridge (`local-br0`) connected to the physical network interface (`enp9s0`):

```yaml
# machines/roles/build-pxe-files/templates/configs/local-bridge-setup.service.j2
[Unit]
Description=Setup local bridge (local-br0) for Multus bridge CNI
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '
  # Create bridge if it doesn'\''t exist
  if ! ip link show local-br0 >/dev/null 2>&1; then
    ip link add name local-br0 type bridge
  fi
  # Check if enp9s0 is already connected to local-br0
  if ip link show enp9s0 2>/dev/null | grep -q "master local-br0"; then
    echo "enp9s0 is already connected to local-br0"
  else
    # Connect enp9s0 to the bridge using NetworkManager
    nmcli connection add type bridge ifname local-br0 con-name local-br0
    WIRED_CONN=$(nmcli -t -f NAME connection show | grep -i "wired\|ethernet" | head -1)
    nmcli connection modify "$WIRED_CONN" connection.master local-br0 connection.slave-type bridge
    nmcli connection up local-br0
    nmcli connection up "$WIRED_CONN"
  fi
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

This service:

- Creates the `local-br0` bridge if it doesn't exist
- Connects `enp9s0` to the bridge via NetworkManager
- Checks if already configured to avoid "Device is already in use" errors
- Ensures the bridge is up and connected to the physical network

#### 2. Multus NetworkAttachmentDefinition

A NetworkAttachmentDefinition configures the bridge CNI plugin:

```yaml
# cluster/roles/gaming/templates/gaming-bridge-network.yaml.j2
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: gaming-bridge-network
  namespace: gaming
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "bridge",
      "bridge": "local-br0",
      "isGateway": false,
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.X.0/24",
        "rangeStart": "192.168.X.100",
        "rangeEnd": "192.168.X.110",
        "gateway": "192.168.X.1"
      }
    }
```

The `host-local` IPAM assigns IPs for Kubernetes tracking, but the guest OS gets its IP from the router's DHCP server.

#### 3. KubeVirt managedTap Binding

The `managedTap` binding plugin (enabled in the KubeVirt CR) allows the guest OS to communicate directly with the router's DHCP server:

```yaml
# cluster/roles/gaming/templates/gaming-compat-live-vm.yaml.j2
interfaces:
- name: net0
  macAddress: "8A:D3:14:CA:21:7A"  # Fixed MAC address for consistent DHCP leases
  binding:
    name: managedtap
networks:
- name: net0
  multus:
    networkName: gaming-bridge-network
```

**Key Points**:

- `managedTap` doesn't intercept DHCP requests, allowing the guest OS to get IPs from the router
- The bridge provides L2 connectivity to the physical network
- VMs appear as regular devices on the 192.168.X.0 network
- Fixed MAC addresses ensure consistent IP assignments across VM reboots
- The router's DHCP server assigns IPs to VMs via static leases (e.g., `gaming.vms.lab.x.y.z` → 192.168.26.100)
- Kubernetes also assigns an IP (e.g., 192.168.X.102) for tracking, but the guest OS uses the router-assigned IP
- DNS names follow the pattern `<vm-name>.vms.lab.x.y.z` for easy identification

#### Why managedTap?

Without `managedTap`, KubeVirt's bridge mode intercepts DHCP requests and assigns IPs internally, preventing VMs from getting IPs from external DHCP servers. The `managedTap` binding (introduced in KubeVirt v1.4.0) bypasses this interception, enabling direct communication with the router's DHCP server.

#### 4. Fixed MAC Addresses and Static DHCP Leases

To ensure consistent IP assignments and DNS resolution, VMs are configured with fixed MAC addresses, and the router maintains static DHCP leases:

**VM Configuration** (fixed MAC addresses):

```yaml
# cluster/roles/gaming/templates/gaming-compat-live-vm.yaml.j2
interfaces:
- name: net0
  macAddress: "8A:D3:14:CA:21:7A"  # Fixed MAC for gaming-compat-live
  binding:
    name: managedtap
```

**Router Configuration** (static DHCP leases):

```yaml
# network/roles/router/templates/network/dhcp.conf
# Gaming VMs static leases - from kubernetes_cluster vars
{% for vm in hostvars[groups['kubernetes_cluster'][0]].vms %}
{% if vm.mac is defined and vm.mac | length > 0 and 'XX' not in vm.mac.upper() %}
config host
    option name '{{ vm.name }}.vms.lab.x.y.z'
    option mac '{{ vm.mac }}'
    option ip '{{ vm.ip }}'
    option dns '1'
    option interface 'vlan26'
{% endif %}
{% endfor %}
```

**Benefits**:

- Consistent IP assignments across VM reboots
- Predictable DNS names (`gaming.vms.lab.x.y.z`, `gaming-compat.vms.lab.x.y.z`)
- No need to look up IPs after each reboot
- Router automatically assigns the correct IP based on MAC address

## Challenge 3: Windows VM Configuration

### Hyper-V Features

Windows 11 requires specific Hyper-V features to run properly in a VM:

```yaml
features:
  kvm:
    hidden: true  # Hide KVM from guest
  hyperv:
    relaxed: {}
    vapic: {}
    spinlocks:
      spinlocks: 4096
```

The `vendorId` field was initially used but is not supported in KubeVirt v1.6.3.

### Disk Bus Types: SATA vs VirtIO

Windows doesn't include virtio drivers by default, which creates a challenge:

**Maintenance Mode (Installation)**:

- Uses `bus: sata` for system and data disks
- Windows installer can see disks without additional drivers
- Easier installation process

**Live Mode (Performance)**:

- Uses `bus: virtio` for system and data disks
- Requires virtio drivers to be installed in Windows
- Better performance than SATA

**Boot Order Management**:

- When ISO is attached: ISO gets `bootOrder: 1`, system disk gets `bootOrder: 2`
- When ISO is detached: System disk gets `bootOrder: 1`
- This is handled automatically by the `iso.sh` script

**VirtIO Driver Installation**:

- Download virtio-win ISO from Fedora Project
- Attach as second CD-ROM during Windows installation
- Load drivers when Windows installer can't see disks
- Or install drivers after Windows is installed (then switch to virtio)

## Challenge 4: Storage Binding and VM Scheduling

The original storage classes used `WaitForFirstConsumer`, which delays PVC binding until a pod consumes it. This created two problems:

### Problem 1: CDI Uploads

1. CDI upload pod needs the PVC to be bound
2. PVC won't bind until a pod consumes it
3. Circular dependency!

### Problem 2: VM Scheduling

When VMs use `WaitForFirstConsumer` PVCs:

1. VM pod can't schedule because PVCs aren't bound
2. PVCs won't bind until VM pod schedules
3. Another circular dependency!

**The Solution**: Use `Immediate` binding mode for all gaming storage classes:

```yaml
- name: lg-nvme-raw-x3-immediate-on-tower1
  reclaimPolicy: Retain
  numberOfReplicas: "3"
  diskSelector: "lg-nvme-raw"
  volumeBindingMode: Immediate  # Key difference

- name: lg-hdd-raw-x1-immediate-on-tower1
  reclaimPolicy: Retain
  numberOfReplicas: "1"
  diskSelector: "lg-hdd-raw"
  volumeBindingMode: Immediate
```

This ensures:

- ISO PVCs bind immediately, enabling CDI uploads
- VM PVCs bind immediately, allowing VMs to schedule without waiting
- PVs are provisioned as soon as PVCs are created

**Duplicate PV Prevention**:

- The Ansible playbook includes cleanup tasks to remove Released PVs and orphaned Longhorn volumes before applying new PVCs
- This prevents accumulation of unused volumes when PVCs are recreated
- Ensures idempotency: running `make cluster/install` multiple times won't create duplicate PVs

## Challenge 5: ISO Upload via CDI

Uploading ISOs requires access to the CDI upload proxy. There are two approaches:

### Option 1: Port-Forwarding (Manual)

**Terminal 1** (port-forward):

```bash
export KUBECONFIG=$(pwd)/machines/data/kubeconfig
kubectl port-forward -n cdi service/cdi-uploadproxy 8443:443
```

**Terminal 2** (upload):

```bash
virtctl image-upload dv windows-11-iso \
  --namespace=gaming \
  --size=10Gi \
  --image-path=/path/to/windows.iso \
  --access-mode=ReadWriteOnce \
  --uploadproxy-url=https://localhost:8443 \
  --insecure \
  --storage-class=lg-nvme-raw-x1-immediate
```

### Option 2: NodePort Service (Automated)

We've automated ISO uploads using a NodePort service and a helper script (`cluster/scripts/gaming/iso.sh`):

```bash
# Upload and attach Windows ISO
./cluster/scripts/gaming/iso.sh gaming-compat-maintenance attach --iso-path=/path/to/windows.iso

# Attach existing ISO PVC
./cluster/scripts/gaming/iso.sh gaming-compat-maintenance attach --iso-pvc=windows-iso

# Detach ISO
./cluster/scripts/gaming/iso.sh gaming-compat-maintenance detach
```

The script automatically:

- Creates a NodePort service for the CDI upload proxy (if needed)
- Detects the NodePort and node IP
- Checks if PVC already exists (reuses instead of re-uploading)
- Uploads the ISO using `virtctl` (if needed)
- Attaches ISO to VM with proper boot order (ISO gets `bootOrder: 1`)
- Handles retries and error detection

**Boot Order Management**:

- When ISO is attached: ISO gets `bootOrder: 1`, system disk gets `bootOrder: 2`
- When ISO is detached: System disk gets `bootOrder: 1`, other boot orders are removed
- This ensures VMs boot from ISO during installation, then from system disk after installation

**Key Learnings**:

- Version compatibility matters: `virtctl` version must match KubeVirt version
- Port-forwarding works well for manual uploads
- NodePort enables automation but requires firewall rules
- The upload proxy service maps port 443 to pod port 8443
- Reusing existing PVCs prevents unnecessary re-uploads

## Challenge 6: CDI Block Device Permissions

After setting up ISO uploads, we encountered a critical issue: CDI upload pods were failing with "Permission denied" errors when trying to access `/dev/cdi-block-volume`:

```text
error uploading image: blockdev: cannot open /dev/cdi-block-volume: Permission denied
```

This error occurred because CDI creates block devices for DataVolumes, but the upload pods couldn't access them due to incorrect device ownership.

### Failed Approaches

We initially tried several Kubernetes-native solutions:

1. **Udev Rules**: Created udev rules to set permissions on block devices, but this required host-level access and didn't work reliably
2. **CDI Custom Resource Patches**: Attempted to patch CDI's default pod security context, but CDI's defaults override these patches
3. **MutatingAdmissionWebhook**: Tried to automatically patch upload pods with `supplementalGroups`, but pods are immutable after creation, making this approach unworkable

### The Solution: Containerd Configuration

The correct solution was found in [GitHub issue #2433](https://github.com/kubevirt/containerized-data-importer/issues/2433): configure containerd to automatically set device ownership based on the pod's security context.

**Containerd Configuration** (`/etc/containerd/config.toml`):

```toml
[plugins."io.containerd.grpc.v1.cri"]
  # Enable device ownership from security context
  # This allows containers to access block devices (like CDI block volumes)
  # based on the pod's securityContext (fsGroup, supplementalGroups)
  # This fixes the "Permission denied" error when accessing /dev/cdi-block-volume
  device_ownership_from_security_context = true
```

This setting tells containerd to automatically set device ownership based on the pod's `securityContext.fsGroup` and `supplementalGroups`, allowing CDI upload pods to access block devices without manual intervention.

### Implementation

The containerd configuration is deployed to all nodes via Butane/Ignition during PXE boot:

```yaml
# machines/roles/build-pxe-files/templates/butane/*.bu.j2
files:
  - path: /etc/containerd/config.toml
    mode: 0644
    contents:
      source: http://192.168.X.1/pxe/configs/containerd-config.toml
    overwrite: true
```

The configuration file is generated from a Jinja2 template and deployed to the router's HTTP server, ensuring all nodes (including reinstalled ones) get the correct containerd configuration.

### Key Insight

This issue highlights an important lesson: **not all container runtime problems can be solved at the Kubernetes level**. Sometimes, the solution requires configuring the container runtime (containerd) itself. When troubleshooting permission issues with block devices, consider:

1. **Search for the exact error message** in GitHub issues
2. **Check container runtime configuration** (containerd, CRI-O) before trying Kubernetes workarounds
3. **Understand the layers**: Kubernetes → CRI → Container Runtime → Host

## Priority Classes: Resource Management

To ensure live mode VMs can evict other pods when needed:

```yaml
# cluster/roles/gaming/templates/priority-classes.yaml.j2
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: gaming-priority
value: 1000
preemptionPolicy: PreemptLowerPriority
```

Live mode VMs use `priorityClassName: gaming-priority`, while maintenance mode VMs use the default priority (0).

## VM Lifecycle Management

A bash script (`cluster/scripts/gaming/ctl.sh`) manages VM lifecycle with conflict detection:

```bash
# Start Linux gaming VM in live mode
./cluster/scripts/gaming/ctl.sh start

# Start Windows gaming VM in maintenance mode
./cluster/scripts/gaming/ctl.sh start -c -m

# Stop a VM
./cluster/scripts/gaming/ctl.sh stop -c -m
```

**Options**:

- `-c, --compatibility`: Use Windows VM (gaming-compat-*)
- `-m, --maintenance`: Use maintenance mode

The script detects conflicts (e.g., trying to start live mode when maintenance mode is running) and fails gracefully rather than automatically stopping VMs. All `kubectl` commands include the `-n gaming` namespace flag.

## Storage Volume Layout

### Linux VM (Bazzite)

- **System** (64Gi, 3 replicas): OS and applications
- **Cache** (128Gi, 1 replica on tower1): bcache cache device
- **Data** (2Ti, 1 replica on tower1): Games and user data

### Windows VM

- **System** (1Ti, 3 replicas): Windows OS and applications
- **Data** (256Gi, 1 replica on tower1): Games and user data

All volumes use `Retain` reclaim policy to prevent accidental data loss.

## VNC Access for Installation

VMs have VNC enabled by default in KubeVirt. Access via `virtctl`:

```bash
# Start VM
./cluster/scripts/gaming/ctl.sh start -c -m

# Connect via VNC (port-forwarding, blocking)
virtctl vnc --proxy-only --port 5555 gaming-compat-maintenance -n gaming
```

**VNC Connection**:

- Use `--proxy-only` flag to prevent `virtctl` from trying to open a VNC viewer automatically
- Use `--port` to specify a fixed port (e.g., `5555`) for consistent connections
- Connect your VNC client to `localhost:5555`
- The command blocks, keeping the port-forward active until terminated (Ctrl+C)

**Handling VM Reboots**:

- When VM reboots, VNC connection will disconnect
- Restart the VNC port-forward command to reconnect
- The connection will re-establish once the VM starts booting

This provides graphical access for Windows installation and Linux desktop interaction.

### Graphics Configuration with GPU Passthrough

When using GPU passthrough, there's a challenge: Windows requires a graphics device to boot, but you typically want to disable VNC to use only the GPU output. The `VideoConfig` feature gate (enabled in the KubeVirt CR) allows VNC to coexist with GPU passthrough.

**Current Configuration**:

- VNC is enabled by default (allows Windows to boot)
- GPU passthrough is configured via `hostDevices`
- The `VideoConfig` feature gate enables advanced video device configuration
- For live mode VMs, the GPU becomes the primary display once Windows boots

**Note**: Disabling VNC entirely (e.g., with `autoAttachGraphicsDevice: false`) prevents Windows from booting, as Windows requires a graphics device during initialization. The current approach allows VNC for boot and maintenance, while the GPU handles display output during gaming sessions.

## Version Compatibility

A critical lesson learned: always ensure version compatibility between components:

- **KubeVirt**: v1.6.3
- **CDI**: v1.63.1 (latest stable compatible with KubeVirt 1.6.3)
- **virtctl**: Must match KubeVirt version

Version mismatches cause connection issues and API incompatibilities.

## The Complete Ansible Role

The gaming role (`cluster/roles/gaming/`) follows the same pattern as other roles:

1. **Defaults** (`defaults/main.yaml`): Configuration variables
2. **Tasks** (`tasks/install.yaml`): Deployment logic
3. **Templates** (`templates/`): Jinja2 templates for K8s resources
4. **Documentation** (`docs/`): User guides for ISO setup and VNC access

Key files:

- `kubevirt-cr.yaml.j2`: KubeVirt Custom Resource (with managedTap configuration)
- `gaming-bridge-network.yaml.j2`: Multus NetworkAttachmentDefinition for bridge networking
- `gaming-live-vm.yaml.j2`: Linux live mode VM (uses bridge network with managedTap)
- `gaming-maintenance-vm.yaml.j2`: Linux maintenance mode VM
- `gaming-compat-live-vm.yaml.j2`: Windows live mode VM (uses bridge network with managedTap)
- `gaming-compat-maintenance-vm.yaml.j2`: Windows maintenance mode VM
- `pvcs.yaml.j2`: PersistentVolumeClaims
- `priority-classes.yaml.j2`: PriorityClass for resource management

Host configuration files:

- `machines/roles/build-pxe-files/templates/configs/local-bridge-setup.service.j2`: Systemd service to create and configure the bridge

## What's Next?

With gaming VMs deployed, the next steps are:

1. **VM Installation**: Install Bazzite and Windows 11 using the ISO mounting feature
2. **GPU Driver Setup**: Install NVIDIA drivers in Windows VM
3. **Performance Tuning**: Optimize VM settings for gaming performance
4. **Backup Strategy**: Implement VM snapshot and backup procedures
5. **Monitoring**: Add metrics and alerts for VM health

## Lessons Learned

1. **Storage Binding Modes Matter**: `Immediate` vs `WaitForFirstConsumer` has real implications for both CDI uploads and VM scheduling
2. **Version Compatibility is Critical**: Always match `virtctl` version with KubeVirt version
3. **Networking is Complex**: KubeVirt networking requires careful attention to API structure. Bridge networking with `managedTap` enables VMs to get IPs from router DHCP servers
4. **managedTap Enables Router DHCP**: The `managedTap` binding plugin (KubeVirt v1.4.0+) allows guest OSes to communicate directly with external DHCP servers, bypassing KubeVirt's internal DHCP interception
5. **Bridge Setup Requires Host Configuration**: Creating and configuring the bridge on the host (via systemd service) is essential for bridge CNI to work. NetworkManager integration prevents "Device is already in use" errors
6. **GPU Passthrough Requires Host Config**: IOMMU and VFIO must be configured at the host level
7. **Dual-Mode Design Provides Flexibility**: Separate live/maintenance VMs enable resource-efficient maintenance
8. **Container Runtime Configuration Matters**: Not all container issues can be solved at the Kubernetes level—sometimes you need to configure containerd directly (e.g., `device_ownership_from_security_context`)
9. **Search Strategy is Key**: When troubleshooting, search for exact error messages in GitHub issues before trying complex workarounds
10. **Windows Disk Bus Types**: Use SATA for installation (no drivers needed), virtio for performance (requires drivers)
11. **Boot Order Management**: Automatically managing boot order when attaching/detaching ISOs ensures smooth installation workflows
12. **Namespace Consistency**: Always include namespace flags in `kubectl` commands in scripts to avoid "resource not found" errors
13. **Fixed MAC Addresses**: Configure fixed MAC addresses in VM templates to ensure consistent IP assignments and DNS resolution across reboots
14. **Static DHCP Leases**: Router static DHCP leases with DNS names (`.vms.lab.x.y.z`) provide predictable network access
15. **Graphics Configuration**: Windows requires a graphics device to boot. The `VideoConfig` feature gate allows VNC to coexist with GPU passthrough, enabling boot while using GPU for display output

## Conclusion

Deploying gaming VMs on Kubernetes with KubeVirt and GPU passthrough is complex but achievable. The dual-mode design (live/maintenance) provides the flexibility to run gaming sessions with full GPU access while allowing maintenance tasks without resource contention.

The key to success is understanding:

- Storage binding modes and their implications (`Immediate` for VMs and ISOs)
- KubeVirt networking API structure and bridge networking with Multus
- `managedTap` binding plugin for router DHCP integration
- Host bridge setup and NetworkManager integration
- GPU passthrough requirements (IOMMU, VFIO, feature gates including `VideoConfig`)
- Fixed MAC addresses and static DHCP leases for consistent networking
- DNS naming conventions (`.vms.lab.x.y.z`) for VM identification
- Graphics configuration: VNC for boot, GPU for display output
- Version compatibility between components
- Resource management via PriorityClasses
- Container runtime configuration (containerd device ownership settings)
- Windows disk bus types (SATA for installation, virtio for performance)
- Boot order management for ISO installation workflows

With this setup, gaming VMs are now Kubernetes-native resources that can be managed, monitored, and automated just like any other workload in the cluster.

---

*This is the sixth post in our "K8s Homelab" series. The gaming VMs are now deployed and ready for installation. In future posts, we'll cover VM installation, performance tuning, and backup strategies.*
