# BÁO CÁO TRIỂN KHAI CI/CD — YAS (Yet Another Shop)

> **Ngày cập nhật:** 2026-04-14
> **Mục tiêu:** Xây dựng hệ thống CI/CD cho YAS — e-commerce microservices (Java Spring Boot + Next.js)
> **Công nghệ:** Jenkins, ArgoCD (GitOps), Istio Service Mesh, Docker, Kubernetes, Helm

---

## MỤC LỤC

1. [Tổng quan kiến trúc](#1-tổng-quan-kiến-trúc)
2. [Repository structure — Cấu trúc thư mục mới](#2-repository-structure--cấu-trúc-thư-mục-mới)
3. [ArgoCD — GitOps](#3-argocd--gitops)source bin/activate
   - 3.1. Namespaces (`k8s/argocd/namespaces.yaml`)
   - 3.2. Root Application (`k8s/argocd/root-app.yaml`)
   - 3.3. Dev Child App (`k8s/argocd/apps/dev/all-services.yaml`)
   - 3.4. Staging Child App (`k8s/argocd/apps/staging/all-services.yaml`)
   - 3.5. Kustomization files
4. [Istio Service Mesh](#4-istio-service-mesh)
   - 4.1. Strict mTLS (`k8s/istio/base/global-mtls.yaml`)
   - 4.2. Namespace Label (`k8s/istio/base/namespace-label.yaml`)
   - 4.3. Retry Policy (`k8s/istio/policies/cart-retry-vs.yaml`)
   - 4.4. Authorization Policy (`k8s/istio/policies/cart-authz.yaml`)
5. [Jenkins Pipelines](#5-jenkins-pipelines)
   - 5.1. `dev_cd` — Auto-deploy dev khi main thay đổi
   - 5.2. `staging_cd` — Deploy staging khi có Git tag
   - 5.3. `developer_build` — Developer tự test code riêng
   - 5.4. `developer_delete` — Xóa namespace developer
6. [Luồng CI/CD hoàn chỉnh](#6-luồng-cicd-hoàn-chỉnh)
7. [Hướng dẫn cài đặt](#7-hướng-dẫn-cài-đặt)
8. [Các thay đổi cần thực hiện thủ công](#8-các-thay-đổi-cần-thực-hiện-thủ-công)

---

## 1. TỔNG QUAN KIẾN TRÚC

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GITHUB REPOSITORY                                 │
│                     https://github.com/Introduction-To-DevOps-Group-10/yas-pj2│
│                                                                             │
│  Developer push code                                                         │
│       │                                                                      │
│       ├─── Feature branch (VD: dev_tax_service)                            │
│       │        │                                                            │
│       │        └── developer_build Jenkins job                               │
│       │                  │                                                  │
│       │                  ├── Build image: <branch>-<sha>                    │
│       │                  ├── Deploy → namespace: developer (NodePort)         │
│       │                  └── Dev test → xóa khi xong                         │
│       │                                                                     │
│       └─── Main branch ───────────────────────────────────────────────┐    │
│            │                                                           │    │
│            ├── Jenkins CI (Jenkinsfile gốc)                             │    │
│            │     ├── mvn test + SonarQube + Snyk                      │    │
│            │     ├── Docker build → Push Docker Hub (tag: latest)       │    │
│            │     └── git commit values.yaml → push main                 │    │
│            │                                                           │    │
│            ▼                                                           ▼    │
│  ┌─────────────────────┐          ┌──────────────────────────────────┐    │
│  │  ArgoCD Root App    │          │  Git Tag v*.*.*                  │    │
│  │  (k8s/argocd/apps/) │          │  (git tag v1.2.3 → push origin)  │    │
│  └──────────┬──────────┘          └──────────────┬───────────────────┘    │
│             │                                      │                         │
│      ┌──────┴──────────────────┐          ┌───────┴──────────────┐         │
│      │ yas-dev-all-services    │          │ yas-staging-all-svc  │         │
│      │ targetRevision: main    │          │ targetRevision: v*.*.*│         │
│      │ auto-sync: ✅           │          │ sync on tag: ✅       │         │
│      │ namespace: dev          │          │ namespace: staging     │         │
│      │ image.tag: latest       │          │ image.tag: v1.2.3     │         │
│      └──────────┬──────────────┘          └───────────┬──────────┘         │
│                 │                                    │                      │
│                 ▼                                    ▼                      │
│  ┌──────────────────────────────────────────────────────────────┐          │
│  │              KUBERNETES CLUSTER                               │          │
│  │                                                               │          │
│  │  Namespace: dev          Namespace: staging    Namespace: dev │          │
│  │  ├── cart pod           ├── cart pod          ├── cart pod  │          │
│  │  ├── storefront-bff    ├── storefront-bff    ├── storefront │          │
│  │  ├── ... (all 22)      ├── ... (all 22)      ├── ...        │          │
│  │                                                               │          │
│  │  ✅ ArgoCD auto-sync   ✅ ArgoCD on tag        ✅ Manual build │          │
│  │  ✅ NodePort exposed   ✅ ClusterIP             ✅ NodePort     │          │
│  │                                                               │          │
│  │  ISTIO SERVICE MESH (tất cả 3 namespace)                     │          │
│  │  ├── PeerAuthentication: STRICT mTLS                          │          │
│  │  ├── DestinationRule: ISTIO_MUTUAL                           │          │
│  │  ├── VirtualService: cart retry 3x on 5xx                   │          │
│  │  └── AuthorizationPolicy: cart ← chỉ storefront-bff được gọi │          │
│  └───────────────────────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. REPOSITORY STRUCTURE — CẤU TRÚC THƯ MỤC MỚI

```
yas-pj2/
│
├── k8s/                                  ← Helm charts gốc của YAS (đã có sẵn)
│   ├── charts/                           ← 22 microservices
│   │   ├── backend/                      ← Helm chart base cho Java services
│   │   ├── ui/                          ← Helm chart base cho Next.js services
│   │   ├── cart/values.yaml              ← image: ghcr.io/nashtech-garage/yas-cart: latest
│   │   ├── storefront-bff/values.yaml    ← image: ghcr.io/nashtech-garage/yas-storefront-bff: latest
│   │   └── ... (tất cả 22 services)
│   │
│   ├── argocd/                          ← [MỚI] ArgoCD GitOps manifests
│   │   ├── namespaces.yaml                ← dev + staging + developer namespaces
│   │   ├── root-app.yaml                 ← Root Application (app-of-apps)
│   │   └── apps/
│   │       ├── kustomization.yaml
│   │       ├── dev/
│   │       │   ├── all-services.yaml      ← Dev child application
│   │       │   └── kustomization.yaml
│   │       └── staging/
│   │           ├── all-services.yaml      ← Staging child application
│   │           └── kustomization.yaml
│   │
│   └── istio/                           ← [MỚI] Istio Service Mesh
│       ├── base/
│       │   ├── global-mtls.yaml           ← STRICT mTLS policy
│       │   └── namespace-label.yaml       ← Istio injection label
│       └── policies/
│           ├── cart-retry-vs.yaml         ← Retry 3x on HTTP 5xx
│           └── cart-authz.yaml            ← Authorization: storefront-bff → cart
│
└── jenkins/                             ← [MỚI] Jenkins pipeline files
    ├── dev-cd-jenkinsfile                ← Dev CD: main → dev (auto)
    ├── staging-cd-jenkinsfile            ← Staging CD: tag v*.*.* → staging
    ├── developer-build-jenkinsfile        ← Developer test code riêng
    └── developer-delete-jenkinsfile      ← Xóa developer namespace
```

---

## 3. ARGOCD — GITOPS

### 3.1. `k8s/argocd/namespaces.yaml`

```yaml
# ============================================================
# ArgoCD Namespaces
# Tạo 3 namespace cho 3 môi trường triển khai.
# ============================================================
---
apiVersion: v1
kind: Namespace
metadata:
  name: dev          # Môi trường dev — auto-sync từ main branch
  labels:
    # istio-injection: enabled
    # Khi label này được apply, Istio sẽ tự động inject
    # Envoy sidecar proxy vào TẤT CẢ pod được tạo trong namespace này.
    # Mọi pod mới đều có sidecar mTLS ngay lập tức.
    istio-injection: enabled
---
apiVersion: v1
kind: Namespace
metadata:
  name: staging      # Môi trường staging — sync khi có Git tag v*.*.*
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: Namespace
metadata:
  name: developer    # Namespace tạm thời — developer tự tạo để test code
  labels:
    istio-injection: enabled
```

**Giải thích chi tiết:**

| Trường | Ý nghĩa |
|---|---|
| `apiVersion: v1` / `kind: Namespace` | Kubernetes resource chuẩn — tạo đơn vị network isolation |
| `istio-injection: enabled` | Label báo cho Istio mutating webhook: mỗi pod mới tạo trong namespace này đều được inject thêm container `istio-proxy`. Không cần sửa Dockerfile hay Kubernetes manifests. |
| 3 namespace riêng biệt | Đảm bảo isolation tuyệt đối giữa dev / staging / developer |

---

### 3.2. `k8s/argocd/root-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: yas-root
  namespace: argocd        # ArgoCD quản lý app này trong namespace argocd
  finalizers:
    # Khi xóa root app, Kubernetes sẽ tự động xóa tất cả
    # child resources (không orphaned resources)
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default         # ArgoCD project — giới hạn quyền deploy

  # Git repo nơi ArgoCD tìm manifests
  source:
    repoURL:        https://github.com/Introduction-To-DevOps-Group-10/yas-pj2.git
    targetRevision: main    # Theo dõi branch main
    path:           k8s/argocd/apps  # Chỉ theo dõi thư mục apps/

  # ArgoCD app sống trong argocd namespace nhưng quản lý resources
  # trong chính argocd namespace (self-referential root app pattern)
  destination:
    server:    https://kubernetes.default.svc  # API server nội bộ của cluster
    namespace: argocd

  syncPolicy:
    automated:
      prune:    true    # Xóa resources đã xóa khỏi Git (garbage collection)
      selfHeal: true    # Tự động reconcile khi cluster drift khỏi Git
    retry:
      limit: 5          # Retry tối đa 5 lần nếu sync thất bại
      backoff:
        duration: 5s    # Bắt đầu retry sau 5 giây
        factor: 2       # Mỗi lần retry tiếp theo, thời gian chờ x2
        maxDuration: 3m  # Tối đa 3 phút giữa các lần retry
```

**App-of-Apps Pattern là gì?**
Thay vì tạo 2 ArgoCD Application (dev + staging) thủ công bằng `kubectl apply`, ta tạo **một** Application gốc (`yas-root`) trỏ vào thư mục `k8s/argocd/apps/`. ArgoCD tự động đọc manifests trong thư mục đó và tạo các child Applications. Khi thêm môi trường mới, chỉ cần thêm file YAML vào thư mục — ArgoCD tự nhận diện.

---

### 3.3. `k8s/argocd/apps/dev/all-services.yaml`

```yaml
# Dev Child App — auto-sync mỗi khi branch main thay đổi
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: yas-dev-all-services
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    environment: dev
    app.kubernetes.io/part-of: yas    # Label để group các apps
spec:
  project: default

  source:
    repoURL:        https://github.com/.../yas-pj2.git
    targetRevision: main             # ← KEY: theo dõi branch main
    path:           k8s/charts       # ← Helm charts gốc của 22 services

    helm:
      valueFiles:
        - values.yaml                # Load values.yaml mặc định của mỗi chart
      parameters:
        # image.tag = latest vì CI job gốc push tag 'latest' lên Docker Hub
        - name: backend.image.tag
          value: latest
        - name: image.tag
          value: latest
        # CI job sẽ sed trực tiếp trong values.yaml để đổi repo
        # ghcr.io → docker.io/nashtechgarage

  destination:
    server:    https://kubernetes.default.svc
    namespace: dev                   # ← Deploy vào namespace dev

  syncPolicy:
    automated:
      prune:    true                # Xóa service nếu bị xóa khỏi Git
      selfHeal: true                # Tự heal drift (đảm bảo cluster = Git)
      allowEmpty: true              # Không lỗi khi không có thay đổi gì
    retry:
      limit: 5
    ignoreDifferences:
      # HPA tự động thay đổi replicas → ArgoCD không diff trường này
      - group: apps
        kind: Deployment
        jsonPointers:
          - /spec/replicas
```

**Cơ chế auto-sync hoạt động như thế nào?**

```
1. Developer push code lên main branch
2. GitHub webhook → Jenkins CI job chạy
3. CI build + docker push lên Docker Hub
4. CI sed cập nhật k8s/charts/<service>/values.yaml (image tag)
5. CI git commit + git push values.yaml lên main
6. ArgoCD poll SCM → phát hiện commit mới trên main
7. ArgoCD re-render Helm charts với image tag mới
8. ArgoCD sync vào namespace dev → pod rolling-update
→ Toàn bộ quy trình không cần thao tác thủ công.
```

---

### 3.4. `k8s/argocd/apps/staging/all-services.yaml`

```yaml
# Staging Child App — CHỈ sync khi có Git Release Tag dạng v*.*.*
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: yas-staging-all-services
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    environment: staging
    app.kubernetes.io/part-of: yas
spec:
  project: default

  source:
    repoURL:        https://github.com/.../yas-pj2.git
    targetRevision: "v*.*.*"      # ← KEY: ArgoCD regex match git tags
    path:           k8s/charts

    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: backend.image.tag
          value: latest            # ← Giá trị này bị override bởi staging_cd job
        - name: image.tag
          value: latest

  destination:
    server:    https://kubernetes.default.svc
    namespace: staging

  # KHÔNG auto-prune / self-heal trên staging — cần kiểm soát thủ công
  syncPolicy:
    automated:
      prune:    false             # Không tự xóa — staging không được mất dữ liệu
      selfHeal: false             # Không tự heal — cần human review trước
      allowEmpty: true
    retry:
      limit: 3                    # Retry ít hơn dev
```

**Tại sao `targetRevision: "v*.*.*"`?**

ArgoCD dùng glob pattern để match Git references. `"v*.*.*"` match tất cả:
- `v1.0.0`, `v2.3.4` (final release)
- `v1.2.3-rc1`, `v1.2.3-beta` (pre-release)
- `v10.0.0-hotfix`

Nhưng KHÔNG match:
- `main`, `develop`, `feature-branch` (branch names)
- `abc1234` (commit SHA)

→ Staging chỉ deploy khi có **release tag được tạo có chủ đích** — đảm bảo tính ổn định.

---

### 3.5. Kustomization Files

```yaml
# k8s/argocd/apps/kustomization.yaml
# k8s/argocd/apps/dev/kustomization.yaml
# k8s/argocd/apps/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - dev/all-services.yaml    # Hoặc staging/all-services.yaml
```

**Kustomize là gì?** Kustomize (tích hợp sẵn trong `kubectl apply -k`) cho phép compose các Kubernetes manifests từ nhiều file YAML. ArgoCD root app sử dụng Kustomize để load tất cả child Applications từ thư mục `apps/`. Mỗi subdirectory (dev, staging) có Kustomization riêng để dễ quản lý.

---

## 4. ISTIO SERVICE MESH

### 4.1. `k8s/istio/base/global-mtls.yaml`

```yaml
# ─── Phần 1: PeerAuthentication ─────────────────────────────
# PeerAuthentication: cấu hình mTLS ở mức "pod nhận request"
# Istiod (Istio Control Plane) dùng SDS (Secret Discovery Service)
# để inject x509 certificate vào mỗi sidecar proxy.
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: yas-strict-mtls
  namespace: istio-system      # Istio control plane namespace
spec:
  mtlsMode: STRICT             # ← Tất cả traffic phải là mTLS
                              # DISABLE = cho phép plain-text (không dùng)
                              # PERMISSIVE = cho phép cả 2 (dev only)
                              # STRICT = CHỈ cho phép mTLS (production)
  targetNamespaces:
    - dev                      # Áp dụng cho dev namespace
    - staging                  # Áp dụng cho staging namespace
    - developer                # Áp dụng cho developer namespace

---
# ─── Phần 2: DestinationRule ──────────────────────────────
# DestinationRule: cấu hình mTLS ở mức "pod gửi request"
# Envoy proxy phía gửi dựa vào rule này để quyết định
# dùng mTLS hay không khi gọi một service.
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: yas-mtls-destination-rule
  namespace: istio-system
spec:
  # Áp dụng cho TẤT CẢ service trong cluster (wildcard)
  host: "*.svc.cluster.local"
  trafficPolicy:
    tls:
      # ISTIO_MUTUAL: Istio tự động lấy certificate từ SDS
      # Không cần generate, import hay rotate thủ công.
      # Istiod rotate certificate mỗi 24 giờ (configurable).
      mode: ISTIO_MUTUAL
```

**mTLS hoạt động như thế nào?**

```
Pod A (storefront-bff)                          Pod B (cart)
┌─────────────────────┐                    ┌─────────────────────┐
│ Container           │                    │ Container           │
│  app.jar            │                    │  app.jar            │
├─────────────────────┤                    ├─────────────────────┤
│ Envoy Sidecar       │←── mTLS (x509) ──→│ Envoy Sidecar       │
│ (istio-proxy)       │   encrypted traffic │ (istio-proxy)       │
│                     │                    │                     │
│ SDS Client ────────→│Istiod CA           │←────── SDS Client  │
│ (lấy cert tự động) │ (cấp phát cert)   │ (lấy cert tự động) │
└─────────────────────┘                    └─────────────────────┘

Quy trình:
1. Pod A gửi request HTTP bình thường đến cart:80
2. Envoy sidecar A intercepts request
3. Envoy A kiểm tra DestinationRule → biết phải dùng mTLS
4. Envoy A lấy certificate từ SDS (cấp bởi Istiod)
5. Request được mã hóa bằng TLS và gửi đến Pod B
6. Envoy sidecar B nhận request, verify certificate
7. B解密 và forward HTTP request đến cart container
```

**Tại sao cần cả PeerAuthentication VÀ DestinationRule?**

- `PeerAuthentication` → cấu hình phía **nhận** (receiver sidecar)
- `DestinationRule` → cấu hình phía **gửi** (sender sidecar)

Cả hai cùng cần thiết vì Istio Envoy hoạt động theo mô hình **sidecar proxy**. Envoy lắng nghe và intercept tất cả inbound + outbound traffic. Nếu chỉ có PA mà không có DR, outbound calls vẫn không dùng mTLS.

---

### 4.2. `k8s/istio/base/namespace-label.yaml`

```yaml
# File tài liệu + kiểm tra trạng thái Istio injection
# KHÔNG dùng để apply trực tiếp (namespace đã được label
# trong k8s/argocd/namespaces.yaml)

# Lệnh để bật Istio sidecar injection thủ công:
# kubectl label namespace dev istio-injection=enabled --overwrite
# kubectl label namespace staging istio-injection=enabled --overwrite
# kubectl label namespace developer istio-injection=enabled --overwrite

# Để kiểm tra trạng thái:
# kubectl get namespace -L istio-injection
# NAME          STATUS   AGE   INJECTION
# argocd        Active   30d   disabled
# dev           Active   10d   enabled      ← ✅
# staging       Active   10d   enabled      ← ✅
# developer     Active   5d    enabled      ← ✅
```

---

### 4.3. `k8s/istio/policies/cart-retry-vs.yaml`

```yaml
# VirtualService cho cart service — cấu hình retry policy
# VirtualService gắn với destination service (cart),
# nên TẤT CẢ các caller gọi cart đều thừa hưởng retry policy
# mà không cần sửa code ở caller side.
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: cart-retry-virtualservice
  namespace: dev          # Tạo bản sao cho staging & developer
spec:
  # hosts: phải khớp với Kubernetes Service FQDN của cart
  # short name "cart" hoạt động trong cùng namespace
  # FQDN cần cho cross-namespace calls
  hosts:
    - cart
    - cart.dev.svc.cluster.local

  http:
    # ─── Rule 1: Retry cho API paths ─────────────────────────
    - match:
        - headers:
            :path:              # Istio dùng ":" prefix cho HTTP header keys
              prefix: /api/cart  # Áp dụng cho tất cả /api/cart/*
      route:
        - destination:
            host: cart          # Forward đến cart service
            port:
              number: 80        # Named port 'http' từ k8s Service

      # Retry policy — được áp dụng bởi Envoy proxy ở CALLER side
      retries:
        attempts: 3              # Tổng cộng 3 lần retry sau lần đầu thất bại
                                 # → 1 original + 3 retries = 4 attempts total
        perTryTimeout: 3s        # Mỗi retry có timeout 3 giây riêng
                                 # Nếu retry không response trong 3s → timeout
        retryOn: |              # Loại lỗi nào thì retry
          5xx,                  # 500, 501, 502, 503, 504 — server error
          reset,                # Connection reset (peer đóng connection)
          gateway-error,        # 502/503/504 — upstream gateway error
          connect-failure       # Không kết nối được upstream

    # ─── Rule 2: Health check — KHÔNG retry ────────────────
    # Retry health check là anti-pattern:
    # - Health check fail → rolling restart pod đúng → phải fail ngay
    # - Retry health check → che giấu real downtime
    - match:
        - headers:
            :path:
              exact: /actuator/health/readiness
      route:
        - destination:
            host: cart
            port:
              number: 80
      retries: {}               # Empty object = no retry
```

**Retries hoạt động ở đâu trong request flow?**

```
Caller (storefront-bff) Envoy Sidecar
        │
        │ 1. app gửi HTTP GET /api/cart/items
        ▼
┌───────────────────────┐
│ Envoy Sidecar         │ ─── Envoy kiểm tra VirtualService ───
│ (caller's side)       │ ─── phát hiện /api/cart/* ────────────
│                       │ ─── thấy retries: 3 ────────────────────
│                       │
│ ─── Request 1 ──→ cart (thất bại: 503) ─── timeout 3s ────│
│ ─── Request 2 ──→ cart (thất bại: 503) ─── timeout 3s ────│
│ ─── Request 3 ──→ cart (thành công: 200) ─── RETURN ──────│
│                                                   │
└───────────────────────────────────────────────────┘
        │
        ▼
  App nhận response 200 — không biết gì về retry
```

---

### 4.4. `k8s/istio/policies/cart-authz.yaml`

```yaml
# AuthorizationPolicy — Principle of Least Privilege
# DENY-by-default, ALLOW-by-exception
# Tách thành 2 policy: 1 DENY all + 1 ALLOW storefront-bff
---
# Bước 1: DENY ALL — từ chối mọi request vào cart
# Istio evaluate DENY rules TRƯỚC ALLOW rules — always.
# Nếu không có rule nào match ALLOW → request bị DENY.
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: cart-deny-all
  namespace: dev
spec:
  action: DENY
  # selector: chỉ apply cho pods có label app=cart
  # Không có selector → apply cho TẤT CẢ pods trong namespace
  selector:
    matchLabels:
      app: cart
  # Empty rules = match ALL requests → deny ALL
  rules:
    - {}

---
# Bước 2: ALLOW — chỉ storefront-bff được phép gọi cart
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: cart-allow-storefront-bff
  namespace: dev
spec:
  action: ALLOW
  selector:
    matchLabels:
      app: cart
  rules:
    - from:
        - source:
            # SPIFFE ID của storefront-bff pod
            # Format: spiffe://<trust-domain>/ns/<ns>/sa/<service-account>
            # trust-domain mặc định Kubernetes = cluster.local
            # ServiceAccount của storefront-bff được tạo bởi backend Helm chart
            # Xác minh: kubectl get pod -n dev -l app=storefront-bff \
            #                     -o jsonpath='{.spec.serviceAccountName}'
            principals:
              - "cluster.local/ns/dev/sa/storefront-bff"
      to:
        - operation:
            # Chỉ cho phép cart API paths
            paths:
              - /api/cart/*
              - /ws/cart            # WebSocket nếu cart có real-time feature
            # Giới hạn HTTP methods — không cần TRACE, OPTIONS,...
            methods:
              - GET
              - POST
              - PUT
              - DELETE
              - PATCH
```

**Tại sao tách thành 2 AuthorizationPolicy?**

Istio không có syntax "DENY-except-for-X" trong một policy duy nhất. Mô hình chuẩn:
1. `DENY` policy với `rules: [{}]` → match all → deny all
2. `ALLOW` policy với specific principals → selectively opens

**Thứ tự evaluate của Istio:**
```
1. DENY rules evaluated FIRST → if match → REJECT immediately
2. ALLOW rules evaluated SECOND → if match → PERMIT
3. No ALLOW match → IMPLICIT DENY
```

---

## 5. JENKINS PIPELINES

### 5.1. `jenkins/dev-cd-jenkinsfile` — Dev CD Pipeline (GitOps Pull Model)

```groovy
// ================================================================
// dev_cd Jenkinsfile
// GitOps PULL MODEL — CHỈ commit Git, KHÔNG helm/kubectl
//
// Trigger: Khi main branch thay đổi (CI job push values.yaml)
//
// Luồng hoàn chỉnh:
//   1. CI job push values.yaml (ko [skip ci])
//      → ArgoCD thấy commit mới → sync dev ✅
//   2. Dev_cd thấy main thay đổi → trigger
//   3. Dev_cd build & push ALL images (tag: <commit_sha>)
//   4. Dev_cd commit values.yaml (CÓ [skip ci])
//      → ArgoCD thấy commit → sync dev ✅
//      → Dev_cd KHÔNG tự trigger lại (vì [skip ci])
//
// Mô hình: ArgoCD là "Single Source of Truth" cho cluster.
// ================================================================
pipeline {
    agent any

    environment {
        DOCKER_HUB_USER = 'nashtechgarage'
        GIT_REPO        = 'https://github.com/.../yas-pj2.git'
        GIT_BRANCH      = 'main'
        GIT_CREDENTIALS = 'github-read-write'
    }

    stages {

        // ─── Stage 1: Checkout main branch ─────────────────────────────
        stage('Checkout main branch') {
            steps {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: "*/${GIT_BRANCH}"]],
                    extensions: [
                        [$class: 'WipeWorkspace'],
                        [$class: 'CloneOption', depth: 1]
                    ],
                    userRemoteConfigs: [[
                        url: "${GIT_REPO}",
                        credentialsId: "${GIT_CREDENTIALS}"
                    ]]
                ])
            }
        }

        // ─── Stage 2: Build & Push Docker Images (Commit ID Tag) ─────
        // Mỗi commit → image tag = 7 ký tự đầu của commit SHA
        // VD: commit abc1234 → tag: abc1234
        // Đảm bảo image uniquely traceable về đúng commit
        stage('Build & Push Docker Images') {
            script {
                env.COMMIT_SHORT_SHA = sh(
                    script: 'git rev-parse --short HEAD',
                    returnStdout: true
                ).trim()
                echo "📦 Commit SHA (7 chars): ${env.COMMIT_SHORT_SHA}"

                def javaServices = [
                    'cart','customer','inventory','location','media',
                    'order','payment','payment-paypal','product',
                    'promotion','rating','recommendation','sampledata',
                    'search','tax','webhook',
                    'storefront-bff','backoffice-bff'
                ]
                def nodeServices = ['storefront', 'backoffice']

                (javaServices + nodeServices).each { svc ->
                    def imageRepo = "yas-${svc}"
                    sh """
                        docker build -t ${DOCKER_HUB_USER}/${imageRepo}:${env.COMMIT_SHORT_SHA} ${svc}/
                        docker push ${DOCKER_HUB_USER}/${imageRepo}:${env.COMMIT_SHORT_SHA}

                        # Vẫn push thêm bản tag latest để dự phòng
                        docker tag ${DOCKER_HUB_USER}/${imageRepo}:${env.COMMIT_SHORT_SHA} \
                                  ${DOCKER_HUB_USER}/${imageRepo}:latest
                        docker push ${DOCKER_HUB_USER}/${imageRepo}:latest
                    """
                }
            }
        }

        // ─── Stage 3: Patch Helm values.yaml ─────────────────────────
        // Đổi: ghcr.io → docker.io/nashtechgarage
        // Đổi: tag: bất kỳ → <commit_sha>
        stage('Patch Helm values.yaml') {
            script {
                def allServices = [
                    'cart','customer','inventory','location','media',
                    'order','payment','payment-paypal','product',
                    'promotion','rating','recommendation','sampledata',
                    'search','tax','webhook',
                    'storefront-ui','storefront-bff',
                    'backoffice-ui','backoffice-bff',
                ]
                allServices.each { svc ->
                    def valuesFile = "k8s/charts/${svc}/values.yaml"
                    def imageRepo  = "yas-${svc}"
                    if (svc == 'storefront-ui')  { imageRepo = 'yas-storefront'   }
                    if (svc == 'backoffice-ui')  { imageRepo = 'yas-backoffice'   }
                    sh """
                        sed -i 's|ghcr.io/nashtech-garage/yas-${svc}|docker.io/${DOCKER_HUB_USER}/${imageRepo}|g' \
                            ${valuesFile}
                        # Đổi tag từ bất kỳ thứ gì thành commit SHA hiện tại
                        sed -i 's|tag: .*|tag: ${env.COMMIT_SHORT_SHA}|g' ${valuesFile}
                    """
                }
            }
        }

        // ─── Stage 4: Verify patched values ───────────────────────────
        stage('Verify patched values') {
            script {
                def sampleTag = sh(
                    script: "grep -E '^\\s*tag:' k8s/charts/cart/values.yaml | head -1 | awk '{print \\$2}'",
                    returnStdout: true
                ).trim()
                if (sampleTag != env.COMMIT_SHORT_SHA) {
                    error("❌ values.yaml patch failed. Expected tag:${env.COMMIT_SHORT_SHA}, got: ${sampleTag}")
                }
            }
        }

        // ─── Stage 5: Commit & Push to Git (PULL MODEL) ───────────────
        // [skip ci] trong commit message ngăn CI build loop
        // → ArgoCD thấy commit → auto-sync dev namespace
        // → Dev_cd KHÔNG tự trigger lại
        stage('Commit & Push to Git') {
            script {
                sh '''
                    git config --global user.email  'jenkins@yas.local'
                    git config --global user.name   'YAS CI/CD — Dev CD'
                '''

                def hasChanges = sh(
                    script: "git diff --stat | grep -q 'values.yaml' && echo 'yes' || echo 'no'",
                    returnStdout: true
                ).trim()

                if (hasChanges == 'yes') {
                    sh '''
                        git add k8s/charts/*/values.yaml
                    '''

                    def commitMsg = """[CD/dev] Update Docker Hub image refs to ${env.COMMIT_SHORT_SHA}

[skip ci]

Co-authored-by: YAS CI/CD Dev CD <jenkins@yas.local>"""

                    sh """
                        git commit -m "${commitMsg.replaceAll('"', '\\\\"').replaceAll('\n', '\\n')}"
                        git push origin ${GIT_BRANCH}
                    """
                } else {
                    echo "⏭  No values.yaml changes — skipping commit"
                }
            }
        }
    }

    post {
        success {
            echo "✅ DEV_CD COMPLETED — Commit: ${env.COMMIT_SHORT_SHA} — ArgoCD sync triggered"
        }
        always  { cleanWs() }
    }
}
```

**GitOps Pull Model — Nguyên lý hoạt động:**

```
┌────────────────────────────────────────────────────────────────────────────┐
│                    GitOps Pull Model — Dev Environment                      │
│                                                                            │
│   CI Jenkinsfile (Jenkinsfile gốc)                                        │
│        │                                                                   │
│        ├── Build service + docker push (tag: <sha>)                        │
│        └── git commit values.yaml (KHÔNG có [skip ci])                    │
│              │                                                             │
│              ▼                                                             │
│   ArgoCD yas-dev-all-services                                              │
│   (targetRevision: main, automated sync)                                    │
│        │                                                                   │
│        ├── Phát hiện commit mới trên main ✅                              │
│        └── Helm upgrade dev namespace (image: <sha>)                        │
│                                                                            │
│   dev_cd Jenkinsfile (thấy main thay đổi → trigger)                      │
│        │                                                                   │
│        ├── Lấy COMMIT_SHORT_SHA = git rev-parse --short HEAD              │
│        ├── Build & push Docker images (tag: <sha>)                        │
│        ├── Patch values.yaml: tag → <sha>                                  │
│        └── git commit values.yaml (CÓ [skip ci])  ←── KHÔNG trigger CI   │
│              │                                                             │
│              ▼                                                             │
│   ArgoCD yas-dev-all-services                                              │
│        │                                                                   │
│        ├── Phát hiện commit mới trên main ✅                              │
│        └── Helm upgrade dev namespace (image: <sha>, idempotent)           │
│                                                                            │
│   dev_cd KHÔNG tự trigger lại vì [skip ci] ✅                             │
└────────────────────────────────────────────────────────────────────────────┘
```

**Thay đổi so với thiết kế cũ:** Đã **xóa hoàn toàn** 4 stages:
- ❌ `Create dev namespace`
- ❌ `Deploy all services via Helm`
- ❌ `Expose services via NodePort`
- ❌ `Verify deployment`

**Image tag strategy:** Thay `latest` bằng `COMMIT_SHORT_SHA` (7 ký tự đầu của commit SHA) — đảm bảo mỗi deployment uniquely traceable về đúng commit, thay vì dùng chung tag `latest` cho mọi commit.

---

### 5.2. `jenkins/staging-cd-jenkinsfile` — Staging CD Pipeline (GitOps Pull Model)

```groovy
// ================================================================
// staging_cd Jenkinsfile
// GitOps PULL MODEL — CHỈ commit Git, KHÔNG helm/kubectl
//
// Trigger  : Git tag dạng v*.*.* được push lên origin
// VD       : git tag v1.2.3 && git push origin v1.2.3
//
// Luồng hoàn chỉnh:
//   1. Developer tạo git tag v1.2.3 và push
//   2. staging_cd trigger tự động (GitHub webhook)
//   3. Extract git tag v1.2.3
//   4. Build & push ALL images (tag = v1.2.3) lên Docker Hub
//   5. Patch values.yaml: tag = v1.2.3, ghcr.io → docker.io
//   6. Commit & push values.yaml (CÓ [skip ci])
//      → ArgoCD thấy tag v1.2.3 match "v*.*.*" → sync staging ✅
//      → staging_cd KHÔNG tự trigger lại
// ================================================================
pipeline {
    agent any

    environment {
        DOCKER_HUB_USER = 'nashtechgarage'
        GIT_REPO        = 'https://github.com/.../yas-pj2.git'
        GIT_BRANCH      = 'main'
        GIT_CREDENTIALS = 'github-read-write'
    }

    stages {

        // ─── Stage 1: Extract Git Tag ──────────────────────────────────
        stage('Extract Git Tag') {
            script {
                def tag = env.GIT_TAG_NAME ?: env.TAG_NAME ?: ''
                if (!tag) {
                    tag = sh(script: "git describe --tags --abbrev=0", returnStdout: true).trim()
                }
                env.RELEASE_TAG = tag   // VD: v1.2.3
            }
        }

        // ─── Stage 2: Checkout ─────────────────────────────────────────
        stage('Checkout') {
            steps { checkout scm }
        }

        // ─── Stage 3: Verify tag format ────────────────────────────────
        stage('Verify tag format') {
            steps {
                script {
                    def tag = env.RELEASE_TAG
                    if (!tag.matches(/^v\d+\.\d+\.\d+.*$/)) {
                        error("❌ Invalid tag: '${tag}'. Expected: v*.*.*  VD: v1.2.3")
                    }
                }
            }
        }

        // ─── Stage 4: Build & Push Docker Images ─────────────────────
        stage('Build & Push Docker Images') {
            script {
                // Lấy commit SHA (cần vì đang ở detached HEAD state)
                env.COMMIT_SHORT_SHA = sh(
                    script: 'git rev-parse --short HEAD',
                    returnStdout: true
                ).trim()

                def javaServices = [
                    'cart','customer','inventory','location','media',
                    'order','payment','payment-paypal','product',
                    'promotion','rating','recommendation','sampledata',
                    'search','tax','webhook',
                    'storefront-bff','backoffice-bff'
                ]
                def nodeServices = ['storefront', 'backoffice']

                (javaServices + nodeServices).each { svc ->
                    def imageRepo = "yas-${svc}"
                    def tag = env.RELEASE_TAG    // VD: v1.2.3
                    sh """
                        docker build -t ${DOCKER_HUB_USER}/${imageRepo}:${tag} ${svc}/
                        docker push ${DOCKER_HUB_USER}/${imageRepo}:${tag}

                        # Vẫn push thêm bản tag latest để dự phòng
                        docker tag ${DOCKER_HUB_USER}/${imageRepo}:${tag} \
                                  ${DOCKER_HUB_USER}/${imageRepo}:latest
                        docker push ${DOCKER_HUB_USER}/${imageRepo}:latest
                    """
                }
            }
        }

        // ─── Stage 5: Patch Helm values.yaml ─────────────────────────
        // Đổi: ghcr.io → docker.io/nashtechgarage
        // Đổi: tag: bất kỳ → <release_tag> (VD: v1.2.3)
        stage('Patch Helm values.yaml') {
            script {
                def allServices = [
                    'cart','customer','inventory','location','media',
                    'order','payment','payment-paypal','product',
                    'promotion','rating','recommendation','sampledata',
                    'search','tax','webhook',
                    'storefront-ui','storefront-bff',
                    'backoffice-ui','backoffice-bff',
                ]
                allServices.each { svc ->
                    def valuesFile = "k8s/charts/${svc}/values.yaml"
                    def imageRepo  = "yas-${svc}"
                    if (svc == 'storefront-ui')  { imageRepo = 'yas-storefront' }
                    if (svc == 'backoffice-ui')  { imageRepo = 'yas-backoffice' }
                    sh """
                        sed -i 's|ghcr.io/nashtech-garage/yas-${svc}|docker.io/${DOCKER_HUB_USER}/${imageRepo}|g' \
                            ${valuesFile}
                        # Đổi tag từ bất kỳ thứ gì thành release tag (VD: v1.2.3)
                        sed -i 's|tag: .*|tag: ${env.RELEASE_TAG}|g' ${valuesFile}
                    """
                }
            }
        }

        // ─── Stage 6: Verify patched values ───────────────────────────
        stage('Verify patched values') {
            script {
                def sampleTag = sh(
                    script: "grep -E '^\\s*tag:' k8s/charts/cart/values.yaml | head -1 | awk '{print \\$2}'",
                    returnStdout: true
                ).trim()
                if (sampleTag != env.RELEASE_TAG) {
                    error("❌ Patch failed. Expected tag:${env.RELEASE_TAG}, got: ${sampleTag}")
                }
            }
        }

        // ─── Stage 7: Commit & Push to Git (PULL MODEL) ───────────────
        // [skip ci] ngăn CI job chạy lại
        // → ArgoCD thấy tag v1.2.3 match "v*.*.*" → sync staging
        stage('Commit & Push to Git') {
            script {
                sh '''
                    git config --global user.email  'jenkins@yas.local'
                    git config --global user.name   'YAS CI/CD — Staging CD'
                '''

                def hasChanges = sh(
                    script: "git diff --stat | grep -q 'values.yaml' && echo 'yes' || echo 'no'",
                    returnStdout: true
                ).trim()

                if (hasChanges == 'yes') {
                    sh 'git add k8s/charts/*/values.yaml'

                    def releaseTag = env.RELEASE_TAG
                    def commitMsg = """[CD/staging] Release ${releaseTag} — Docker Hub image update

[skip ci]

Co-authored-by: YAS CI/CD Staging CD <jenkins@yas.local>"""

                    sh """
                        git commit -m "${commitMsg.replaceAll('"', '\\\\"').replaceAll('\n', '\\n')}"
                        git push origin refs/heads/${GIT_BRANCH}
                    """
                } else {
                    echo "⏭  No values.yaml changes — skipping commit"
                }
            }
        }
    }

    post {
        success {
            echo "✅ STAGING_CD COMPLETED — ArgoCD sync triggered (tag: ${env.RELEASE_TAG})"
        }
        always { cleanWs() }
    }
}
```

**GitOps Pull Model — Staging Flow:**

```
git tag v1.2.3 && git push origin v1.2.3
         │
         ▼
GitHub Webhook → staging_cd Jenkinsfile trigger
         │
         ├── Extract: RELEASE_TAG = v1.2.3
         ├── Build & push images: nashtechgarage/yas-*:v1.2.3
         ├── Patch values.yaml: tag: v1.2.3, ghcr.io → docker.io
         └── Commit & push values.yaml ([skip ci])

              │ Git push
              ▼
         ArgoCD yas-staging-all-services
         (targetRevision: "v*.*.*")
              │
              ├── Tag v1.2.3 match "v*.*.*" ✅
              └── Helm upgrade staging namespace

              staging namespace
              └── Tất cả services (tag: v1.2.3)
```

**Thay đổi so với thiết kế cũ:** Đã **xóa hoàn toàn** 3 stages cuối:
- ❌ `Create staging namespace` (Stage 4 cũ)
- ❌ `Deploy all services to staging` (Stage 5 cũ)
- ❌ `Verify staging deployment` (Stage 6 cũ)

→ **Thêm Stage 6** (`Verify patched values`) — verify `sed` trước commit.
→ **Thêm Stage 7** (`Commit & Push to Git`) — [skip ci] ngăn loop, ArgoCD sync staging.

---

### 5.3. `jenkins/developer-build-jenkinsfile` — Developer Test Pipeline

> **Giữ nguyên** — `developer_build` tạo môi trường test tạm thời cho developer,
> không thuộc phạm vi ArgoCD GitOps. ArgoCD không quản lý namespace `developer`.
> Jenkins trực tiếp `helm upgrade` và `kubectl expose` là **đúng** trong ngữ cảnh này
> vì đây là môi trường **manual test** không cần ArgoCD reconcile.

**Logic chính:**

```
┌────────────────────────────────────────────────────────────────┐
│ Ví dụ: Developer đang làm dev_tax_service trên service tax   │
│                                                                │
│ SERVICE_NAME = tax                                            │
│ BRANCH_NAME  = dev_tax_service                                │
│                                                                │
│ Logic:                                                        │
│   tax        → image tag = dev_tax_service-<sha>  (BRANCH)    │
│   cart       → image tag = main                (STABLE)       │
│   storefront → image tag = main                (STABLE)       │
│   ...        → image tag = main                (STABLE)       │
│                                                                │
│ → deploy vào namespace: developer                              │
│ → NodePort: 30001 (storefront), 30002 (backoffice)           │
│ → Dev thêm hosts: <WORKER-IP> storefront.yas.local.com       │
│ → Dev truy cập http://<WORKER-IP>:30001 để test              │
└────────────────────────────────────────────────────────────────┘
```

**Stage 5 — Build chỉ service được chỉ định:**
```groovy
stage('Build & Push target service image') {
    script {
        def svc = params.SERVICE_NAME       // tax
        def imageRepo = "yas-${svc}"
        def tag = env.IMAGE_TAG              // dev_tax_service-a1b2c3d
        sh """
            docker build -t ${DOCKER_HUB_USER}/${imageRepo}:${tag} ${svc}/
            docker push ${DOCKER_HUB_USER}/${imageRepo}:${tag}
        """
    }
}
```

**Stage 6 — Đảm bảo các service khác có image main:**
```groovy
// Chỉ pull nếu chưa có — tiết kiệm thời gian
docker pull ${DOCKER_HUB_USER}/${imageRepo}:main || true
```

**Stage 9 — Dynamic NodePort cho service đang test:**
```groovy
// Mỗi service được expose NodePort ngẫu nhiên (3xxxx)
// Developer biết được port cụ thể qua stage output
kubectl expose deployment ${params.SERVICE_NAME} \
  -n developer --type=NodePort --port=80 --target-port=80 \
  --name=${params.SERVICE_NAME}-np --overwrite=True
```

---

### 5.4. `jenkins/developer-delete-jenkinsfile` — Cleanup Pipeline

```groovy
// Xóa theo thứ tự để tránh orphaned resources:
stage('Delete all Helm releases')
    // helm uninstall <release> — xóa Deployment, Service, ConfigMap...

stage('Delete all Kubernetes resources')
    // kubectl delete all/configmap/secret/pvc --all
    // Đảm bảo không có orphaned PVC, Secret, ConfigMap

stage('Delete developer namespace')
    // kubectl delete namespace developer
    // Xóa namespace cuối cùng để cascade xóa các resources còn lại

stage('Verify deletion')
    // kubectl get namespace developer → phải return NotFound
```

---

## 6. LUỒNG CI/CD HOÀN CHỈNH

### Luồng 1: Developer đẩy code lên feature branch (VD: `dev_tax_service`)

```
Developer (VS Code / Git)
    │
    ├── git add . && git commit -m "fix tax calculation"
    └── git push origin dev_tax_service
              │
              ▼
Jenkins CI Job (Jenkinsfile gốc)
    ├── SCM poll / webhook trigger on feature branch
    ├── mvn test -pl tax -am
    ├── SonarQube scan
    ├── Snyk security check
    ├── docker build -t nashtechgarage/yas-tax:dev_tax_service-<sha>
    └── docker push nashtechgarage/yas-tax:dev_tax_service-<sha>

    HOẶC: Developer vào Jenkins UI → developer_build job
    ├── SERVICE_NAME = tax
    ├── BRANCH_NAME  = dev_tax_service
    ├── Checkout branch: dev_tax_service
    ├── docker build → tag: dev_tax_service-<sha>
    ├── helm upgrade developer namespace
    │     ├── tax         → image: dev_tax_service-<sha>
    │     └── all others → image: main
    └── Developer truy cập: http://<WORKER-IP>:30001
              │
              ▼
ArgoCD (nếu CI update values.yaml và push main)
    ├── Phát hiện commit mới trên main
    ├── Auto-sync dev namespace
    └── Helm upgrade dev → tất cả services với tag: latest
```

### Luồng 2: Merge vào main → Auto-deploy dev

```
git checkout main && git merge dev_tax_service && git push origin main
              │
              ▼
Jenkins CI (Jenkinsfile gốc)
    ├── Build tất cả services thay đổi
    ├── docker push nashtechgarage/yas-<svc>:latest
    └── git commit values.yaml → push main
              │
              ▼
ArgoCD yas-dev-all-services
    ├── targetRevision: main
    ├── Phát hiện commit mới trên main ✅
    ├── ArgoCD re-render Helm charts
    ├── helm upgrade dev namespace (image: latest)
    └── Rolling-update pods trong dev
              │
              ▼
Namespace dev
    ├── Tất cả 22 services ✅ (image: latest)
    ├── Istio mTLS ✅
    ├── Retry policy ✅
    ├── Authorization policy ✅
    └── NodePort: 30001, 30002
```

### Luồng 3: Tạo release → Deploy staging

```
git tag v1.2.3
git push origin v1.2.3
              │
              ▼
GitHub Webhook → Jenkins staging_cd job
    ├── Extract GIT_TAG_NAME = v1.2.3
    ├── Verify format (^v\d+\.\d+\.\d+.*$)
    ├── docker build & push nashtechgarage/yas-*:v1.2.3
    ├── sed values.yaml: tag: latest → tag: v1.2.3
    ├── helm upgrade staging namespace
    └── ArgoCD yas-staging-all-services
          ├── targetRevision: "v*.*.*"
          ├── Match v1.2.3 tag ✅
          └── Sync staging namespace
              │
              ▼
Namespace staging
    ├── Tất cả 22 services ✅ (image: v1.2.3)
    ├── Istio mTLS ✅
    └── ClusterIP services (không expose NodePort)
```

---

## 7. HƯỚNG DẪN CÀI ĐẶT

### Bước 1: Cài đặt Kubernetes Cluster

```bash
# Tùy chọn: Minikube (1 node) hoặc Kind / K3s / production cluster
# Ví dụ: Minikube với 2 nodes
minikube start --nodes 2 --driver=docker

# Hoặc kiểm tra cluster hiện có
kubectl get nodes
```

### Bước 2: Cài đặt ArgoCD

```bash
# Tạo namespace argocd
kubectl create namespace argocd

# Apply ArgoCD manifest (Standard install)
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Đợi ArgoCD server ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

# Truy cập ArgoCD UI (password = initial admin secret)
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

### Bước 3: Cài đặt Istio

```bash
# Download Istio
curl -L https://istio.io/downloadIstio | sh -
cd istio-1.22.*
export PATH=$PWD/bin:$PATH

# Demo profile (đủ cho môi trường dev/test)
istioctl install --set profile=demo -y

# Verify
kubectl get pods -n istio-system
```

### Bước 4: Apply ArgoCD manifests

```bash
# Clone repo
git clone https://github.com/Introduction-To-DevOps-Group-10/yas-pj2.git
cd yas-pj2

# Apply namespaces (tạo dev, staging, developer + Istio labels)
kubectl apply -f k8s/argocd/namespaces.yaml

# Apply ArgoCD root app (ArgoCD sẽ tự tạo child apps)
kubectl apply -f k8s/argocd/root-app.yaml

# Verify ArgoCD apps
kubectl get application -n argocd
# NAME              KIND         NAMESPACE  STATUS   HEALTH
# yas-root          Application  argocd    Unknown
```

### Bước 5: Apply Istio policies

```bash
# Apply strict mTLS
kubectl apply -f k8s/istio/base/global-mtls.yaml

# Apply retry policy cho cart
kubectl apply -f k8s/istio/policies/cart-retry-vs.yaml

# Apply authorization policy
kubectl apply -f k8s/istio/policies/cart-authz.yaml

# Verify
kubectl get PeerAuthentication -n istio-system
kubectl get VirtualService -n dev
kubectl get AuthorizationPolicy -n dev
```

### Bước 6: Tạo Jenkins Jobs trên Jenkins UI

```
JENKINS → New Item → Pipeline

┌─────────────────────────────────────────────────────┐
│ 1. dev_cd                                           │
│    Type        : Pipeline                          │
│    Definition  : Pipeline script from SCM          │
│    SCM         : Git                              │
│    Repository  : https://github.com/.../yas-pj2   │
│    Script Path : jenkins/dev-cd-jenkinsfile       │
│    Branch      : */main                           │
│    Triggers    : GitHub hook trigger               │
├─────────────────────────────────────────────────────┤
│ 2. staging_cd                                      │
│    Type        : Pipeline                          │
│    Definition  : Pipeline script from SCM          │
│    Script Path : jenkins/staging-cd-jenkinsfile   │
│    Triggers    : Build when a tag is pushed        │
│    Parameter   : TAG_NAME = refs/tags/v*          │
├─────────────────────────────────────────────────────┤
│ 3. developer_build                                  │
│    Type        : Pipeline                          │
│    Definition  : Pipeline script from SCM          │
│    Script Path : jenkins/developer-build-jenkinsfile│
│    Triggers    : None (manual only)               │
│    Concurrency : Do not allow concurrent builds    │
├─────────────────────────────────────────────────────┤
│ 4. developer_delete                                │
│    Type        : Pipeline                          │
│    Definition  : Pipeline script from SCM          │
│    Script Path : jenkins/developer-delete-jenkinsfile│
│    Triggers    : None (manual only)               │
└─────────────────────────────────────────────────────┘
```

### Bước 7: Cấu hình GitHub Webhook

```
GitHub Repository → Settings → Webhooks → Add webhook
  ├── Payload URL: https://<JENKINS-URL>/github-webhook/
  ├── Content type: application/json
  ├── Events: ✅ Push, ✅ Tag push
  └── Active: ✅
```

---

## 8. CÁC THAY ĐỔI CẦN THỰC HIỆN THỦ CÔNG

### 8.1. Thay K8S API Server IP

Trong **tất cả 4 file Jenkinsfile**, tìm và thay:

```groovy
// TRƯỚC:
K8S_CLUSTER = 'https://<K8S-MASTER-IP>:6443'

// SAU (ví dụ):
K8S_CLUSTER = 'https://192.168.1.100:6443'
```

Cách lấy IP:
```bash
# Nếu dùng Minikube:
minikube ip

# Nếu dùng remote K8s:
kubectl get nodes -o wide
# OUTPUT: NAME    STATUS  INTERNAL-IP  EXTERNAL-IP
#        node1   Ready   192.168.1.100   -
```

### 8.2. Xác nhận SPIFFE ID thực tế của storefront-bff

```bash
# Sau khi deploy storefront-bff vào namespace dev:
kubectl get pod -n dev -l app=storefront-bff \
  -o jsonpath='{.items[0].spec.serviceAccountName}'

# Output: storefront-bff

# SPIFFE ID = spiffe://cluster.local/ns/dev/sa/storefront-bff
# Kiểm tra SPIFFE ID trong certificate:
kubectl exec -n dev -it \
  $(kubectl get pod -n dev -l app=storefront-bff -o name | head -1) \
  -c istio-proxy -- pilot-agent status | grep SPIFFE
```

### 8.3. Docker Hub Credentials trong Jenkins

```
Jenkins → Manage Jenkins → Credentials → System → Global credentials
  → Add Credential:
    Kind    : Username with password
    ID      : docker-hub-credentials
    Username: nashtechgarage
    Password: <Docker Hub Access Token>
```

### 8.4. Kubernetes Credentials trong Jenkins

```
Jenkins → Manage Jenkins → Credentials → System → Global credentials
  → Add Credential:
    Kind    : Kubernetes configuration (kubeconfig)
    ID      : k8s-cluster-credentials
    Content : <output của: cat ~/.kube/config>
```

### 8.5. Mirror Istio policies sang staging và developer

File `k8s/istio/policies/cart-retry-vs.yaml` và `k8s/istio/policies/cart-authz.yaml`
hiện tại chỉ có `namespace: dev`. Cần tạo bản sao cho staging và developer:

```bash
# Tạo bản sao cho staging
sed 's/namespace: dev/namespace: staging/g' \
  k8s/istio/policies/cart-retry-vs.yaml > \
  k8s/istio/policies/cart-retry-vs-staging.yaml

sed 's/namespace: dev/namespace: staging/g' \
  k8s/istio/policies/cart-authz.yaml > \
  k8s/istio/policies/cart-authz-staging.yaml

# Tạo bản sao cho developer
sed 's/namespace: dev/namespace: developer/g' \
  k8s/istio/policies/cart-retry-vs.yaml > \
  k8s/istio/policies/cart-retry-vs-developer.yaml

sed 's/namespace: dev/namespace: developer/g' \
  k8s/istio/policies/cart-authz.yaml > \
  k8s/istio/policies/cart-authz-developer.yaml

# Apply tất cả
kubectl apply -f k8s/istio/policies/
```

---

## TÓM TẮT CÁC FILE ĐÃ TẠO

| # | Đường dẫn | Loại | Mục đích |
|---|---|---|---|
| 1 | `k8s/argocd/namespaces.yaml` | K8s Manifest | Tạo dev/staging/developer NS + Istio labels |
| 2 | `k8s/argocd/root-app.yaml` | ArgoCD App | Root app-of-apps, theo dõi `k8s/argocd/apps/` |
| 3 | `k8s/argocd/apps/kustomization.yaml` | Kustomize | Compose dev + staging apps |
| 4 | `k8s/argocd/apps/dev/all-services.yaml` | ArgoCD App | Auto-sync main → dev |
| 5 | `k8s/argocd/apps/dev/kustomization.yaml` | Kustomize | Dev app entry |
| 6 | `k8s/argocd/apps/staging/all-services.yaml` | ArgoCD App | Sync Git tag v*.*.* → staging |
| 7 | `k8s/argocd/apps/staging/kustomization.yaml` | Kustomize | Staging app entry |
| 8 | `k8s/istio/base/global-mtls.yaml` | Istio Policy | STRICT mTLS + ISTIO_MUTUAL |
| 9 | `k8s/istio/base/namespace-label.yaml` | ConfigMap | Tài liệu Istio injection |
| 10 | `k8s/istio/policies/cart-retry-vs.yaml` | Istio VS | Retry 3x on HTTP 5xx |
| 11 | `k8s/istio/policies/cart-authz.yaml` | Istio AuthZ | Chỉ storefront-bff → cart |
| 12 | `jenkins/dev-cd-jenkinsfile` | Jenkinsfile | Auto CD dev (main → dev) |
| 13 | `jenkins/staging-cd-jenkinsfile` | Jenkinsfile | CD staging (tag → staging) |
| 14 | `jenkins/developer-build-jenkinsfile` | Jenkinsfile | Developer test code |
| 15 | `jenkins/developer-delete-jenkinsfile` | Jenkinsfile | Xóa developer namespace |

**Tổng: 15 files mới được tạo, 0 file hiện có bị sửa.**
