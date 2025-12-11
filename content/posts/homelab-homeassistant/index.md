---
title: "K8s Homelab: HomeAssistant VM with KubeVirt"
date: 2025-11-29T18:00:00+01:00
description: "Deploying HomeAssistant OS as a KubeVirt VM on Kubernetes, migrating from Raspberry Pi to a container-native solution with automated lifecycle management"
tags: ["homelab", "kubernetes", "kubevirt", "homeassistant", "virtualization", "ansible", "cdi", "longhorn", "iot"]
categories: ["homelab", "kubernetes"]
---

*This is the seventh post in our "K8s Homelab" series. Check out the [previous post](/posts/homelab-gaming-kubevirt/) to see how we deployed gaming VMs with GPU passthrough.*

## From Raspberry Pi to Kubernetes-Native

HomeAssistant has been running on a Raspberry Pi 5 in my homelab, managing smart home devices including Philips Hue lights, electrical sockets, A/C units, and surveillance cameras. While the Pi worked well, I wanted to migrate it to the Kubernetes cluster for better resource management, automated backups, and integration with the rest of the infrastructure.

This post documents the journey of deploying HomeAssistant OS as a KubeVirt VM, using CDI (Containerized Data Importer) to import the QCOW2 disk image, and configuring UEFI boot to ensure proper startup.

## The Challenge: HomeAssistant in Kubernetes

Running HomeAssistant in Kubernetes presents several unique challenges:

1. **OS Image Import**: HomeAssistant OS is distributed as a QCOW2 disk image, not a container image
2. **Boot Configuration**: HomeAssistant OS requires UEFI firmware, not traditional BIOS
3. **Storage Management**: Need persistent storage for HomeAssistant configuration and data
4. **Network Access**: VM must be accessible via Traefik ingress for external access
5. **Lifecycle Management**: Automated startup, shutdown, and restart capabilities
6. **Resource Allocation**: Appropriate CPU and memory allocation for IoT device management

## The Architecture: Simplified VM Design

Unlike the gaming VMs which use dual-mode operation (live/maintenance), HomeAssistant uses a simpler single-VM design:

### HomeAssistant VM

- **VM Name**: `homeassistant`
- **Resources**: 2 cores, 2GB RAM
- **Storage**: System disk (50Gi) using Longhorn with 3 replicas
- **Network**: Pod networking (masquerade interface) for Kubernetes-native connectivity
- **Boot**: UEFI firmware (required for HomeAssistant OS)
- **Run Strategy**: `Always` (automatically starts and restarts if stopped)
- **Node Affinity**: Preferred on a specific node (but can run elsewhere)

### Storage Configuration

```yaml
# Storage class for HomeAssistant system disk
lg-nvme-hdd-x3-immediate:
  numberOfReplicas: 3
  diskSelector: "lg-nvme-hdd"
  volumeBindingMode: Immediate
```

The storage class uses:

- **3 replicas** for high availability
- **Immediate binding** to ensure the PVC is ready before VM creation
- **NVMe/HDD hybrid** storage for cost-effective performance

## Implementation: HomeAssistant Role

The HomeAssistant deployment is managed via an Ansible role that handles the entire lifecycle.

### Step 1: OS Image Import with CDI DataVolume

HomeAssistant OS is distributed as a compressed QCOW2 image (`.qcow2.xz`). We use CDI's DataVolume to automatically download, decompress, and import it:

```yaml
# cluster/roles/homeassistant/templates/homeassistant-os-datavolume.yaml.j2
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: {{ homeassistant_os_dv_name }}
  namespace: {{ homeassistant_namespace }}
spec:
  source:
    http:
      url: "https://github.com/home-assistant/operating-system/releases/download/{{ homeassistant_os_version }}/haos_ova-{{ homeassistant_os_version }}.qcow2.xz"
  contentType: kubevirt
  pvc:
    accessModes:
      - ReadWriteOnce
    storageClassName: {{ homeassistant_storage_class_system }}
    resources:
      requests:
        storage: {{ homeassistant_system_size }}
```

**Key Features**:

- **Automatic Download**: CDI downloads the image from GitHub releases
- **Decompression**: Handles `.xz` compression automatically
- **QCOW2 Conversion**: Converts to a format suitable for KubeVirt
- **PVC Creation**: Creates the PVC automatically when import completes

The DataVolume import process:

1. Creates a temporary pod to download the image
2. Decompresses the `.xz` file
3. Imports the QCOW2 image into the PVC
4. Cleans up temporary resources

### Step 2: VM Configuration with UEFI Boot

HomeAssistant OS requires UEFI firmware, not traditional BIOS. The VM configuration includes:

```yaml
# cluster/roles/homeassistant/templates/homeassistant-vm.yaml.j2
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: homeassistant
  namespace: {{ homeassistant_namespace }}
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        firmware:
          bootloader:
            efi:
              secureBoot: false
        cpu:
          cores: {{ homeassistant_cpu }}
        resources:
          requests:
            memory: {{ homeassistant_memory }}
            cpu: {{ homeassistant_cpu }}
          limits:
            memory: {{ homeassistant_memory }}
            cpu: {{ homeassistant_cpu }}
        devices:
          disks:
          - name: system
            disk:
              bus: virtio
            bootOrder: 1
          interfaces:
          - name: default
            masquerade: {}
      networks:
      - name: default
        pod: {}
      volumes:
      - name: system
        persistentVolumeClaim:
          claimName: "{{ homeassistant_os_dv_name }}"
```

**Key Configuration**:

- **UEFI Firmware**: `bootloader.efi.secureBoot: false` enables UEFI without secure boot
- **Run Strategy**: `Always` ensures the VM automatically starts and restarts
- **Pod Networking**: Uses masquerade interface for Kubernetes-native networking
- **Boot Order**: System disk is set as boot device #1

### Step 3: Service and Ingress Configuration

To make HomeAssistant accessible externally, we create a Kubernetes Service and Traefik Ingress:

```yaml
# Service
apiVersion: v1
kind: Service
metadata:
  name: homeassistant
  namespace: homeassistant
spec:
  type: ClusterIP
  ports:
  - port: 8123
    targetPort: 8123
    protocol: TCP
  selector:
    kubevirt.io/vm: homeassistant
```

```yaml
# Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homeassistant
  namespace: homeassistant
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - homeassistant.lab.x.y.z
    secretName: homeassistant-tls
  rules:
  - host: homeassistant.lab.x.y.z
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: homeassistant
            port:
              number: 8123
```

**TLS Configuration**: The ingress uses a TLS secret created from the homelab CA certificates, providing HTTPS access with a trusted certificate.

## Challenge 1: QCOW2 Image Import

The initial approach was to use an ISO installation image, but HomeAssistant OS is distributed as a ready-to-use QCOW2 disk image, not an installer ISO.

### Solution: CDI DataVolume with HTTP Source

CDI's DataVolume supports HTTP sources, allowing us to download the image directly from GitHub releases:

```yaml
spec:
  source:
    http:
      url: "https://github.com/home-assistant/operating-system/releases/download/16.3/haos_ova-16.3.qcow2.xz"
  contentType: kubevirt
```

**Benefits**:

- **Automatic Download**: No manual image upload required
- **Version Management**: Easy to update by changing the version variable
- **Idempotent**: CDI checks if the DataVolume already exists and skips re-download

### Storage Size Consideration

The initial PVC size of 32Gi was insufficient for the decompressed QCOW2 image. The image expands to approximately 34Gi after decompression, so we increased the size to 50Gi to provide headroom:

```yaml
homeassistant_system_size: "50Gi"
```

## Challenge 2: UEFI Boot Configuration

Initially, the VM was stuck at "Booting from Hard Disk..." in SeaBIOS. HomeAssistant OS requires UEFI firmware, not traditional BIOS.

### Solution: UEFI Firmware Configuration

Adding UEFI firmware configuration to the VM spec:

```yaml
domain:
  firmware:
    bootloader:
      efi:
        secureBoot: false
```

This enables UEFI boot without secure boot, which is sufficient for HomeAssistant OS. The VM now boots properly with the UEFI firmware.

## Challenge 3: Run Strategy Selection

The VM needs to automatically start and restart if it stops, ensuring HomeAssistant is always available.

### Solution: Always Run Strategy

```yaml
spec:
  runStrategy: Always
```

**Run Strategy Options**:

- **`Always`**: VM automatically starts and restarts if stopped (equivalent to `spec.running: true`)
- **`Manual`**: VM requires manual start/stop commands
- **`RerunOnFailure`**: Only restarts on infrastructure failures, not graceful shutdowns
- **`Once`**: Runs once and doesn't restart
- **`Halted`**: Ensures VM stays stopped (equivalent to `spec.running: false`)

For HomeAssistant, `Always` ensures the service is always available, automatically recovering from node reboots or infrastructure issues.

## Challenge 4: Reverse Proxy Configuration

After deploying HomeAssistant and configuring the Traefik ingress, accessing the service via the configured domain resulted in HTTP 400 Bad Request errors, even though direct connections to the VM worked correctly.

### Root Cause: Trusted Proxy Configuration

HomeAssistant requires explicit configuration to trust reverse proxies. When accessed through Traefik, HomeAssistant receives requests with `X-Forwarded-*` headers but rejects them as untrusted, resulting in HTTP 400 errors.

### Solution: Configure Trusted Proxies

HomeAssistant must be configured to trust the reverse proxy by adding the `trusted_proxies` configuration to the `http` section in `configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.42.0.0/16      # Kubernetes pod network (where Traefik runs)
    - 192.168.26.0/24  # Lab network (adjust based on your network)
```

**Configuration Methods**:

1. **Via HomeAssistant UI (Recommended)**:
   - Install the "File Editor" add-on from Settings → Add-ons → Add-on Store
   - Open File Editor from the sidebar
   - Navigate to `/config/configuration.yaml`
   - Add or update the `http` section with the trusted proxy configuration
   - Validate: Developer Tools → YAML → Check Configuration
   - Restart HomeAssistant: Settings → System → Restart

2. **Via SSH/Console**:
   - Access the VM console: `virtctl console homeassistant -n homeassistant`
   - Type `login` to access the shell
   - Navigate to the config directory (typically `/config` or `/mnt/data/supervisor/homeassistant`)
   - Edit `configuration.yaml` with `nano` or `vi`
   - Validate: `ha core check`
   - Restart: `ha core restart`

3. **Via Port-Forward (Initial Setup)**:
   - If Traefik access isn't working yet, use port-forward for initial setup:

     ```bash
     kubectl port-forward -n homeassistant svc/homeassistant 8123:8123
     ```

   - Access `http://localhost:8123` to complete setup and configure trusted proxies
   - After configuration, Traefik ingress will work correctly

**Network Ranges to Trust**:

- **Kubernetes Pod Network** (`10.42.0.0/16`): Where Traefik and other cluster services run
- **Lab Network** (`192.168.26.0/24`): Your local network where clients access HomeAssistant
- Adjust these ranges based on your specific network configuration

After configuring trusted proxies and restarting HomeAssistant, the Traefik ingress will work correctly, and you can access HomeAssistant via your configured domain.

## Ansible Role Structure

The HomeAssistant role follows the same pattern as the gaming role:

```text
cluster/roles/homeassistant/
├── defaults/
│   └── main.yaml          # Default variables
├── tasks/
│   ├── install.yaml       # Installation tasks
│   ├── configure.yaml     # Configuration tasks (empty for now)
│   └── uninstall.yaml     # Uninstallation tasks
└── templates/
    ├── homeassistant-vm.yaml.j2
    ├── homeassistant-os-datavolume.yaml.j2
    ├── homeassistant-service.yaml.j2
    ├── homeassistant-ingress.yaml.j2
    ├── pvcs.yaml.j2
    ├── priority-classes.yaml.j2
    └── storage-class.yaml.j2
```

### Installation Process

The install tasks handle:

1. **Namespace Creation**: Creates the `homeassistant` namespace with privileged pod security
2. **Storage Class**: Creates the storage class if it doesn't exist
3. **Priority Class**: Creates a priority class for the VM
4. **DataVolume**: Creates and waits for the OS image import to complete
5. **VM Creation**: Creates the VirtualMachine resource
6. **TLS Secret**: Creates TLS secret from CA certificates
7. **Service & Ingress**: Creates Kubernetes Service and Traefik Ingress

### Idempotency

The role is fully idempotent:

- **DataVolume**: CDI checks if the import already completed and skips re-download
- **VM**: Kubernetes API handles updates gracefully
- **Service/Ingress**: Standard Kubernetes resources are idempotent

## Access and Management

### Web Interface

Once the VM is running and HomeAssistant OS has booted (can take 10-20 minutes on first boot), you can access it via:

```text
https://homeassistant.lab.x.y.z
```

**Note**: If you encounter HTTP 400 errors when accessing via the ingress, you need to configure trusted proxies in HomeAssistant's `configuration.yaml` (see Challenge 4 above). For initial setup, you can use port-forward:

```bash
kubectl port-forward -n homeassistant svc/homeassistant 8123:8123
# Then access http://localhost:8123
```

### VM Management

```bash
# Check VM status
kubectl get vm homeassistant -n homeassistant

# Check VMI (running instance)
kubectl get vmi homeassistant -n homeassistant

# Access console
virtctl console homeassistant -n homeassistant

# VNC access (for boot troubleshooting)
virtctl vnc homeassistant -n homeassistant --proxy-only --port 5555
```

### Service Status

```bash
# Check service endpoints
kubectl get endpoints homeassistant -n homeassistant

# Check ingress
kubectl get ingress homeassistant -n homeassistant
```

## Lessons Learned

### 1. QCOW2 vs ISO

HomeAssistant OS is distributed as a ready-to-use QCOW2 image, not an installer ISO. Using CDI's DataVolume with HTTP source is the correct approach for importing pre-built disk images.

### 2. UEFI Requirement

HomeAssistant OS requires UEFI firmware. Without it, the VM gets stuck at the BIOS boot screen. Always check the OS requirements before configuring the VM.

### 3. Storage Size Planning

QCOW2 images expand after decompression. Always allocate extra storage (20-30% more) to account for image expansion and future growth.

### 4. Run Strategy Selection

For services that should always be available, use `runStrategy: Always`. This ensures automatic startup and recovery from infrastructure issues.

### 5. Pod Networking

Using pod networking (masquerade interface) provides Kubernetes-native networking, allowing the VM to be accessed via standard Kubernetes Services and Ingress resources.

### 6. Reverse Proxy Configuration

When deploying HomeAssistant behind a reverse proxy (Traefik), it's essential to configure `trusted_proxies` in the `http` section of `configuration.yaml`. Without this configuration, HomeAssistant will reject requests from the reverse proxy with HTTP 400 errors, even though direct connections work fine. Always configure trusted proxy IP ranges that include your Kubernetes pod network and client networks.

## Next Steps

With HomeAssistant running in Kubernetes, future enhancements could include:

1. **Backup Automation**: Automated backups of HomeAssistant configuration using Velero or similar tools
2. **Monitoring Integration**: Expose HomeAssistant metrics to Prometheus
3. **Resource Scaling**: Adjust CPU/memory based on device count and automation complexity
4. **High Availability**: Consider multi-replica setup if needed (though HomeAssistant typically runs as a single instance)

## Conclusion

Migrating HomeAssistant from a Raspberry Pi to a KubeVirt VM on Kubernetes provides:

- **Better Resource Management**: Shares cluster resources efficiently
- **Automated Lifecycle**: Automatic startup and restart capabilities
- **Integration**: Native Kubernetes networking and service discovery
- **Backup Integration**: Can leverage cluster-wide backup solutions
- **Scalability**: Easy to adjust resources as needed

The deployment is fully automated via Ansible, making it easy to recreate or update. The use of CDI DataVolumes for image import and UEFI firmware configuration ensures HomeAssistant OS boots correctly and runs reliably in the Kubernetes environment.

---

*Next in the series: We'll explore additional homelab services and how they integrate with our Kubernetes infrastructure.*
