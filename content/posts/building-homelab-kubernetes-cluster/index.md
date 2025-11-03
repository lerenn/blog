---
title: "Building a Kubernetes Homelab: From Network Infrastructure to K3s Cluster"
date: 2025-10-12T13:00:00+01:00
description: "Deploying a highly available K3s cluster on Fedora CoreOS with Butane/Ignition, featuring automated provisioning and future PXE-based upgrades"
tags: ["homelab", "kubernetes", "k3s", "fedora-coreos", "butane", "ignition", "infrastructure", "automation"]
categories: ["homelab", "kubernetes"]
---

This is the third post in my "Building a Kubernetes Homelab" series. If you haven't read the [first post](/posts/building-homelab-introduction/) and [second post](/posts/building-homelab-network/), start there — they set the stage for what comes next.

## The Leap: From Clean VLANs to a Real Cluster

The network was finally stable. VLANs behaved, DHCP worked, and devices were segmented the way I had always wanted. After hours of troubleshooting OpenWRT, fighting with proprietary firmware, and wrestling with WiFi configuration, I finally had the foundation I needed.

It was time to build the thing that had motivated all of this: a Kubernetes cluster that I could trust.

I had been dreaming about this moment for months. Three Lenovo mini PCs, each with their own personality and quirks, waiting to be transformed into a resilient cluster. The plan sounded simple enough: Fedora CoreOS, bootstrapped via Ignition with Butane, forming a highly available K3s cluster with embedded etcd. Immutable OS, declarative provisioning, small footprint. Everything I wanted.

What could go wrong?

## Chapter 1: Choosing the Stack (and Owning Its Consequences)

I chose Fedora CoreOS and K3s for clear reasons:

- Immutable OS with atomic upgrades and SELinux (and because I love Fedora)
- First-boot provisioning via Ignition (written with Butane)
- K3s's embedded etcd and small footprint

And then I did what we all do: I customized it. I disabled Traefik, ServiceLB, local storage, metrics-server, and network policy, assuming I would add exactly what I wanted later.

That choice turned out to be the start of the story.

## Chapter 2: The First Boot — Where Good Ideas Meet Reality

After extensive research and careful planning, I wrote four Butane files — one for the first node in bootstrap mode and one for each node in join mode — along with an installation script that would run once via systemd.

I spent hours crafting the perfect Ignition configuration. On paper, the flow was clean: set hostname, configure static IPs, fix SELinux context for the installer script, run a one-shot `k3s-install.service`, and let the K3s installer generate its own service. Idempotency was enforced with a stamp file. All the right ingredients were there.

I carefully transferred the USB drive to the first Lenovo mini PC, watched it boot, and waited with anticipation as the installation process began.

And then the first boot failed.

The system booted, the Ignition configuration applied, but then... nothing. The SSH service didn't start. The K3s installation never completed. Hours of configuration work, and the system refused to come to life. I was frustrated, but this was just the beginning of what would become a multi-day debugging marathon.

## Chapter 3: What Broke (and What That Taught Me)

After spending hours trying to understand why the system refused to boot properly, I finally began connecting to the console and digging through logs. The issues piled up:

- **The hostname check was too strict.** The node was named `lenovo1.lab.internal`, not just `lenovo1`, so it tried to join a cluster that didn't exist. Simple fix, but it took me hours to realize this was the problem.
- **SELinux wasn't amused.** The installer script landed with the wrong context and systemd refused to execute it. I spent an entire afternoon trying different approaches before discovering the context issue.
- **The K3s service never started** because I was waiting for it without starting it. Classic chicken-and-egg problem that I should have seen coming.
- **When I tried to install external CNI plugins**, I hit CoreOS's immutable root: I couldn't place binaries in `/usr/libexec/cni/` even if I wanted to. This was when I realized I was fighting against the fundamental design of the platform.

Each of these issues was reasonable on its own. Together, they were a clear message: keep it simple, lean into the platform, and avoid fighting immutability. Hours of debugging later, I finally understood what this journey would really be about — working with the platform, not against it.

## Chapter 4: The Breakthrough — Stop Forcing It — Let K3s Handle CNI

After days of fighting with external CNI plugins and hitting the immutability wall repeatedly, I had a realization. I was making this way more complicated than it needed to be.

The pivotal change was this: I stopped trying to install or manage CNIs myself. I let K3s handle its own built‑in Flannel CNI layer. No external downloads, no binary placement on a read‑only root, no custom DaemonSets. Just K3s doing K3s things.

The relief when it finally worked was immense. Hours of frustration, days of debugging, all resolved by the simple act of trusting the platform to do what it was designed to do.

From there, the cluster came to life.

## Chapter 5: The Final Shape of the System

- Fedora CoreOS on all nodes
- Ignition via Butane for everything: files, systemd, network
- A single `k3s-install.sh` invoked by a one-shot unit
- SELinux fixed up front by a dedicated service
- K3s installed with disabled defaults, using its built‑in Flannel CNI
- Clean bootstrap-vs-join behavior and multiple API server endpoints for joins

### The Directory Layout I Ended Up With

```text
machines/
├── README.md
├── roles/
│   └── build-pxe-files/     # Ansible role for PXE file generation
│       ├── tasks/main.yaml  # Token fetch, template rendering, butane compilation
│       ├── templates/        # Jinja2 templates with {{ k3s_token }} variable
│       │   ├── k3s-install.sh.j2
│       │   ├── lenovo1-bootstrap.bu.j2
│       │   ├── lenovo1-reinstall.bu.j2
│       │   ├── lenovo2.bu.j2
│       │   └── lenovo3.bu.j2
│       └── defaults/main.yaml
├── playbooks/
│   ├── build-pxe-files.yaml # Calls build-pxe-files role
│   └── get-kubeconfig.yaml
├── scripts/
│   └── trigger-pxe-boot.sh
└── data/
    ├── generated/            # Generated files (gitignored)
    │   ├── scripts/
    │   │   └── k3s-install.sh
    │   ├── butane/
    │   └── ignition/
    └── kubeconfig
```

### The One Decision That Changed Everything

I stopped managing a CNI myself and let K3s use its built-in Flannel CNI. Here's the heart of the installer now:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
    --disable traefik \
    --disable servicelb \
    --disable local-storage \
    --disable metrics-server \
    --token="$K3S_TOKEN" \
    --write-kubeconfig-mode=644 \
    --cluster-cidr="10.42.0.0/16" \
    --service-cidr="10.43.0.0/16" \
    --kubelet-arg="cgroup-driver=systemd" \
    --kubelet-arg="container-runtime-endpoint=unix:///run/containerd/containerd.sock" \
    "$@"
```

And on bootstrap, I just wait for it to come up and be Ready:

```bash
timeout 300 bash -c 'until sudo k3s kubectl get nodes >/dev/null 2>&1; do sleep 5; done'
timeout 300 bash -c 'until sudo k3s kubectl get nodes | grep -q "Ready"; do sleep 5; done' || true
```

### The Complete k3s-install.sh Script

Here's the actual installation script that runs on each node. It's templated with Jinja2 so the K3s token can be automatically injected during the build process:

```bash
#!/bin/bash
set -euo pipefail

K3S_VERSION="v1.28.5+k3s1"
K3S_TOKEN="{{ k3s_token }}"  # Injected by Ansible from bootstrap node
CLUSTER_SERVERS="https://192.168.X.5:6443,https://192.168.X.6:6443,https://192.168.X.7:6443"
HOSTNAME=$(hostname)

# Bootstrap vs Join logic
is_bootstrap_node() {
    [[ "$HOSTNAME" == "lenovo1" ]] || [[ "$HOSTNAME" == "lenovo1.lab.internal" ]]
}

# Bootstrap on first node
if is_bootstrap_node; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
        --cluster-init \
        --disable traefik \
        --disable servicelb \
        --disable local-storage \
        --disable metrics-server \
        --write-kubeconfig-mode=644 \
        --cluster-cidr="10.42.0.0/16" \
        --service-cidr="10.43.0.0/16" \
        --kubelet-arg="cgroup-driver=systemd"
else
    # Join existing cluster with multiple endpoint support
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
        --token="$K3S_TOKEN" \
        --server https://192.168.X.5:6443 \
        --server https://192.168.X.6:6443 \
        --server https://192.168.X.7:6443 \
        --disable traefik \
        --disable servicelb \
        --disable local-storage \
        --disable metrics-server \
        --write-kubeconfig-mode=644 \
        --cluster-cidr="10.42.0.0/16" \
        --service-cidr="10.43.0.0/16" \
        --kubelet-arg="cgroup-driver=systemd"
fi

# Wait for cluster to be ready
timeout 300 bash -c 'until sudo k3s kubectl get nodes >/dev/null 2>&1; do sleep 5; done'
```

## Chapter 6: PXE Boot — From Manual USB to Full Automation

After hours of manual USB installations, I finally had enough. Installing Fedora CoreOS via USB drive on each node was tedious, error-prone, and took forever. I needed automation.

The installation process has evolved from manual USB installation to **complete automation via PXE boot**. The system now provides zero-touch FCOS installation with automatic Ignition application.

### The Challenge: Manual Installation Pain

I started by manually creating USB drives for each node. It worked, but it was slow. I had to:

- Download the FCOS image for each node
- Flash the USB drive
- Boot from USB
- Wait for installation
- Repeat for each node

For three nodes, this wasn't terrible. But I knew I'd be adding more nodes in the future, and I wanted to be able to reinstall nodes easily for testing and upgrades.

I needed PXE boot.

### The Storage Hurdle: Router Limitations

The first major challenge was **storage space**. The OpenWRT router has limited internal storage (typically 128MB), but Fedora CoreOS files are large:

- **Kernel**: ~15MB
- **Initramfs**: ~50MB  
- **Rootfs**: ~200MB
- **Metal Image**: ~1.2GB

The total requirement was over 1.4GB, far exceeding the router's capacity.

### The Breakthrough: USB Storage Solution

I solved the storage problem by using **external USB storage** connected to the router. This was the same approach I had used for network configuration files in my previous post — bind mounts to make USB files accessible via HTTP.

This approach solved the storage problem while keeping the router's internal storage free for system operations.

### The Complete Automated Architecture

I built a hybrid approach combining **PXE boot for automation** with **USB storage for large files**:

- **OpenWRT Router**: Serves as PXE server with DHCP, TFTP, and HTTP
- **USB Storage**: Hosts Fedora CoreOS images (kernel, initramfs, rootfs, metal image)
- **Standard iPXE Bootloader**: Better UEFI compatibility than netboot.xyz
- **Per-Node Configuration**: MAC-based and hostname-based boot scripts with inventory-driven configuration

### The Complete Automated Boot Process

1. **Node powers on** → PXE boot via network
2. **DHCP server** → Provides IP and bootfile (`ipxe.efi`)
3. **TFTP server** → Serves standard iPXE bootloader
4. **iPXE loads** → Chains to custom boot scripts based on MAC/hostname
5. **Per-node script** → Loads FCOS kernel + initramfs with comprehensive installer parameters
6. **FCOS installer** → Automatically downloads metal image and Ignition file
7. **Installation** → Writes FCOS to target device and applies Ignition configuration
8. **Reboot** → System boots into installed FCOS with SSH access configured

### The First Success: Zero-Touch Provisioning

After all the troubleshooting and configuration, the moment of truth arrived. I triggered PXE boot on the first node and watched as it:

1. Booted from the network
2. Downloaded the FCOS images
3. Applied the Ignition configuration
4. Installed to disk
5. Rebooted into a fully configured system

**It worked!** From that moment on, I knew I could provision new nodes in minutes, not hours.

### Installation Commands

The fully automated PXE boot setup requires just a few commands:

```bash
# Configure router with complete PXE boot system
make router/setup

# Build PXE files (templates → generated files with token substitution)
make machines/build

# Deploy generated files to router
make router/deploy
```

The new `machines/build` target:

- Fetches the K3s node token from the bootstrap node (lenovo1)
- Generates `k3s-install.sh` from Jinja2 template with real token
- Generates Butane files from Jinja2 templates with real token
- Compiles Butane files to Ignition JSON using `butane` CLI (requires [Butane installed](https://github.com/coreos/butane/releases))
- Saves all generated files to `machines/data/generated/`

The `router/deploy` target:

- Deploys generated Ignition files to `/www/pxe/ignition/` on the router
- Deploys `k3s-install.sh` to `/www/pxe/scripts/` on the router
- All files already have the real token substituted (no runtime replacement needed)

### Behind the Scenes: Ansible Automation

The `machines/build` target uses an Ansible role (`build-pxe-files`) to automate the entire process:

```yaml
# machines/playbooks/build-pxe-files.yaml
---
- name: Build PXE files from templates
  hosts: localhost
  gather_facts: false
  roles:
    - build-pxe-files
```

The role fetches the K3s token from the bootstrap node, renders Jinja2 templates, and compiles Butane to Ignition:

```yaml
# machines/roles/build-pxe-files/tasks/main.yaml
- name: Fetch K3s node token from lenovo1
  ansible.builtin.raw: "sudo cat /var/lib/rancher/k3s/server/node-token"
  delegate_to: lenovo1
  register: k3s_token_raw

- name: Extract token value
  set_fact:
    k3s_token: "{{ k3s_token_raw.stdout | trim }}"

- name: Generate k3s-install.sh from template
  template:
    src: k3s-install.sh.j2
    dest: "{{ generated_scripts_dir }}/k3s-install.sh"
    mode: '0755'

- name: Generate Butane files from templates
  template:
    src: "{{ item }}.bu.j2"
    dest: "{{ generated_butane_dir }}/{{ item }}.bu"
  loop: "{{ butane_files }}"

- name: Compile Butane files to Ignition
  command: butane --strict "{{ generated_butane_dir }}/{{ item }}.bu"
  register: ignition_results
  loop: "{{ butane_files }}"
```

**The system now provides complete automation:**

- ✅ **Zero manual intervention** required
- ✅ **Per-node configuration** via inventory
- ✅ **Automatic Ignition application**
- ✅ **SSH access** configured on first boot
- ✅ **K3s token automatically fetched and embedded** in all files at build time
- ✅ **Ready for K3s installation** via Ignition
- ✅ **Template-based approach** ensures consistency and maintainability

The PXE system automatically handles node identification via MAC address and serves the appropriate Ignition configuration for each node. The installation is completely hands-off once the system is configured, with automatic token management for cluster joining.

### Re-installing or Upgrading Nodes

**Reinstalling a node with full cluster cleanup:**

```bash
# Reinstall lenovo1 (automatically handles node deletion, draining, and PXE boot)
./machines/scripts/reinstall-node.sh lenovo1
```

The `reinstall-node.sh` script automates the complete reinstallation process:

1. **Deletes the node from the Kubernetes cluster** (if it exists)
   - Safely drains pods first using `kubectl drain`
   - Removes the node from the cluster
   - Warns about potential stale etcd member entries for control plane nodes

2. **Configures PXE boot on the target machine**
   - Detects IPv4 and IBA CL PXE boot entries automatically
   - Sets appropriate boot order (IPv4 first, IBA CL second if available)
   - Configures `BootNext` for immediate PXE boot
   - Reboots the machine

3. **Cleans up SSH host keys**
   - Removes old SSH host keys from `~/.ssh/known_hosts` by hostname
   - Resolves the node's IP using the `host` command
   - Removes SSH host keys by IP to avoid host key verification errors after reinstall

**How the SSH host key cleanup works:**

```bash
# Remove by hostname
ssh-keygen -R "${TARGET}" -f ~/.ssh/known_hosts 2>/dev/null || true

# Resolve IP using host command and remove by IP
NODE_IP=$(host "${TARGET}" 2>/dev/null | grep "has address" | awk '{print $4}' | head -1)
if [ -n "$NODE_IP" ]; then
    ssh-keygen -R "${NODE_IP}" -f ~/.ssh/known_hosts 2>/dev/null || true
    log "Removed SSH keys for ${TARGET} (${NODE_IP})"
fi
```

This ensures that after a reinstall, when the node comes back with a fresh SSH host key, you won't encounter host key verification errors. The script uses the `host` command for IP resolution, which works reliably across different platforms.

**Note for control plane nodes:** If you encounter "duplicate node name" errors when a control plane node tries to rejoin, you may need to manually remove the stale etcd member entry. The script warns you about this possibility.

### Accessing the Cluster

**Fetching kubeconfig for local kubectl access:**

```bash
# Fetch kubeconfig from lenovo1
make machines/kubeconfig

# Use it with kubectl
export KUBECONFIG=$(pwd)/machines/data/kubeconfig
kubectl get nodes
```

The playbook:

- Fetches kubeconfig from the FCOS node
- Automatically replaces server URL from `127.0.0.1` to the node's IP
- Saves to `machines/data/kubeconfig` with proper permissions
- Works with FCOS (no Python required on the target)

**The kubeconfig playbook:**

```yaml
# machines/playbooks/get-kubeconfig.yaml
---
- name: Fetch kubeconfig from lenovo1
  hosts: lenovo1
  gather_facts: false
  vars:
    ansible_user: core
    kubeconfig_local_path: "{{ playbook_dir }}/../data/kubeconfig"
    kubeconfig_remote_path: "/etc/rancher/k3s/k3s.yaml"
    lenovo1_ip: "{{ ansible_host }}"
  
  tasks:
    - name: Fetch kubeconfig content
      ansible.builtin.raw: "sudo cat {{ kubeconfig_remote_path }}"
      register: kubeconfig_content
      
    - name: Save kubeconfig locally with corrected server URL
      ansible.builtin.copy:
        content: "{{ kubeconfig_content.stdout | regex_replace('https://127\\.0\\.0\\.1:6443', 'https://' + lenovo1_ip + ':6443') }}"
        dest: "{{ kubeconfig_local_path }}"
        mode: '0600'
      delegate_to: localhost
      become: false
```

This playbook uses Ansible's `raw` module (which doesn't require Python on the target) and automatically fixes the server URL from the local loopback to the actual node IP.

### Key Butane Configuration Elements

The Butane configuration for each node includes several critical components. Here's an abbreviated version showing the key parts:

```yaml
variant: fcos
version: 1.5.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "ssh-rsa AAAAB3..."

storage:
  # Configure data disk for Longhorn storage
  disks:
    - device: /dev/sda
      wipe_table: true
      partitions:
        - label: longhorn-data
          number: 1
          size_mib: 0

  filesystems:
    - path: /var/lib/longhorn
      device: /dev/disk/by-partlabel/longhorn-data
      format: xfs
      with_mount_unit: true

  files:
    # K3s installation script (served via HTTP in PXE)
    - path: /opt/k3s-install.sh
      mode: 0755
      contents:
        source: http://192.168.X.1/pxe/scripts/k3s-install.sh

    # SELinux context fix (runs before K3s install)
    - path: /etc/systemd/system/selinux-fix.service
      contents:
        inline: |
          [Unit]
          Description=Fix SELinux context
          Before=k3s-install.service
          
          [Service]
          Type=oneshot
          ExecStart=/bin/chcon -t bin_t /opt/k3s-install.sh
          
    # K3s installation service (one-shot with stamp file)
    - path: /etc/systemd/system/k3s-install.service
      contents:
        inline: |
          [Unit]
          ConditionPathExists=!/var/lib/%N.stamp
          
          [Service]
          Type=oneshot
          ExecStart=/opt/k3s-install.sh
          ExecStart=/bin/touch /var/lib/%N.stamp

systemd:
  units:
    - name: selinux-fix.service
      enabled: true
    - name: k3s-install.service
      enabled: true
```

The configuration handles disk partitioning, downloads the installation script via HTTP, fixes SELinux contexts, and uses a stamp file for idempotency. The simplicity of Butane compared to raw Ignition JSON makes it maintainable and readable.

## Lessons I Won't Forget

- Start with the defaults. K3s's built‑in Flannel CNI works and respects CoreOS immutability.
- Don't fight SELinux; prepare for it. Fix contexts explicitly before running installers.
- Let the K3s installer own its systemd unit.
- Idempotency matters. Stamp files beat clever conditionals.
- External registries go down. Fewer external dependencies = fewer surprises.
- **Explicit network configuration matters.** K3s needs `--cluster-cidr` and `--service-cidr` to properly initialize its CNI, even with defaults.
- **Avoid duplicate CIDR parameters.** Don't specify `cluster-cidr` and `service-cidr` in both the install script and config.yaml — it causes "must be of different IP family" errors.
- **CNI binaries location is critical.** FCOS has a read-only `/usr`, so K3s stores CNI binaries in `/var/lib/rancher/k3s/data/<hash>/bin/`. Configure containerd to use writable locations like `/var/lib/cni/bin/`.
- **CNI config timing requires containerd restart.** containerd starts before K3s writes the CNI config, so it caches "no network config found". A systemd service (`cni-config-fix.service`) waits for the CNI config, creates the symlink to `/etc/cni/net.d/`, then restarts containerd to load it. This is the recommended approach for timing issues on immutable systems.
- **PXE boot complexity is real.** iPXE memory limits, TFTP server quirks, and bootloader compatibility all matter.
- **USB storage solves router limitations.** OpenWRT routers have limited internal storage; USB storage for large files is essential.
- **Standard iPXE EFI is more reliable.** Better UEFI compatibility than netboot.xyz for automated installation.
- **FCOS installer needs comprehensive parameters.** `ignition.firstboot`, `ignition.platform.id=metal`, and `coreos.inst.insecure` are all required.
- **Hybrid live + installer mode works.** The installer runs within the live environment with proper rootfs loading.
- **Token management should be automated.** Fetching the K3s node token at build time from the bootstrap node ensures worker nodes can always join with the correct credentials.
- **Template-based generation is better than runtime substitution.** Jinja2 templates with Ansible ensure consistency, version control, and no router-side token replacement complexity.
- **Don't disable CNI.** `--disable-network-policy` only disables the NetworkPolicy API in K3s; it shouldn't be in the `disable:` list or it breaks CNI entirely.

## The Journey Complete — For Now

Looking back on the journey from clean VLANs to a fully automated K3s cluster, I can see how far this project has come. What started as a simple plan to deploy Kubernetes on three machines turned into a comprehensive understanding of immutable operating systems, CNI timing issues, and network boot protocols.

The debugging sessions were frustrating, the late-night troubleshooting exhausting, but the satisfaction of seeing the cluster finally come to life made it all worthwhile. I had built something resilient, something maintainable, something I could trust.

The cluster is up, the foundation is solid, and this time it feels maintainable.

## What's Next

- Add Longhorn using the spare HDDs
- ~~Introduce a proper PXE flow for re‑imaging and upgrades~~ ✅ **Complete! Fully automated PXE boot with installer mode**
- Upgrade from Flannel to Cilium for advanced networking features
- Migrate services (HomeAssistant, monitoring, and more)
- Implement automated cluster scaling and node replacement

## Longhorn Storage: Classes, Placement, and Safety

I added Longhorn for distributed storage and codified how data is placed per logical cluster (foundation, cryptellation, perso).

### Helm values that matter

- Reserve CPU for stability (millicores as strings):
  - `guaranteedEngineManagerCPU: "250"`
  - `guaranteedReplicaManagerCPU: "250"`
- Force explicit StorageClass choice:
  - `persistence.defaultClass: false`

### StorageClasses

All classes set `allowVolumeExpansion: true` and `volumeBindingMode: WaitForFirstConsumer`.

- `longhorn-foundation-delete` (labels: `cluster: foundation`)
  - replicas: "1" (space‑efficient), reclaimPolicy: Delete
- `longhorn-cryptellation-delete` / `longhorn-cryptellation-retain` (labels: `cluster: cryptellation`)
  - replicas: "3", `parameters.nodeSelector: cryptellation`
- `longhorn-perso-delete` / `longhorn-perso-retain` (labels: `cluster: perso`)
  - replicas: "3", `parameters.nodeSelector: perso`

Longhorn node tags (`cryptellation`, `perso`) ensure replicas are placed only on intended nodes.

### Rules of thumb

- Rebuildable/throwaway: Delete + 1 replica
- Should persist while running but OK to clean up on uninstall: Delete + 3 replicas
- Must not be lost: Retain + 3 replicas

Optional per‑class tuning: `staleReplicaTimeout` (default ~30m). Lower for fast failover CI, higher for flaky/edge nodes.

---

If you want the blow‑by‑blow of the CNI detour and how I landed on the built‑in approach, I captured the full troubleshooting path below for future me (and anyone else who needs it).

## Appendix: PXE Boot Implementation — From Manual USB to Fully Automated Network Installation

### The Evolution: Three Phases of PXE Boot

Our PXE boot implementation went through three distinct phases, each solving different challenges:

#### Phase 1: The "Unknown Block Error" Challenge

The initial PXE boot attempts failed with a persistent **"VFS unable to mount root fs on unknown-block(0,0)"** error. This error occurred even though our PXE infrastructure was working perfectly (confirmed by Ubuntu booting successfully). After extensive troubleshooting and research, we discovered the issue was related to UEFI compatibility and kernel parameters.

**The Fix**: Use Standard iPXE EFI Binary + Live Mode with Deferred Rootfs Loading

```ipxe
kernel http://192.168.X.1/pxe/fcos/kernel initrd=initramfs.img coreos.live.rootfs_url=http://192.168.X.1/pxe/fcos/rootfs.img coreos.liveiso=1 rd.neednet=1 ip=dhcp console=tty0 console=ttyS0,115200n8 ipv6.disable=1
initrd http://192.168.X.1/pxe/fcos/initramfs.img
boot
```

#### Phase 2: The Installer Mode Challenge

Once we got the live environment booting, we faced a new challenge: **the automated installer wasn't starting**. The system would boot into the live environment and show "root account locked" but never begin the installation process.

**The Root Cause**: Missing required parameters for automated installation

**The Fix**: Comprehensive installer parameters

```ipxe
kernel http://192.168.X.1/pxe/fcos/kernel initrd=initramfs.img \
    ignition.firstboot \
    ignition.platform.id=metal \
    coreos.inst.install_dev=${dev} \
    coreos.inst.image_url=${image} \
    coreos.inst.ignition_url=${ign} \
    coreos.inst.insecure \
    coreos.live.rootfs_url=http://192.168.X.1/pxe/fcos/rootfs.img \
    rd.neednet=1 ip=dhcp console=tty0 console=ttyS0,115200n8 ipv6.disable=1
```

#### Phase 3: The Complete Automated Solution

The final working solution combines **live environment booting** with **automated installation**:

### Key Parameters That Made It Work

- **`ignition.firstboot`** - Tells FCOS this is a first boot installation
- **`ignition.platform.id=metal`** - Specifies the platform type
- **`coreos.inst.install_dev=${dev}`** - Target installation device
- **`coreos.inst.image_url=${image}`** - Metal image URL (909MB .xz file)
- **`coreos.inst.ignition_url=${ign}`** - Ignition configuration URL
- **`coreos.inst.insecure`** - Skip signature verification (for local HTTP)
- **`coreos.live.rootfs_url=...`** - Required for installer to boot
- **`rd.neednet=1 ip=dhcp`** - Network-first approach
- **`ipv6.disable=1`** - Prevents IPv6 NetworkManager issues
- **Standard iPXE EFI binary** - Better UEFI compatibility

### The PXE Architecture Components

The final architecture provides **fully automated FCOS installation**:

- **TFTP**: Serves small iPXE bootloader (`ipxe.efi` - 1MB)
- **HTTP**: Serves large Fedora CoreOS images from USB storage
- **USB Storage**: Hosts FCOS images (kernel, initramfs, rootfs, metal image)
- **Per-Node Scripts**: MAC-based and hostname-based iPXE scripts with inventory-driven configuration
- **Ansible Automation**: Generates per-node scripts dynamically from inventory

### The Complete Boot Process

1. **Node powers on** → PXE boot via network
2. **DHCP server** → Provides IP and bootfile (`ipxe.efi`)
3. **TFTP server** → Serves standard iPXE bootloader
4. **iPXE loads** → Chains to per-node script based on MAC/hostname
5. **Per-node script** → Loads FCOS kernel + initramfs with comprehensive installer parameters
6. **FCOS installer** → Automatically downloads metal image and Ignition file
7. **Installation** → Writes FCOS to target device and applies Ignition configuration
8. **Reboot** → System boots into installed FCOS with SSH access configured

### Key Technical Breakthroughs

- **Hybrid Live + Installer Mode**: The installer runs within the live environment
- **Comprehensive Parameter Set**: All required parameters for automated installation
- **Inventory-Driven Configuration**: Ansible generates node-specific scripts from inventory
- **USB Storage Integration**: Solves OpenWRT router's limited internal storage
- **Signature Verification Bypass**: `coreos.inst.insecure` for local HTTP serving
- **Network-First Approach**: Ensures network is available before installer starts
- **Template-Based Token Management**: K3s node token automatically fetched from bootstrap node and embedded in all files at build time using Jinja2 templates
- **HTTP-Served Installation Scripts**: Serving `k3s-install.sh` via HTTP avoids base64 encoding complexity in Ignition files and simplifies token substitution
- **Ansible Role for PXE Generation**: Dedicated `build-pxe-files` role handles token fetch, template rendering, and butane compilation

### The Result: Complete Automation

The system now provides **fully automated FCOS installation** via PXE boot:

- ✅ **Zero manual intervention** required
- ✅ **Per-node configuration** via inventory
- ✅ **Automatic Ignition application**
- ✅ **SSH access** configured on first boot
- ✅ **Ready for K3s installation** via Ignition

## Appendix: CNI Troubleshooting — The Long Way Around

This appendix documents the full journey of CNI troubleshooting — from external plugins to built-in solutions. If you're following along and want to understand why I ended up using K3s's built-in CNI instead of Namble or Cilium, this is the detailed story.

### The Journey: From External CNI to Built-In

I started with what seemed like a smart approach: use an external CNI plugin (Namble) that was more powerful than Flannel. This would give me better control and more features. It seemed like the right choice for a production-like homelab setup.

### The Read-Only Filesystem Challenge

I tried installing external CNI plugins and immediately hit the read‑only root of Fedora CoreOS. Even after fixing PodCIDR mismatches, kubelets were still looking in `/usr/libexec/cni/` for plugins I couldn't place there. I spent hours trying to work around this limitation before finally accepting the truth: it all disappeared the moment I stopped overriding K3s and let it manage its own built-in Flannel CNI.

### The Timing Issue

After switching to K3s's built-in Flannel CNI, I thought I was in the clear. The read-only filesystem problem was solved. But then a new issue emerged: nodes would stay in `NotReady` state with "cni plugin not initialized" errors.

I spent days investigating this. The pods wouldn't start. The nodes refused to become Ready. After extensive research and multiple failed attempts, I finally discovered the root cause: **a timing issue.** `containerd` starts before K3s creates the CNI configuration file, so containerd caches "no network config found" and never reloads.

**The Solution**: A systemd service (`cni-config-fix.service`) that:

- Runs after K3s installation (`After=k3s-install.service`)
- Waits for the CNI config file to be created by K3s
- Creates a symlink from `/var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist` to `/etc/cni/net.d/`
- Restarts `containerd` to reload and discover the CNI configuration

This approach aligns with industry best practices for handling CNI timing issues on immutable systems. Research showed three recommended approaches: configuring containerd paths (which we did), managing systemd service dependencies (which we did), and restarting containerd after config is available (which we did). The restart ensures containerd picks up the config without requiring manual intervention.

Sometimes the right answer is to remove code, not add more—but when timing matters, a simple restart service is the pragmatic solution.
