---
title: "Speed up CI/CD with Dagger Engine and Docker Registry Mirror"
date: 2025-08-06T15:30:00+02:00
draft: false
description: "Learn how to deploy Dagger Engine with a Docker registry mirror to speed up CI/CD pipelines and avoid Docker Hub rate limits"
tags: ["dagger", "kubernetes", "ci-cd", "docker", "devops", "registry"]
categories: ["devops"]
---

This blog post covers how to deploy Dagger Engine with a Docker registry mirror on Kubernetes to speed up CI/CD pipelines and avoid Docker Hub rate limiting issues. I'll explore the problem, the solution architecture, and provide complete Kubernetes manifests for production use.

## What is Dagger?

Dagger is a modern CI/CD engine that allows you to write your pipelines as code. It provides a powerful API for building, testing, and deploying applications. Dagger Engine runs as a service that can be shared across multiple CI/CD pipelines, providing caching and performance benefits.

## The Problem: Docker Hub Rate Limiting

When running CI/CD pipelines with Dagger, each build typically pulls multiple Docker images from Docker Hub:

- Base images: `golang:1.21`, `node:18`, `python:3.11`
- Build tools: `alpine:latest`, `ubuntu:20.04`
- Custom images: Your application images

**The Challenge:**

- Docker Hub has rate limits (200 pulls per 6 hours for anonymous users)
- Each CI/CD run pulls the same images repeatedly
- Build times increase as images are downloaded each time
- Rate limiting causes pipeline failures

## The Solution: Docker Registry Mirror

Instead of pulling images directly from Docker Hub, we'll deploy a local Docker registry that acts as a mirror/cache:

### Architecture

```text
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   CI/CD Pipeline│    │  Dagger Engine   │    │ Docker Registry │
│                 │    │                  │    │     Mirror      │
│  - GitHub Actions│───▶│  - BuildKit     │───▶│  - Local Cache  │
│  - Self-hosted  │    │  - Container    │    │  - 50GB Storage │
│    runners      │    │    Engine       │    │  - Proxy to     │
└─────────────────┘    └──────────────────┘    │    Docker Hub   │
                                               └─────────────────┘
                                                         │
                                                         ▼
                                               ┌─────────────────┐
                                               │   Docker Hub    │
                                               │   (External)    │
                                               └─────────────────┘
```

### Benefits

1. **Automatic Caching**: First pull caches the image locally
2. **Subsequent Pulls**: Served from local cache, no Docker Hub calls
3. **Persistent Storage**: Images survive pod restarts
4. **Transparent**: No changes needed in CI/CD pipelines
5. **Rate Limit Protection**: Local cache prevents hitting Docker Hub limits

## Implementation

### Prerequisites

1. **Kubernetes cluster** with containerd runtime
2. **Persistent storage** available (50GB recommended)
3. **Privileged containers** enabled
4. **Network policies** allowing internal communication

### 1. Persistent Volume for Registry

First, create a persistent volume for the Docker registry cache:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: k8s-worker-docker-registry
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/lib/k8s/docker
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - k8s-worker
```

### 2. Docker Registry Deployment

Deploy the Docker registry with proxy configuration:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: docker-registry
  namespace: docker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: docker-registry
  template:
    metadata:
      labels:
        app: docker-registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_PROXY_REMOTEURL
          value: "https://registry-1.docker.io"
        volumeMounts:
        - name: registry-storage
          mountPath: /var/lib/registry
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "1Gi"
            cpu: "500m"
      volumes:
      - name: registry-storage
        persistentVolumeClaim:
          claimName: docker-registry
```

### 3. Dagger Engine Configuration

Configure Dagger Engine to use the local registry through BuildKit:

**Note**: Dagger Engine uses BuildKit directly for image operations, not the system containerd. Therefore, we configure BuildKit registry mirrors rather than containerd configuration.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dagger-buildkit-config
  namespace: dagger
data:
  buildkitd.toml: |
    debug = true
    
    [registry."docker.io"]
      mirrors = ["http://registry.docker.svc.cluster.local:5000"]
    
    [registry."ghcr.io"]
      mirrors = ["http://registry.docker.svc.cluster.local:5000"]
```

Mount this configuration in the Dagger Engine:

```yaml
volumeMounts:
- name: buildkit-config
  mountPath: /etc/buildkit
volumes:
- name: buildkit-config
  configMap:
    name: dagger-buildkit-config
```

### 4. Complete Deployment

Deploy all components:

```bash
# Deploy Docker registry
kubectl apply -f deployments/docker-registry/

# Deploy Dagger Engine
kubectl apply -f deployments/dagger-engine/

# Verify deployment
kubectl get pods -n docker
kubectl get pods -n dagger
```

## Performance Benefits

### Before (Direct Docker Hub)

- **First build**: Slow (download images from Docker Hub)
- **Subsequent builds**: Slow (re-download same images)
- **Rate limiting**: Pipeline failures after 200 pulls
- **Network usage**: High bandwidth consumption

### After (Registry Mirror)

- **First build**: Same speed (download and cache images)
- **Subsequent builds**: Much faster (serve from local cache)
- **Rate limiting**: Eliminated (local cache)
- **Network usage**: Minimal (only first-time downloads)

## GitHub Actions Integration

### Before: Traditional Dagger Usage

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: self-hosted
    steps:
    - uses: actions/checkout@v4
    
    - name: Run Dagger
      run: |
        dagger call lint --source-dir .
        dagger call test --source-dir .
```

This approach:

- Pulls images for each step
- No caching between builds
- Hits Docker Hub rate limits
- Slower build times

### After: Using Self-Hosted Dagger Engine

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: k8s-home-runners
    steps:
    - uses: actions/checkout@v4
    
    - name: Run Dagger with Engine
      env:
        _EXPERIMENTAL_DAGGER_RUNNER_HOST: "tcp://dagger-engine.dagger.svc.cluster.local:8080"
      run: |
        dagger call lint --source-dir .
        dagger call test --source-dir .
```

This approach:

- Reuses cached images
- Faster build times
- No Docker Hub rate limit issues
- Consistent performance

## Monitoring and Maintenance

### Check Registry Cache

```bash
# Check registry storage usage
kubectl exec -n docker deployment/docker-registry -- du -sh /var/lib/registry

# List cached images
kubectl exec -n docker deployment/docker-registry -- find /var/lib/registry -type d | grep -v "^/var/lib/registry$" || echo "No cached images yet"
```

### Registry Health

```bash
# Check registry status
kubectl get pods -n docker
kubectl logs -n docker deployment/docker-registry

# Test registry connectivity
kubectl exec -n dagger deployment/dagger-engine -- wget -qO- http://registry.docker.svc.cluster.local:5000/v2/
```

### Dagger Engine Status

```bash
# Check engine status
kubectl get pods -n dagger
kubectl logs -n dagger deployment/dagger-engine

# Check BuildKit configuration
kubectl exec -n dagger deployment/dagger-engine -- cat /etc/buildkit/buildkitd.toml
```

## Security Considerations

1. **Internal Only**: Registry is accessible only within the cluster
2. **No Authentication**: Simple setup for local use
3. **Network Policies**: Can be added for additional security
4. **Storage**: 50GB persistent storage for image cache

## Conclusion

This solution provides a robust way to speed up CI/CD pipelines while avoiding Docker Hub rate limits. The Docker registry mirror acts as an intelligent cache layer, automatically storing frequently used images and serving them locally.

**Key Benefits:**

- Eliminates Docker Hub rate limiting
- Speeds up builds significantly
- No changes required in CI/CD pipelines
- Persistent cache survives pod restarts
- Transparent to users

The combination of Dagger Engine for build orchestration and Docker registry mirror for image caching creates a powerful, self-contained CI/CD infrastructure that's both fast and reliable.
