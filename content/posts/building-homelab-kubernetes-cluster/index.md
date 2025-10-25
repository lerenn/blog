---
title: "Building a Kubernetes Homelab: From Network Infrastructure to K3s Cluster"
date: 2025-10-12T13:00:00+01:00
description: "Deploying a highly available K3s cluster on Fedora CoreOS with Butane/Ignition, featuring automated provisioning and future PXE-based upgrades"
tags: ["homelab", "kubernetes", "k3s", "fedora-coreos", "butane", "ignition", "infrastructure", "automation"]
categories: ["homelab", "kubernetes"]
---

# Building a Kubernetes Homelab: From Network to a Resilient K3s Cluster

This is the third post in my "Building a Kubernetes Homelab" series. If you haven't read the [first post](/posts/building-homelab-introduction/) and [second post](/posts/building-homelab-network/), start there — they set the stage for what comes next.

## The Leap: From Clean VLANs to a Real Cluster

The network was finally stable. VLANs behaved, DHCP worked, and devices were segmented the way I had always wanted. It was time to build the thing that had motivated all of this: a Kubernetes cluster that I could trust.

The plan sounded simple enough: 3 Lenovo mini PCs running Fedora CoreOS, bootstrapped via Ignition with Butane, forming a highly available K3s cluster with embedded etcd. Immutable OS, declarative provisioning, small footprint. What could go wrong?

## Choosing the Stack (and Owning Its Consequences)

I chose Fedora CoreOS and K3s for clear reasons:

- Immutable OS with atomic upgrades and SELinux
- First-boot provisioning via Ignition (written with Butane)
- K3s's embedded etcd and small footprint

And then I did what we all do: I customized it. I disabled Traefik, ServiceLB, local storage, metrics-server, and network policy, assuming I would add exactly what I wanted later.

That choice turned out to be the start of the story.

## The First Boot: Where Good Ideas Meet Reality

I wrote four Butane files — one for the first node in bootstrap mode and one for each node in join mode — and an installation script that would run once via systemd.

On paper, the flow was clean: set hostname, configure static IPs, fix SELinux context for the installer script, run a one-shot `k3s-install.service`, and let the K3s installer generate its own service. Idempotency was enforced with a stamp file. All the right ingredients were there.

And then the first boot failed.

## What Broke (and What That Taught Me)

- The hostname check was too strict. The node was named `lenovo1.lab.home.lerenn.net`, not just `lenovo1`, so it tried to join a cluster that didn't exist.
- SELinux wasn't amused. The installer script landed with the wrong context and systemd refused to execute it.
- The K3s service never started because I was waiting for it without starting it.
- When I tried to install external CNI plugins, I hit CoreOS's immutable root: I couldn't place binaries in `/usr/libexec/cni/` even if I wanted to.

Each of these issues was reasonable on its own. Together, they were a clear message: keep it simple, lean into the platform, and avoid fighting immutability.

## The Breakthrough: Stop Forcing It — Let K3s Handle CNI

The pivotal change was this: I stopped trying to install or manage CNIs myself. I let K3s handle its own built‑in Flannel CNI layer. No external downloads, no binary placement on a read‑only root, no custom DaemonSets. Just K3s doing K3s things.

From there, the cluster came to life.

## The Final Shape of the System

- Fedora CoreOS on all nodes
- Ignition via Butane for everything: files, systemd, network
- A single `k3s-install.sh` invoked by a one-shot unit
- SELinux fixed up front by a dedicated service
- K3s installed with disabled defaults, using its built‑in Flannel CNI
- Clean bootstrap-vs-join behavior and multiple API server endpoints for joins

### The Directory Layout I Ended Up With

```
machines/
├── README.md
├── butane/
│   ├── lenovo1-bootstrap.bu
│   ├── lenovo1.bu
│   ├── lenovo2.bu
│   └── lenovo3.bu
├── ignition/        # compiled .ign (gitignored)
└── scripts/
    └── k3s-install.sh
```

### The One Decision That Changed Everything

I stopped managing a CNI myself and let K3s use its built-in Flannel CNI. Here's the heart of the installer now:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - \
    --disable traefik \
    --disable servicelb \
    --disable local-storage \
    --disable metrics-server \
    --disable-network-policy \
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

## How I Install It Now (Fully Automated PXE Boot)

The installation process has evolved from manual USB installation to **complete automation via PXE boot**. The system now provides zero-touch FCOS installation with automatic Ignition application.

### The Complete PXE Boot Architecture

The system uses a hybrid approach: **PXE boot for automation** + **USB storage for large files**:

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

### Installation Commands

**For fully automated PXE boot setup:**
```bash
# Configure router with complete PXE boot system
make router/setup

# Build Ignition files for nodes
make machines/build
```

**The system now provides complete automation:**
- ✅ **Zero manual intervention** required
- ✅ **Per-node configuration** via inventory
- ✅ **Automatic Ignition application**
- ✅ **SSH access** configured on first boot
- ✅ **Ready for K3s installation** via Ignition

The PXE system automatically handles node identification via MAC address and serves the appropriate Ignition configuration for each node. The installation is completely hands-off once the system is configured.

## Lessons I Won't Forget

- Start with the defaults. K3s's built‑in Flannel CNI works and respects CoreOS immutability.
- Don't fight SELinux; prepare for it. Fix contexts explicitly before running installers.
- Let the K3s installer own its systemd unit.
- Idempotency matters. Stamp files beat clever conditionals.
- External registries go down. Fewer external dependencies = fewer surprises.
- **Explicit network configuration matters.** K3s needs `--cluster-cidr` and `--service-cidr` to properly initialize its CNI, even with defaults.
- **PXE boot complexity is real.** iPXE memory limits, TFTP server quirks, and bootloader compatibility all matter.
- **USB storage solves router limitations.** OpenWRT routers have limited internal storage; USB storage for large files is essential.
- **Standard iPXE EFI is more reliable.** Better UEFI compatibility than netboot.xyz for automated installation.
- **FCOS installer needs comprehensive parameters.** `ignition.firstboot`, `ignition.platform.id=metal`, and `coreos.inst.insecure` are all required.
- **Hybrid live + installer mode works.** The installer runs within the live environment with proper rootfs loading.

## What's Next

- Add Longhorn using the spare HDDs
- ~~Introduce a proper PXE flow for re‑imaging and upgrades~~ ✅ **Complete! Fully automated PXE boot with installer mode**
- Upgrade from Flannel to Cilium for advanced networking features
- Migrate services (HomeAssistant, monitoring, and more)
- Implement automated cluster scaling and node replacement

The cluster is up, the foundation is solid, and this time it feels maintainable.

---

If you want the blow‑by‑blow of the CNI detour and how I landed on the built‑in approach, I captured the full troubleshooting path below for future me (and anyone else who needs it).

## Appendix: PXE Boot Implementation — From Manual USB to Fully Automated Network Installation

### The Evolution: Three Phases of PXE Boot

Our PXE boot implementation went through three distinct phases, each solving different challenges:

#### Phase 1: The "Unknown Block Error" Challenge

The initial PXE boot attempts failed with a persistent **"VFS unable to mount root fs on unknown-block(0,0)"** error. This error occurred even though our PXE infrastructure was working perfectly (confirmed by Ubuntu booting successfully). After extensive troubleshooting and research, we discovered the issue was related to UEFI compatibility and kernel parameters.

**The Fix**: Use Standard iPXE EFI Binary + Live Mode with Deferred Rootfs Loading

```ipxe
kernel http://192.168.26.1/pxe/fcos/kernel initrd=initramfs.img coreos.live.rootfs_url=http://192.168.26.1/pxe/fcos/rootfs.img coreos.liveiso=1 rd.neednet=1 ip=dhcp console=tty0 console=ttyS0,115200n8 ipv6.disable=1
initrd http://192.168.26.1/pxe/fcos/initramfs.img
boot
```

#### Phase 2: The Installer Mode Challenge

Once we got the live environment booting, we faced a new challenge: **the automated installer wasn't starting**. The system would boot into the live environment and show "root account locked" but never begin the installation process.

**The Root Cause**: Missing required parameters for automated installation

**The Fix**: Comprehensive installer parameters

```ipxe
kernel http://192.168.26.1/pxe/fcos/kernel initrd=initramfs.img \
    ignition.firstboot \
    ignition.platform.id=metal \
    coreos.inst.install_dev=${dev} \
    coreos.inst.image_url=${image} \
    coreos.inst.ignition_url=${ign} \
    coreos.inst.insecure \
    coreos.live.rootfs_url=http://192.168.26.1/pxe/fcos/rootfs.img \
    rd.neednet=1 ip=dhcp console=tty0 console=ttyS0,115200n8 ipv6.disable=1
```

#### Phase 3: The Complete Automated Solution

The final working solution combines **live environment booting** with **automated installation**:

### Key Parameters That Made It Work:

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

### The Complete Automated Architecture

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

### The Result: Complete Automation

The system now provides **fully automated FCOS installation** via PXE boot:
- ✅ **Zero manual intervention** required
- ✅ **Per-node configuration** via inventory
- ✅ **Automatic Ignition application**
- ✅ **SSH access** configured on first boot
- ✅ **Ready for K3s installation** via Ignition

## Appendix: CNI Troubleshooting — The Long Way Around

I tried installing external CNI plugins and immediately hit the read‑only root of Fedora CoreOS. Even after fixing PodCIDR mismatches, kubelets were still looking in `/usr/libexec/cni/` for plugins I couldn't place there. It all disappeared the moment I stopped overriding K3s and let it manage its own built-in Flannel CNI. Sometimes the right answer is to remove code, not add more.
