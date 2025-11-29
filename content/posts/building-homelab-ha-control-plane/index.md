---
title: "Building a Kubernetes Homelab: High Availability for the Control Plane"
date: 2025-11-20T15:00:00+01:00
description: "Implementing HA for the Kubernetes API server using keepalived on host, navigating certificate issues, and building resilient kubeconfig generation with automatic fallback"
tags: ["homelab", "kubernetes", "high-availability", "keepalived", "k3s", "control-plane", "ansible", "tls", "certificates", "vrrp"]
categories: ["homelab", "kubernetes"]
---

*This is the fifth post in our "Building a Kubernetes Homelab" series. Check out the [previous post](/posts/building-homelab-foundation-layer/) to see how we deployed MetalLB, Traefik, Longhorn, and container registries.*

## The Single Point of Failure Problem

The cluster was running beautifully. Three nodes, all services deployed, everything humming along. I could access my services from anywhere via VPN, manage the cluster with `kubectl`, and life was good.

Until I realized I had a problem.

Every time I wanted to connect to the cluster, I was using a kubeconfig that pointed to a single node IP. If that node went down, I'd lose access to the cluster entirely. Not exactly what you'd call "high availability."

```yaml
# My kubeconfig was pointing to this:
server: https://192.168.X.5:6443  # node1 - single point of failure
```

This was fine for a development cluster, but I wanted something more resilient. I wanted a Virtual IP (VIP) that would automatically route to any available control plane node, ensuring I could always reach the API server even if one node failed.

What could go wrong?

## Chapter 1: The Plan (It Always Starts with a Plan)

The solution seemed straightforward:

1. **Deploy keepalived on all control plane nodes** as a systemd service (host-level, independent of Kubernetes)
2. **Configure VRRP** to manage the VIP (192.168.X.253) with automatic failover
3. **Add health checks** to ensure only healthy nodes hold the VIP
4. **Update kubeconfig** to use the VIP instead of a single node IP
5. **Ensure TLS certificates** include the VIP in their Subject Alternative Names

Simple, right? Keepalived is a battle-tested solution for VIP management, runs independently of Kubernetes, and provides automatic health checking. This should be a quick afternoon project.

Famous last words.

## Chapter 2: Why Keepalived Instead of MetalLB?

Initially, I considered using MetalLB for the control plane VIP, but I quickly realized this had a fundamental flaw: **MetalLB depends on Kubernetes**. If Kubernetes is down, MetalLB can't manage the VIP, which means I'd lose access to the API server exactly when I need it most.

Keepalived solves this by running **on the host** (via systemd), completely independent of Kubernetes:

- **Early availability**: Starts during boot, before Kubernetes
- **Independence**: Works even if Kubernetes is down
- **Direct network access**: Manages VIP at the network interface level
- **Health checks**: Can verify K3s API server health and automatically failover

I configured keepalived to run in a container (via podman) managed by systemd, which is the standard approach on Fedora CoreOS. The configuration includes:

- **VRRP instance**: Manages the VIP (192.168.X.253) with automatic failover
- **Health check script**: Monitors the local K3s API server on port 6443
- **Priority-based election**: Determines which node should hold the VIP initially
- **No preemption**: Health checks determine VIP ownership, not just priority

The inventory structure defines the VIP:

```yaml
# inventory.yaml
vips:
  control_planes: "192.168.X.253"  # HA control plane (managed by keepalived)
  workers: "192.168.X.254"         # Traefik ingress (managed by MetalLB)
```

This separation ensures that control plane HA is independent of Kubernetes, while worker services (like Traefik) can still use MetalLB for LoadBalancer functionality.

## Chapter 3: The Certificate Problem (TLS Strikes Again)

With the VIPs properly separated, I regenerated my kubeconfig to use the control planes VIP (192.168.X.253). I tried to connect:

```bash
$ kubectl get nodes
E1120 15:19:30.367321    7464 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list: Get \"https://192.168.X.253:6443/api?timeout=32s\": tls: failed to verify certificate: x509: certificate is valid for 10.43.X.X, 127.0.0.1, 192.168.X.254, 192.168.X.5, 192.168.X.6, 192.168.X.7, ::1, not 192.168.X.253"
```

Ah, the classic TLS certificate problem. The k3s API server's certificate didn't include the new control planes VIP (192.168.X.253) in its Subject Alternative Names. It had the old VIP (192.168.X.254) and the individual node IPs, but not the new one.

I checked the k3s configuration on the nodes:

```bash
$ sudo cat /etc/rancher/k3s/config.yaml
tls-san: [192.168.X.254]  # The old VIP, not the new one
```

The nodes had been provisioned with the old VIP in their `tls-san` configuration. I needed to update all control plane nodes to include the new VIP and restart k3s to regenerate the certificates.

### The Fix: Updating TLS SAN on All Nodes

I created a playbook to update the k3s configuration on all control plane nodes:

```yaml
# machines/playbooks/update-k3s-tls-san.yaml
- name: Update k3s TLS SAN to include control planes VIP
  hosts: kubernetes_cluster
  gather_facts: false
  vars:
    control_planes_vip: "{{ hostvars[groups['kubernetes_cluster'][0]].vips.control_planes }}"

  tasks:
    - name: Check if node is control plane
      set_fact:
        is_control_plane: "{{ control_plane | default(false) | bool }}"

    - name: Skip if not control plane node
      meta: end_play
      when: not is_control_plane

    - name: Read current k3s config
      slurp:
        src: /etc/rancher/k3s/config.yaml
      register: k3s_config_content
      become: yes

    - name: Update k3s config to add VIP to tls-san
      copy:
        content: |
          {{ (k3s_config_content.content | b64decode | from_yaml) | combine({'tls-san': ((k3s_config_content.content | b64decode | from_yaml).get('tls-san', []) + [control_planes_vip]) | unique}) | to_yaml }}
        dest: /etc/rancher/k3s/config.yaml
        mode: '0644'
      become: yes
      register: config_updated

    - name: Restart k3s service to regenerate certificates
      systemd:
        name: k3s
        state: restarted
      become: yes
      when: config_updated.changed | default(false) | bool
```

This playbook:

1. Reads the current k3s configuration
2. Adds the control planes VIP to the `tls-san` list (if not already present)
3. Restarts k3s to regenerate certificates with the new SAN

After running this on all three control plane nodes and waiting for the certificates to regenerate, the kubeconfig worked perfectly. I could now connect via the VIP from both my laptop (through VPN) and from machines on the same VLAN.

Success! Or so I thought.

## Chapter 4: The Fallback Problem (What If HA Fails?)

Everything was working, but I had a nagging thought: what if keepalived goes down? What if the VIP becomes unavailable? My kubeconfig would be pointing to a VIP that doesn't work, and I'd be locked out of the cluster.

This was a real concern. In a homelab, things break. Services restart, nodes reboot, network issues happen. I needed a resilient kubeconfig generation process that could detect when the HA VIP wasn't working and fall back to a direct node connection.

### The Solution: Smart Kubeconfig Generation with Fallback

I updated the `get-kubeconfig.yaml` playbook to:

1. **Test HA VIP connectivity** - Check if the VIP is reachable
2. **Validate TLS certificate** - Ensure the certificate is valid for the VIP
3. **Fallback to direct node IP** - If HA fails, use the first responsive control plane node

```yaml
# machines/playbooks/get-kubeconfig.yaml
- name: Check if HA control plane VIP is reachable
  command: "timeout 3 bash -c 'echo > /dev/tcp/{{ ha_control_plane_vip }}/6443'"
  register: ha_vip_check
  ignore_errors: true
  delegate_to: localhost
  become: false
  changed_when: false

- name: Create temporary kubeconfig for HA VIP test
  copy:
    content: "{{ kubeconfig_output.stdout | regex_replace('127\\.0\\.0\\.1:6443', ha_control_plane_vip + ':6443') }}"
    dest: "{{ playbook_dir }}/../data/kubeconfig-test-ha.tmp"
    mode: '0600'
  when: 
    - kubeconfig_output.rc == 0
    - kubeconfig_output.stdout is defined
    - ha_vip_check.rc == 0
  become: false
  delegate_to: localhost

- name: Test HA VIP with kubectl (verify TLS certificate is valid)
  command: "timeout 5 kubectl --kubeconfig={{ playbook_dir }}/../data/kubeconfig-test-ha.tmp get nodes --no-headers"
  register: ha_vip_kubectl_test
  ignore_errors: true
  delegate_to: localhost
  become: false
  changed_when: false
  when: 
    - kubeconfig_output.rc == 0
    - kubeconfig_output.stdout is defined
    - ha_vip_check.rc == 0

- name: Determine if HA VIP is working
  set_fact:
    ha_vip_working: "{{ (ha_vip_check.rc == 0) and (ha_vip_kubectl_test.rc | default(1) == 0) }}"
  become: false

- name: Display HA VIP status
  debug:
    msg: "HA VIP ({{ ha_control_plane_vip }}) is {{ 'working' if ha_vip_working else 'not working' }}. {{ 'Using HA VIP' if ha_vip_working else 'Falling back to direct node IP' }}."
  become: false

- name: Replace 127.0.0.1 with HA control plane VIP in kubeconfig (HA mode)
  set_fact:
    kubeconfig_final: "{{ kubeconfig_output.stdout | regex_replace('127\\.0\\.0\\.1:6443', ha_control_plane_vip + ':6443') }}"
  when: 
    - kubeconfig_output.rc == 0
    - kubeconfig_output.stdout is defined
    - ha_vip_working | default(false) | bool
  become: false

- name: Replace 127.0.0.1 with responsive node IP in kubeconfig (fallback mode)
  set_fact:
    kubeconfig_final: "{{ kubeconfig_output.stdout | regex_replace('127\\.0\\.0\\.1:6443', source_node_ip + ':6443') }}"
  when: 
    - kubeconfig_output.rc == 0
    - kubeconfig_output.stdout is defined
    - not (ha_vip_working | default(false) | bool)
  become: false
```

Now the playbook automatically:

- **Detects if HA is working** by testing both connectivity and TLS validation
- **Uses the HA VIP** when available (resilient, automatic failover)
- **Falls back to direct node IP** when HA is unavailable (ensures access even if keepalived is down)

This gives me the best of both worlds: high availability when everything is working, and a safety net when things break.

## Chapter 5: The Keepalived Configuration (Getting the Details Right)

With keepalived running on all control plane nodes, I needed to ensure the configuration was correct. The keepalived setup includes:

### VRRP Configuration

```conf
# /etc/keepalived/keepalived.conf
vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100  # Node-specific: lenovo1=100, lenovo2=90, lenovo3=80
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k3s-keepalived-secret
    }
    virtual_ipaddress {
        192.168.X.253/32
    }
    track_script {
        chk_k3s
    }
    nopreempt  # Health checks determine VIP ownership
}
```

Key points:

- **Virtual Router ID**: Unique ID (51) for the cluster's VRRP instance
- **Priority**: Node-specific priorities (100, 90, 80) determine initial master election
- **No preemption**: Health checks determine who holds the VIP, not just priority
- **Health check integration**: The `chk_k3s` script monitors K3s API server health

### Health Check Script

```bash
#!/bin/bash
# /usr/local/bin/k3s-healthcheck.sh
# Returns 0 if healthy, non-zero if unhealthy

# Check if K3s API server is listening
if ! netstat -tuln 2>/dev/null | grep -q ':6443 '; then
    exit 1
fi

# Check if K3s API server responds to health check
if curl -k -s --max-time 2 --connect-timeout 2 https://localhost:6443/healthz >/dev/null 2>&1; then
    exit 0
else
    exit 1
fi
```

This script ensures that only nodes with a healthy K3s API server hold the VIP. If a node's API server fails, keepalived automatically releases the VIP, allowing another healthy node to take over.

### Systemd Service

```ini
# /etc/systemd/system/keepalived.service
[Unit]
Description=Keepalived for K3s API server HA
After=network-online.target
Before=k3s.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/podman run --rm \
    --name keepalived \
    --network host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_BROADCAST \
    --cap-add=NET_RAW \
    --cap-add=SYS_TIME \
    --volume /etc/keepalived/keepalived.conf:/etc/keepalived/keepalived.conf:ro \
    --volume /usr/local/bin/k3s-healthcheck.sh:/usr/local/bin/k3s-healthcheck.sh:ro \
    docker.io/osixia/keepalived:latest
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

The service:

- Runs keepalived in a container with host networking (required for VIP management)
- Starts before k3s (ensures VIP is available when Kubernetes starts)
- Automatically restarts on failure
- Mounts configuration and health check script as read-only volumes

## Chapter 6: The Network Configuration (Ensuring VPN Access Works)

With the HA control plane working within the cluster, I wanted to ensure it was accessible from my laptop through VPN. I checked the firewall configuration and found that VPN to Lab VLAN forwarding was already configured, but I wanted to make it explicit.

I added a specific firewall rule for the Kubernetes API server port:

```yaml
# network/roles/router/templates/firewall/firewall.conf
# VPN to Lab forwarding (for remote development access)
config forwarding
  option src    vlan30              # Source: VPN VLAN
  option dest   vlan26              # Destination: Lab VLAN (example VLAN numbers)
```

The forwarding rule was sufficient - OpenWRT's zone-based firewall allows all traffic between zones when forwarding is enabled. The explicit rule I initially added was redundant, so I removed it to keep the configuration clean.

## What We Achieved

With the HA control plane implementation complete, we now have:

✅ **Resilient API Access**: The k3s API server is accessible via a VIP that automatically routes to any available control plane node

✅ **Automatic Failover**: If one control plane node fails, keepalived automatically migrates the VIP to a healthy node

✅ **Host-Level Independence**: Keepalived runs on the host, independent of Kubernetes, ensuring VIP availability even if Kubernetes is down

✅ **Health Checks**: Only nodes with healthy K3s API servers hold the VIP

✅ **Separated VIPs**: Control planes (keepalived) and workers (MetalLB) have their own VIPs, preventing conflicts

✅ **Smart Kubeconfig**: Automatic detection of HA availability with fallback to direct node access

✅ **VPN Access**: The HA control plane is accessible from anywhere through the VPN

✅ **TLS Security**: All certificates properly include the VIP in their SAN lists

✅ **Future-Proof**: New nodes automatically get keepalived and correct TLS SAN configuration via Butane templates

## The Implementation Structure

Keepalived is configured via Butane/Ignition during node provisioning, ensuring it's baked into the node image:

```text
machines/roles/build-pxe-files/templates/
├── butane/
│   ├── lenovo1-bootstrap.bu.j2    # Includes keepalived config
│   ├── lenovo1-reinstall.bu.j2   # Includes keepalived config
│   ├── lenovo2.bu.j2             # Includes keepalived config
│   └── lenovo3.bu.j2             # Includes keepalived config
└── configs/
    ├── keepalived.conf.j2         # VRRP configuration template
    ├── k3s-healthcheck.sh.j2     # Health check script template
    └── keepalived.service.j2      # Systemd service unit template
```

The configuration is deployed to the router's HTTP server and sourced by Butane files during node provisioning:

```yaml
# Butane file excerpt
files:
  - path: /etc/keepalived/keepalived.conf
    contents:
      source: http://192.168.26.1/pxe/configs/keepalived-lenovo1.conf
  - path: /usr/local/bin/k3s-healthcheck.sh
    contents:
      source: http://192.168.26.1/pxe/configs/k3s-healthcheck.sh
  - path: /etc/systemd/system/keepalived.service
    contents:
      source: http://192.168.26.1/pxe/configs/keepalived.service

systemd:
  units:
    - name: keepalived.service
      enabled: true
```

## Lessons Learned

This journey taught me several important lessons about high availability in Kubernetes:

1. **Host-Level Independence Matters**: Running keepalived on the host (systemd) instead of in Kubernetes ensures the VIP is available even when Kubernetes is down. This is critical for control plane HA.

2. **Health Checks Are Essential**: Keepalived's health check script ensures only nodes with healthy K3s API servers hold the VIP. Without this, a node could hold the VIP even if its API server is down.

3. **TLS Certificates Are Fussy**: Always include VIPs in the `tls-san` configuration from the start. Updating certificates on running nodes is possible but requires restarts.

4. **Fallback Is Essential**: Even with HA, things can break. Building automatic fallback into tooling ensures you're never locked out of your cluster.

5. **No Preemption Is Better**: Using `nopreempt` in keepalived means health checks determine VIP ownership, not just priority. This prevents flapping when nodes recover.

6. **Butane Integration**: Configuring keepalived via Butane/Ignition ensures it's baked into the node image and automatically configured during reinstall.

7. **Test Everything**: Connectivity tests, TLS validation, and kubectl commands all need to work. Don't assume that if one works, they all do.

8. **Inventory Structure Matters**: Clear separation of concerns (control_planes vs workers VIPs) makes the architecture easier to understand and maintain.

9. **Container vs Native**: Running keepalived in a container (podman) on Fedora CoreOS is the standard approach, providing isolation while maintaining host-level network access.

## Conclusion

The cluster now has true high availability for the control plane. The Kubernetes API server is accessible via a VIP (192.168.X.253) managed by keepalived, which automatically migrates to healthy nodes when failures occur.

Keepalived runs on the host (systemd), completely independent of Kubernetes, ensuring the VIP is available even when Kubernetes is down. Health checks ensure only nodes with healthy K3s API servers hold the VIP, providing automatic failover based on actual service health, not just node availability.

The smart kubeconfig generation with automatic fallback provides an additional safety net, ensuring cluster access is maintained even if keepalived becomes unavailable.

The foundation is now truly resilient, and I can confidently manage the cluster knowing that single points of failure have been eliminated and that the control plane HA is independent of Kubernetes itself.

---

*Check out the [previous post](/posts/building-homelab-foundation-layer/) to see how we deployed the cluster infrastructure, or read the [first post](/posts/building-homelab-introduction/) for the complete journey from the beginning.*
