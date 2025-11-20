---
title: "Building a Kubernetes Homelab: High Availability for the Control Plane"
date: 2025-11-20T15:00:00+01:00
description: "Implementing HA for the Kubernetes API server using MetalLB VIP, navigating certificate issues, and building resilient kubeconfig generation with automatic fallback"
tags: ["homelab", "kubernetes", "high-availability", "metallb", "k3s", "control-plane", "ansible", "tls", "certificates"]
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

1. **Create a LoadBalancer Service** for the k3s API server using MetalLB
2. **Use a dedicated VIP** for the control plane (separate from Traefik's VIP)
3. **Configure manual Endpoints** pointing to all control plane nodes
4. **Update kubeconfig** to use the VIP instead of a single node IP
5. **Ensure TLS certificates** include the VIP in their Subject Alternative Names

Simple, right? I had MetalLB already running, I knew how to create Services, and I understood the basics of Kubernetes networking. This should be a quick afternoon project.

Famous last words.

## Chapter 2: The VIP Conflict (When Two Services Want the Same IP)

I started by creating the HA control plane role. I defined the Service, the Endpoints, and configured everything to use the cluster VIP (192.168.X.254). I deployed it, checked the status, and...

```bash
$ kubectl get svc -A | grep -E "EXTERNAL-IP|192.168"
kube-system   k3s-api-server   LoadBalancer   10.43.X.X   192.168.X.253   6443:31163/TCP
traefik-system traefik         LoadBalancer   10.43.X.X  <pending>        80:32382/TCP,443:32088/TCP
```

Wait, what? Traefik was showing `<pending>` for its external IP, and my k3s-api-server had... 192.168.X.253? That wasn't the VIP I configured. And more importantly, why wasn't Traefik getting its IP?

I checked the MetalLB IP pool:

```bash
$ kubectl get ipaddresspool -n metallb-system
NAME          AVAILABLE   ASSIGNED
cluster-vip   0           2
```

Two IPs assigned, but only one service had an external IP. Something was wrong.

### The Discovery: Only One IP in the Pool

I looked at my MetalLB configuration and realized the problem: I had only configured one IP address in the pool (192.168.X.254), but both Traefik and the k3s-api-server were trying to use it. MetalLB in Layer 2 mode can only assign one IP to one service at a time.

The k3s-api-server got there first and claimed the VIP. Traefik was left hanging, which meant all my ingress services stopped working.

This was not ideal.

### The Solution: Two VIPs, Two Purposes

I needed to separate the concerns:

- **Control Planes VIP** (192.168.X.253): For the Kubernetes API server HA
- **Workers VIP** (192.168.X.254): For Traefik and ingress services

I updated the inventory structure to reflect this:

```yaml
# inventory.yaml
vips:
  control_planes: "192.168.X.253"  # HA control plane
  workers: "192.168.X.254"         # Traefik ingress
```

And updated MetalLB to include both IPs in the pool:

```yaml
# cluster/roles/metallb/templates/config.yaml.j2
spec:
  addresses:
  - {{ metallb_control_planes_ip }}  # 192.168.X.253/32
  - {{ metallb_workers_ip }}         # 192.168.X.254/32
```

Now both services could have their own LoadBalancer IPs. Problem solved!

Except it wasn't.

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

Everything was working, but I had a nagging thought: what if MetalLB goes down? What if the HA service becomes unavailable? My kubeconfig would be pointing to a VIP that doesn't work, and I'd be locked out of the cluster.

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
- **Uses the HA VIP** when available (resilient, load-balanced access)
- **Falls back to direct node IP** when HA is unavailable (ensures access even if MetalLB is down)

This gives me the best of both worlds: high availability when everything is working, and a safety net when things break.

## Chapter 5: The Service Configuration (Getting the Details Right)

With the VIPs separated and certificates updated, I needed to ensure the Service configuration was correct. The HA control plane service uses:

```yaml
# cluster/roles/ha-cp/templates/api-server-service.yaml.j2
apiVersion: v1
kind: Service
metadata:
  name: {{ ha_control_plane_service_name }}
  namespace: {{ ha_control_plane_namespace }}
spec:
  type: LoadBalancer
  loadBalancerIP: {{ ha_control_plane_vip }}
  externalTrafficPolicy: Cluster
  ports:
    - port: {{ ha_control_plane_port }}
      targetPort: {{ ha_control_plane_port }}
      protocol: TCP
      name: https
  # No selector - we use manual Endpoints resource instead
```

Key points:

- **No selector**: We use a manual Endpoints resource to point to all control plane nodes
- **externalTrafficPolicy: Cluster**: Allows traffic to be routed to any node, not just the one announcing the IP
- **Manual Endpoints**: Dynamically populated with all control plane node IPs

The Endpoints resource is generated from the Kubernetes API itself, ensuring it always reflects the current cluster state:

```yaml
# cluster/roles/ha-cp/templates/api-server-endpoints.yaml.j2
apiVersion: v1
kind: Endpoints
metadata:
  name: {{ ha_control_plane_service_name }}
  namespace: {{ ha_control_plane_namespace }}
subsets:
  - addresses:
{% for ip in control_plane_node_ips %}
      - ip: {{ ip }}
{% endfor %}
    ports:
      - port: {{ ha_control_plane_port }}
        protocol: TCP
        name: https
```

This ensures that if a control plane node fails and is removed from the cluster, the Endpoints automatically update to exclude it, and traffic is only routed to healthy nodes.

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

✅ **Automatic Failover**: If one control plane node fails, traffic automatically routes to the remaining healthy nodes

✅ **Separated VIPs**: Control planes and workers have their own VIPs, preventing conflicts

✅ **Smart Kubeconfig**: Automatic detection of HA availability with fallback to direct node access

✅ **VPN Access**: The HA control plane is accessible from anywhere through the VPN

✅ **TLS Security**: All certificates properly include the VIP in their SAN lists

✅ **Future-Proof**: New nodes automatically get the correct TLS SAN configuration via Butane templates

## The Ansible Structure

The HA control plane role is organized in `cluster/roles/ha-cp/`:

```text
cluster/roles/ha-cp/
├── defaults/
│   └── main.yaml              # VIP configuration
├── tasks/
│   ├── install.yaml            # Deploy Service and Endpoints
│   ├── configure.yaml          # Configuration tasks (empty for now)
│   └── uninstall.yaml          # Cleanup tasks
└── templates/
    ├── api-server-service.yaml.j2
    └── api-server-endpoints.yaml.j2
```

The role is integrated into the main cluster playbooks:

```yaml
# cluster/playbooks/install.yaml
- name: Install cluster infrastructure
  hosts: localhost
  tasks:
    - name: Install infrastructure components
      include_role:
        name: "{{ item }}"
      loop:
        - metrics-server
        - metallb
        - ha-cp              # HA control plane
        - traefik
```

## Lessons Learned

This journey taught me several important lessons about high availability in Kubernetes:

1. **VIP Conflicts Are Real**: When multiple services need LoadBalancer IPs, plan your IP allocation carefully. One IP per service is the rule in Layer 2 mode.

2. **TLS Certificates Are Fussy**: Always include VIPs in the `tls-san` configuration from the start. Updating certificates on running nodes is possible but requires restarts.

3. **Fallback Is Essential**: Even with HA, things can break. Building automatic fallback into tooling ensures you're never locked out of your cluster.

4. **Service vs Endpoints**: Manual Endpoints resources are powerful for services without selectors, but they require dynamic updates to reflect cluster state.

5. **Test Everything**: Connectivity tests, TLS validation, and kubectl commands all need to work. Don't assume that if one works, they all do.

6. **Inventory Structure Matters**: Clear separation of concerns (control_planes vs workers VIPs) makes the architecture easier to understand and maintain.

7. **externalTrafficPolicy Matters**: `Cluster` mode provides better HA than `Local` mode for services with manual Endpoints, as it allows routing to any node.

8. **Automation Saves Time**: Having Ansible playbooks to update TLS SAN and regenerate kubeconfig makes recovery from issues much faster.

## Conclusion

The cluster now has true high availability for the control plane. The Kubernetes API server is accessible via a VIP that automatically routes to any available control plane node, ensuring resilience even if individual nodes fail.

The smart kubeconfig generation with automatic fallback provides an additional safety net, ensuring cluster access is maintained even if MetalLB or the HA service becomes unavailable.

The foundation is now truly resilient, and I can confidently manage the cluster knowing that single points of failure have been eliminated.

---

*Check out the [previous post](/posts/building-homelab-foundation-layer/) to see how we deployed the cluster infrastructure, or read the [first post](/posts/building-homelab-introduction/) for the complete journey from the beginning.*
