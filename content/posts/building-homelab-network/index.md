---
title: "Building a Kubernetes Homelab: My Journey from ISP Router to VLAN-Segmented Network"
date: 2025-09-20T11:00:00+01:00
description: "A personal journey through network automation, hardware failures, and the satisfaction of building a proper homelab infrastructure"
tags: ["homelab", "networking", "vlan", "openwrt", "security", "infrastructure", "ansible", "story"]
categories: ["homelab", "networking"]
---

# Building a Kubernetes Homelab: My Journey from ISP Router to VLAN-Segmented Network

*This is the second post in our "Building a Kubernetes Homelab" series. If you haven't read the [first post](/posts/homelab-network-vlan-setup/) yet, I recommend starting there for the full context of this project.*

## The Beginning: A Dream and a Plan

It all started with a simple dream: transform my basic homelab into a properly segmented, Kubernetes-based infrastructure. I had been running everything on a single network for years, and the security implications were starting to keep me up at night. Smart home devices mixed with servers, personal devices sharing the same subnet as my lab equipment – it was a security nightmare waiting to happen.

In my [previous post](/posts/homelab-network-vlan-setup/), I outlined the vision: 5 VLANs (Management, Lab, IoT, Devices, Guests) with proper isolation, automated configuration, and a path to Kubernetes. Now it was time to make it real.

## Chapter 1: The First Hardware Choice and Its Betrayal

### The Budget Router: A Love Story That Wasn't Meant to Be

I started with what seemed like a reasonable choice: a budget OpenWRT-compatible router. It was affordable, had good reviews, and supported OpenWRT. Perfect for a homelab project, right?

**Wrong.**

The first red flag came when I tried to configure it through SSH. The router would accept my configuration changes, everything would work perfectly... until I rebooted it. Then it would reset to factory defaults, losing everything I had painstakingly configured.

I spent hours troubleshooting this issue. I tried:
- Disabling proprietary GL.iNet services (repeater, gl-config)
- Force remounting the overlay filesystem as read-write
- Multiple sync operations and cache clearing
- Enhanced save processes with explicit commit commands

Nothing worked. Every single reboot would wipe my configuration clean.

### The Realization: Proprietary Firmware Hell

After extensive research and countless failed attempts, I finally understood the problem: **this router runs a heavily modified version of OpenWRT that resets all configuration after every reboot**. This isn't a bug – it's by design. The manufacturer's custom firmware is designed to work with their proprietary web interface and mobile app, not with standard OpenWRT UCI configuration management.

I was fighting against the fundamental architecture of the device. No amount of Ansible automation, no clever configuration tricks, no amount of persistence commands would change this behavior.

### The Hard Decision: Hardware Upgrade

I had to face the music: I needed different hardware. After researching alternatives, I ordered a **mid-range OpenWRT router** which supports flashing with vanilla OpenWRT firmware.

This was a significant investment, but I was committed to doing this right. The new router would give me:
- Full control over configuration persistence
- Standard UCI commands working as expected
- No proprietary service interference
- Better long-term maintainability
- Access to the full OpenWRT package ecosystem

## Chapter 2: The GL-MT3000 Arrives – A New Beginning

### Unboxing and First Impressions

When the new router arrived, I was excited but cautious. I had been burned by the previous router, so I approached this with measured optimism.

The hardware felt solid, and the setup process was straightforward. I flashed it with vanilla OpenWRT, configured SSH access, and updated my inventory to use the standard 192.168.1.x management network.

### The First Success: Configuration Persistence

The moment of truth came when I configured the router, rebooted it, and... **it kept my configuration!** This was a revelation. For the first time, I had a router that actually respected my configuration changes.

I immediately started building my Ansible automation system, confident that this time it would work.

## Chapter 3: Building the Automation Foundation

### The Ansible Infrastructure Takes Shape

With a reliable router, I could finally focus on building proper automation. I created a comprehensive Ansible structure with roles for:

- **Common**: Shared configuration and package management
- **Router**: OpenWRT-specific configuration
- **Switch**: Managed switch configuration (manual for now)
- **Testing**: Network validation and health checks

### The Template System: My First Major Breakthrough

The first major challenge was getting Jinja2 templates to work properly. I initially tried using the `copy` module, but variables weren't being resolved. After some research, I discovered I needed to use the `template` module instead.

```yaml
# This didn't work
- name: Deploy network configuration
  copy:
    src: network.conf
    dest: /etc/config/network

# This worked
- name: Deploy network configuration
  template:
    src: network.conf
    dest: /etc/config/network
    backup: yes
    mode: '0644'
```

This was a small change, but it unlocked the power of dynamic configuration generation. Now I could use variables like `{{ vlans.management.gateway }}` and have them properly resolved.

### The Python3 Challenge

Another early hurdle was getting Python3 working on OpenWRT for full Ansible module support. The default installation was minimal, so I had to install additional packages:

```yaml
- name: Install required packages
  raw: |
    opkg update && opkg install python3 python3-pip
  register: package_install
  retries: 3
  delay: 5
  until: package_install.rc == 0
```

This took several attempts due to network instability, but the retry logic I built into the playbook eventually succeeded.

## Chapter 4: The VLAN Configuration Journey

### The First VLAN Attempt: A Learning Experience

With the basic automation working, I turned my attention to VLAN configuration. I started with a simple approach: configure the router VLANs first, then the switch.

This seemed logical, but I quickly discovered that **order matters**. When I configured the switch VLANs before the router was ready, I lost connectivity entirely. The switch was sending VLAN-tagged traffic that the router couldn't handle yet.

### The Breakthrough: Router First, Then Switch

After several frustrating attempts, I learned the correct sequence:
1. **Router VLANs**: Configure all VLAN interfaces and bridges on the router
2. **Switch VLANs**: Configure the managed switch with proper trunk and access ports
3. **Testing**: Validate connectivity and DHCP functionality

This order was crucial because the router needed to be ready to handle VLAN-tagged traffic before the switch started sending it.

### The MAC Address Format Mystery

One of the most frustrating issues I encountered was with DHCP static assignments. I had configured a static lease for my switch:

```yaml
config host
    option name 'switch-device'
    option mac 'aa:bb:c:d:e:f'  # This didn't work
    option ip '192.168.1.2'
```

The switch wasn't getting its static IP. After hours of debugging, I discovered the issue: **MAC addresses need leading zeros**. The correct format was:

```yaml
config host
    option name 'switch-device'
    option mac 'aa:bb:0c:0d:0e:0f'  # This worked
    option ip '192.168.1.2'
```

This was a subtle but critical difference that taught me to always verify MAC address formats in network configurations.

## Chapter 5: The WiFi Configuration Saga

### The WPA2 Package Nightmare

With VLANs working, I turned my attention to WiFi configuration. This turned out to be one of the most challenging parts of the entire project.

The first issue was WPA2 support. OpenWRT ships with `wpad-basic-mbedtls` by default, which doesn't support WPA2-PSK encryption. I needed the full `wpad` package:

```yaml
- name: Install full wpad package for WPA2 support
  raw: |
    opkg update && opkg remove wpad-basic-mbedtls && opkg install wpad
  register: wpad_install
  retries: "{{ ansible_retry_attempts }}"
  delay: "{{ ansible_retry_delay }}"
  until: wpad_install.rc is defined and wpad_install.rc == 0
```

This process was fragile and required multiple attempts, but it was essential for proper WiFi security.

### The Hardware Path Discovery

The next challenge was finding the correct hardware paths for the GL-MT3000's WiFi radios. The standard OpenWRT paths didn't work, and I spent considerable time experimenting with different configurations.

Eventually, I discovered the correct paths:
- 2.4GHz: `platform/soc/xxxxx.wifi`
- 5GHz: `platform/soc/xxxxx.wifi+1`

### The Encryption Syntax Puzzle

Even with the correct hardware paths, WiFi configuration wasn't working. The issue was with the encryption syntax. I was using `'wpa2'` but OpenWRT expects `'psk2'`:

```yaml
# This didn't work
option encryption 'wpa2'

# This worked
option encryption 'psk2'
```

This was another subtle difference that took time to debug, but it was the final piece needed for WiFi functionality.

## Chapter 6: The DHCP Crisis

### The APIPA Address Mystery

With WiFi networks broadcasting and VLANs configured, I expected everything to work smoothly. Instead, I encountered a new problem: **WiFi clients were receiving APIPA addresses (169.254.x.x) instead of proper VLAN IP addresses**.

This was a critical issue that indicated DHCP wasn't working for WiFi clients on VLAN networks.

### The Root Cause Investigation

I spent days investigating this issue. The problem had multiple components:

**Issue 1: DNSMasq Service Restart**
- DNSMasq wasn't automatically restarting after DHCP configuration changes
- VLAN DHCP ranges weren't being generated in the DNSMasq configuration file

**Issue 2: WiFi VLAN Bridging**
- WiFi interfaces were not properly bridged to VLAN interfaces
- VLAN interfaces were configured directly on `eth1.27`, `eth1.28`, etc.
- WiFi clients couldn't communicate with DHCP servers on VLAN interfaces

### The Solution: VLAN Bridge Configuration

The breakthrough came when I realized I needed to create bridges for each VLAN network. Instead of configuring VLAN interfaces directly, I needed to bridge them:

**Before (broken configuration):**
```yaml
config interface 'vlan20'
    option proto 'static'
    option ipaddr '192.168.20.1'
    option netmask '255.255.255.0'
    option ifname 'eth1.20'
```

**After (working configuration):**
```yaml
config device
    option name 'br-vlan20'
    option type 'bridge'
    list ports 'eth1.20'

config interface 'vlan20'
    option device 'br-vlan20'
    option proto 'static'
    option ipaddr '192.168.20.1'
    option netmask '255.255.255.0'
```

This change, combined with automatic DNSMasq restarts, finally made DHCP work for WiFi clients.

## Chapter 7: The Firewall Configuration Nightmare

### The Final Hurdle: Firewall Syntax

Even with VLAN bridges working, I was still getting APIPA addresses. The issue was with my firewall configuration syntax. After analyzing the original OpenWRT firewall configuration, I discovered several critical syntax differences:

**Key Issues Found:**
1. **Network List Format**: Used `option network 'lan'` instead of `list network 'lan'`
2. **ICMP Type Format**: Used `option icmp_type` with space-separated values instead of `list icmp_type`
3. **Conflicting Rules**: Added unnecessary `wan→lan` forwarding that broke Management VLAN connectivity
4. **Structure Mismatch**: Didn't preserve the original OpenWRT firewall structure

### The Breakthrough: Analyzing Original Configuration

The solution was to study the default OpenWRT firewall configuration and use the correct syntax:

```yaml
# Correct syntax
config zone
    option name 'lan'
    list network 'lan'  # Not option network 'lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'

config rule
    option name 'Allow-ICMPv6-Input'
    option src 'wan'
    option proto 'icmp'
    list icmp_type 'echo-request'  # Not option icmp_type 'echo-request'
    list icmp_type 'echo-reply'
    option family 'ipv6'
    option target 'ACCEPT'
```

This was the final piece of the puzzle. With correct firewall syntax, DHCP finally worked properly for all VLANs.

## Chapter 8: Device Integration and Real-World Testing

### HomeAssistant: The First Real Device

With the network infrastructure working, I could finally start connecting real devices. The first was my HomeAssistant instance, which I wanted on the IoT VLAN.

This was relatively straightforward:
- Connected HomeAssistant to the IoT Ethernet network
- Configured static DHCP lease with MAC address `aa:bb:cc:dd:ee:ff`
- Set up firewall rules to allow Management, Lab, Devices, and Guest VLANs to access IoT VLAN

The HomeAssistant integration was successful, and I could access it from any VLAN as intended.

### The Printer Saga: Dual-Band WiFi Discovery

The printer integration was more challenging. I had a network printer that I wanted on the Devices VLAN, but it couldn't see the "HomeDevices" WiFi network.

After some investigation, I discovered the issue: **the printer only supports 2.4GHz, but HomeDevices was only broadcasting on 5GHz**.

### The Dual-Band Solution

The solution was to configure HomeDevices to broadcast on both 2.4GHz and 5GHz:

```yaml
# HomeDevices dual-band configuration
- name: "HomeDevices"
  vlan: 20
  security: "wpa2"
  password_key: "devices"
  radio: "radio0"  # 2.4GHz for printer compatibility
- name: "HomeDevices"
  vlan: 20
  security: "wpa2"
  password_key: "devices"
  radio: "radio1"  # 5GHz for modern devices
```

This required fixing a configuration conflict where the same SSID on different radios would create duplicate `wifi-iface` identifiers. I solved this by including the radio name in the identifier:

```yaml
config wifi-iface 'homedevices_radio0'  # 2.4GHz
config wifi-iface 'homedevices_radio1'  # 5GHz
```

### The MAC Address Correction

Even with dual-band WiFi working, the printer still wasn't getting its static IP. After checking the DHCP leases, I discovered the printer was using a different MAC address than I had configured. I had to update the inventory with the correct MAC address `ff:ee:dd:cc:bb:aa`.

This taught me the importance of verifying actual device MAC addresses rather than relying on documentation or assumptions.

## Chapter 9: Network Security and Access Control

### Implementing Firewall Rules

With devices connected, I needed to implement proper network security. I created firewall rules that allowed controlled access between VLANs:

- **IoT VLAN Access**: Management, Lab, Devices, and Guest VLANs can access IoT VLAN
- **Devices VLAN Access**: Management VLAN can access Devices VLAN for printer management
- **Bidirectional Isolation**: IoT and Devices VLANs cannot access other VLANs
- **Internet Access**: All VLANs have proper internet connectivity

### The Security Matrix

I documented the access policies in a clear matrix:

| Source VLAN | Management VLAN | Lab VLAN | IoT VLAN | Devices VLAN | Guest VLAN | VPN VLAN | Internet |
|-------------|-----------------|----------|----------|--------------|------------|----------|----------|
| Management  |                 | ✅       | ✅       | ✅           | ✅         | ✅       | ✅       |
| Lab         | ❌              |          | ✅       | ❌           | ❌         | ❌       | ✅       |
| IoT         | ❌              | ❌       |          | ❌           | ❌         | ❌       | ✅       |
| Devices     | ❌              | ✅       | ✅       |              | ✅         | ❌       | ✅       |
| Guests      | ❌              | ❌       | ❌       | ❌           |            | ❌       | ✅       |
| VPN         | ❌              | ✅       | ❌       | ❌           | ❌         |          |          |

This provided clear documentation of which VLANs could access which resources, making it easy to understand and maintain the security model.

## Chapter 10: VPN Configuration - Secure Remote Access

### The Need for Remote Access

With the network infrastructure working and devices properly segmented, I realized I needed a way to access my homelab remotely. Whether I was traveling, working from a different location, or simply wanted to manage my infrastructure from anywhere, I needed secure remote access to my lab environment.

However, I didn't want to expose my entire network to the internet. The security matrix I had carefully designed needed to be maintained even for remote access. This meant I needed a VPN solution that would provide controlled access to specific VLANs only.

### Choosing Wireguard: Modern VPN Technology

After researching VPN options, I chose **Wireguard** for several reasons:

- **Modern cryptography**: Uses state-of-the-art cryptographic primitives
- **Lightweight**: Minimal attack surface with a small codebase
- **High performance**: Faster than traditional VPN protocols like OpenVPN
- **OpenWRT support**: Native support with excellent integration
- **Simple configuration**: Easy to manage and troubleshoot

### VPN Architecture: Lab Access Only

Following the principle of least privilege, I designed the VPN to provide access to the **Lab VLAN only**. This meant:

- **Remote developers** could access the Kubernetes cluster for development work
- **IoT devices** remained isolated and inaccessible from VPN
- **Personal devices** and **guest networks** stayed protected
- **Management access** was still possible through the VPN for administration

### The Implementation: Ansible-Driven VPN Configuration

The VPN configuration was integrated into my existing Ansible automation system, ensuring consistency and repeatability.

#### Network Interface Configuration

The VPN interface was defined in the network configuration template:

```yaml
# VPN Interface - Wireguard VPN server
config interface 'vpn'
    option proto 'wireguard'              # Wireguard protocol
    option private_key '{{ hostvars["router"].wireguard_keys.private }}'  # Router's private key
    option listen_port '51820'            # UDP port for VPN
    option addresses '{{ hostvars["router"].vlans.vpn.ip }}/24'  # Router IP (192.168.30.1/24)
```

This created a dedicated VPN interface on the router with IP `192.168.30.1/24`, separate from all other VLANs.

#### Peer Configuration Management

The Wireguard peer configuration was dynamically generated from the Ansible inventory:

```yaml
# Wireguard Peers - Client configurations
{% for host in groups['vpn'] %}
{% if hostvars[host].wireguard_keys.public is defined and host != 'router' %}
# Peer: {{ host }} ({{ hostvars[host].description }})
config wireguard_{{ host }}
    option public_key '{{ hostvars[host].wireguard_keys.public }}'    # Client's public key
    option allowed_ips '{{ hostvars[host].allowed_ips }}'  # Allowed IP ranges for this client
    option persistent_keepalive '25'                      # Keep-alive interval (seconds)
    option interface 'vpn'                               # Associate with VPN interface
{% endif %}
{% endfor %}
```

This approach allowed me to manage VPN clients through the Ansible inventory, making it easy to add or remove users.

#### Hotplug Integration

One of the challenges with Wireguard on OpenWRT is ensuring peer configurations are applied when the VPN interface comes up. I solved this with a custom hotplug script:

```bash
#!/bin/sh

# Wireguard Hotplug Script
# This script is triggered by network interface events
# It ensures Wireguard peers are configured when the VPN interface comes up

# Only process ifup events for the VPN interface
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "vpn" ] || exit 0

# Wait a moment for the interface to be fully ready
sleep 2

# Configure Wireguard peers from UCI configuration
{% for host in groups['vpn'] %}
{% if hostvars[host].wireguard_keys.public is defined and host != 'router' %}
# Configure peer: {{ host }}
wg set vpn peer {{ hostvars[host].wireguard_keys.public }} allowed-ips {{ hostvars[host].allowed_ips }} persistent-keepalive 25
{% endif %}
{% endfor %}

# Log the event
logger -t wireguard "VPN interface up, peers configured"
```

This script automatically configures all VPN peers whenever the VPN interface is brought up, ensuring reliable connectivity.

### Firewall Integration: Enforcing the Security Matrix

The VPN integration required careful firewall configuration to maintain the security matrix. The key rules were:

```yaml
# VPN VLAN access rules - VPN can only access Lab VLAN
# VPN to Lab forwarding (for remote development access)
config forwarding
    option src      vlan30              # Source: VPN VLAN
    option dest     vlan26              # Destination: Lab VLAN

# Management to VPN forwarding (for VPN management)
config forwarding
    option src      lan                 # Source: Management VLAN
    option dest     vlan30              # Destination: VPN VLAN
```

This ensured that:
- **VPN users** could only access the Lab VLAN
- **Management VLAN** could access VPN for administration
- **All other VLANs** remained isolated from VPN access

### Client Configuration: Workstation Integration

The VPN client configuration was managed through the Ansible inventory:

```yaml
# VPN
vpn:
  hosts:
    workstation:
      ansible_host: 192.168.30.10
      hostname: "workstation.vpn.home.example.net"
      description: "Workstation with VPN client"
      public_key: "{{ hostvars['workstation'].wireguard_keys.public }}"
      private_key: "{{ hostvars['workstation'].wireguard_keys.private }}"
      allowed_ips: "192.168.30.10/32"
```

This allowed me to assign static IP addresses to VPN clients and manage their access through the same automation system.

### Service Management: Reliable VPN Operation

The VPN service management was integrated into the Ansible handlers:

```yaml
- name: restart wireguard
  command: ifdown vpn && ifup vpn
  retries: 3
  delay: 5
```

This ensured that VPN configuration changes were properly applied and the service was restarted reliably.

### Testing and Validation

After implementing the VPN, I conducted comprehensive testing:

1. **Connectivity Testing**: Verified VPN clients could connect and receive proper IP addresses
2. **Access Control Testing**: Confirmed VPN users could only access the Lab VLAN
3. **Isolation Testing**: Verified that IoT, Devices, and Guest VLANs remained inaccessible
4. **Performance Testing**: Measured VPN throughput and latency
5. **Failover Testing**: Tested VPN reconnection after network interruptions

### The Result: Secure Remote Development

The VPN implementation provided exactly what I needed:

- **Secure remote access** to the Kubernetes cluster for development work
- **Maintained network isolation** with the security matrix intact
- **Automated management** through Ansible for easy client addition/removal
- **Reliable operation** with proper service management and monitoring
- **Modern security** with Wireguard's state-of-the-art cryptography

This completed the network infrastructure, providing both local segmentation and secure remote access while maintaining the security principles I had established.

## Chapter 11: The Automation Maturity

### Comprehensive Template Documentation

Throughout this journey, I learned the importance of documentation. I added comprehensive comments to all router configuration templates:

```yaml
# Network configuration for OpenWRT router
# This file defines all network interfaces including VLANs

# Loopback interface - standard localhost interface
config interface 'loopback'
    option device 'lo'                    # Loopback device
    option proto 'static'                 # Static IP configuration
    option ipaddr '127.0.0.1'            # Standard loopback IP
    option netmask '255.0.0.0'           # Loopback subnet mask
```

This documentation proved invaluable for troubleshooting and future maintenance.

### The Complete Automation System

By the end of this journey, I had built a comprehensive automation system that included:

- **Network Configuration**: Automated VLAN setup with proper bridging
- **DHCP Management**: Static and dynamic IP assignment with proper MAC address handling
- **WiFi Configuration**: Dual-band support with proper security
- **Firewall Management**: Controlled access between VLANs
- **Service Management**: Automatic restart of services after configuration changes
- **Testing and Validation**: Comprehensive health checks and connectivity testing
- **Backup and Restore**: Automated configuration backup with timestamped archives

---

*This is part of the "Building a Kubernetes Homelab" series. In the next post, we'll deploy the Kubernetes cluster on the Lab VLAN and begin migrating services to our new network infrastructure.*
