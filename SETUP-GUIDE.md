# HƯỚNG DẪN CÀI ĐẶT & VẬN HÀNH — YAS CI/CD Pipeline

> **Ngày cập nhật:** 2026-04-14
> **Mục tiêu:** Hướng dẫn chi tiết từng bước cài đặt và vận hành toàn bộ hệ thống CI/CD cho YAS
> **Thứ tự cài đặt:** Kubernetes → Istio → ArgoCD → Jenkins → Docker Hub → GitHub Webhook

---

## MỤC LỤC

1. [Tổng quan kiến trúc](#1-tổng-quan-kiến-trúc)
2. [Yêu cầu hệ thống](#2-yêu-cầu-hệ-thống)
3. [Bước 1 — Kubernetes Cluster](#3-bước-1--kubernetes-cluster)
4. [Bước 2 — Docker Hub](#4-bước-2--docker-hub)
5. [Bước 3 — Istio Service Mesh](#5-bước-3--istio-service-mesh)
6. [Bước 4 — ArgoCD](#6-bước-4--argocd)
7. [Bước 5 — Jenkins](#7-bước-5--jenkins)
8. [Bước 6 — GitHub Webhook](#8-bước-6--github-webhook)
9. [Bước 7 — ArgoCD CLI](#9-bước-7--argocd-cli)
10. [Chạy thử nguyên luồng CI/CD](#10-chạy-thử-nguyên-luồng-cicd)
11. [Monitoring & Troubleshooting](#11-monitoring--troubleshooting)

---

## 1. TỔNG QUAN KIẾN TRÚC

```
Developer Code (GitHub)
        │
        ▼
┌───────────────────┐       ┌──────────────────────┐
│   GitHub Webhook   │──────→│  Jenkins Controller  │
│  (push / tag / PR)│       │   (Jenkins Server)   │
└───────────────────┘       └──────────┬───────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                │
                    ▼                ▼                ▼
           ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
           │   dev_cd     │  │ staging_cd   │  │developer_   │
           │  Jenkins Job │  │  Jenkins Job │  │  build       │
           └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
                  │                │                │
                  ▼                ▼                ▼
         ┌──────────────────────────────────────────────┐
         │              GitHub Repository                  │
         │  (commit values.yaml với image tag mới)      │
         └─────────────────────┬────────────────────────┘
                               │ webhook
                               ▼
         ┌──────────────────────────────────────────────┐
         │            ArgoCD Controller                   │
         │  (theo dõi Git, auto-sync vào cluster)      │
         └─────────────────────┬────────────────────────┘
                               │
         ┌─────────────────────┼─────────────────────────┐
         │                     │                         │
         ▼                     ▼                         ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Namespace   │     │  Namespace   │     │  Namespace   │
│     dev     │     │  staging     │     │  developer  │
│  (auto-sync)│     │ (sync on tag)│     │  (manual)   │
└──────────────┘     └──────────────┘     └──────────────┘
         │                     │                         │
         └─────────────────────┼─────────────────────────┘
                               │
                    ┌──────────┴──────────┐
                    │  Kubernetes Cluster  │
                    │  ─────────────────  │
                    │  Istio mTLS ✅      │
                    │  Retry Policy ✅    │
                    │  Authz Policy ✅   │
                    │  NGINX Ingress     │
                    └───────────────────┘
```

---

## 2. YÊU CẦU HỆ THỐNG

### Phần cứng (cho môi trường dev/test)

| Component | Yêu cầu tối thiểu |
|---|---|
| RAM | 8 GB (Jenkins + K8s + Istio + ArgoCD) |
| CPU | 4 cores |
| Disk | 50 GB free |
| OS | Windows 10/11 (Docker Desktop) hoặc Linux/macOS |

### Phần mềm cần cài đặt

| Tool | Phiên bản | Mục đích |
|---|---|---|
| Docker Desktop | 4.x+ | Chạy Minikube/Kind agent + build Docker images |
| kubectl | 1.28+ | Quản lý Kubernetes cluster |
| Helm | 3.12+ | Deploy Helm charts |
| Minikube | 1.32+ | K8s cluster local (hoặc Kind) |
| ArgoCD CLI | 2.10+ | Quản lý ArgoCD qua command line |
| Istioctl | 1.22+ | Cài đặt và quản lý Istio |
| Jenkins | 2.440+ | CI/CD automation server |

### Tài khoản cần chuẩn bị

| Tài khoản | Mục đích |
|---|---|
| Docker Hub | Push/pull Docker images |
| GitHub | Webhook trigger, git push |
| ArgoCD | UI quản lý deployments |
| Jenkins | Tạo và quản lý jobs |

---

## 3. BƯỚC 1 — KUBERNETES CLUSTER

### 3.1. Cài đặt kubectl

```bash
# Windows (dùng Chocolatey)
choco install kubernetes-cli -y

# Kiểm tra
kubectl version --client
```

### 3.2. Cài đặt Minikube (recommend cho dev)

```bash
# Windows
choco install minikube -y

# Linux/macOS
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Cài đặt driver Docker (khuyên dùng)
minikube config set driver docker

# (Tùy chọn) Cài đặt Ingress addon
minikube addons enable ingress

# Start cluster với 2 nodes để simulate môi trường thực
minikube start --nodes 2 --driver=docker --cpus=4 --memory=8g

# Kiểm tra
kubectl get nodes
```

```
OUTPUT mong đợi:
NAME           STATUS   ROLES           AGE
minikube       Ready    control-plane   2m
minikube-m02   Ready    <none>          1m
```

### 3.3. (Tùy chọn) Cài đặt ingress-nginx

```bash
# Ingress controller để truy cập services từ bên ngoài cluster
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml

# Verify
kubectl get pods -n ingress-nginx
```

---

## 4. BƯỚC 2 — DOCKER HUB

### 4.1. Tạo tài khoản Docker Hub

1. Truy cập https://hub.docker.com
2. Đăng ký tài khoản (VD: `nashtechgarage`)
3. Tạo Repository cho từng service:

```bash
# Đăng nhập Docker Hub
docker login -u nashtechgarage

# Tạo repository thủ công trên Docker Hub UI:
# https://hub.docker.com/repositories → New Repository
# Tạo các repo sau:
#
#   nashtechgarage/yas-cart
#   nashtechgarage/yas-customer
#   nashtechgarage/yas-product
#   nashtechgarage/yas-order
#   nashtechgarage/yas-inventory
#   nashtechgarage/yas-location
#   nashtechgarage/yas-media
#   nashtechgarage/yas-payment
#   nashtechgarage/yas-payment-paypal
#   nashtechgarage/yas-promotion
#   nashtechgarage/yas-rating
#   nashtechgarage/yas-recommendation
#   nashtechgarage/yas-sampledata
#   nashtechgarage/yas-search
#   nashtechgarage/yas-tax
#   nashtechgarage/yas-webhook
#   nashtechgarage/yas-storefront
#   nashtechgarage/yas-storefront-bff
#   nashtechgarage/yas-backoffice
#   nashtechgarage/yas-backoffice-bff
```

### 4.2. Tạo Access Token (cho Jenkins)

1. Docker Hub → Account Settings → Security → Access Tokens
2. New Access Token:
   - **Token Name:** `jenkins-access`
   - **Access Permission:** `Read, Write, Delete`
3. Copy token (chỉ hiện 1 lần duy nhất)
4. Lưu token để cấu hình Jenkins credential ở Bước 7

---

## 5. BƯỚC 3 — ISTIO SERVICE MESH

### 5.1. Cài đặt Istio

```bash
# Windows
curl -L https://istio.io/downloadIstio | sh -

# Linux/macOS
curl -L https://istio.io/downloadIstio | sh -

# Di chuyển vào thư mục Istio
cd istio-1.22.*

# Thêm istioctl vào PATH (thay bằng đường dẫn thực tế)
export PATH=$PWD/bin:$PATH

# Cài đặt Istio với profile demo (đủ cho dev/staging)
istioctl install --set profile=demo -y

# Verify Istio components
kubectl get pods -n istio-system
```

```
OUTPUT mong đợi:
NAME                              READY
istio-egressgateway               1/1
istio-ingressgateway              1/1
istiod                            1/1
```

### 5.2. Enable Istio injection cho các namespaces

```bash
# Áp dụng cho cả 3 namespaces
kubectl label namespace dev       istio-injection=enabled --overwrite
kubectl label namespace staging   istio-injection=enabled --overwrite
kubectl label namespace developer istio-injection=enabled --overwrite

# Verify
kubectl get namespace -L istio-injection
```

### 5.3. Apply Istio policies

```bash
# Di chuyển vào repo
cd yas-pj2

# Apply strict mTLS policy
kubectl apply -f k8s/istio/base/global-mtls.yaml

# Apply retry policy cho cart service
kubectl apply -f k8s/istio/policies/cart-retry-vs.yaml

# Apply authorization policy (chỉ storefront-bff → cart)
kubectl apply -f k8s/istio/policies/cart-authz.yaml

# Verify
kubectl get PeerAuthentication -n istio-system
kubectl get VirtualService -n dev
kubectl get AuthorizationPolicy -n dev
```

---

## 6. BƯỚC 4 — ARGOCD

### 6.1. Cài đặt ArgoCD

```bash
# Tạo namespace argocd
kubectl create namespace argocd

# Cài đặt ArgoCD (standard install)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Đợi ArgoCD server ready (có thể mất 2-3 phút)
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

# Verify
kubectl get pods -n argocd
```

### 6.2. Truy cập ArgoCD UI

**Cách 1 — Port-forward (cho dev local):**
```bash
# Terminal 1: Chạy port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Truy cập: https://localhost:8080
```

**Cách 2 — Ingress (cho remote cluster):**
```bash
# Tạo Ingress cho ArgoCD
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.yas.local.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF
```

### 6.3. Lấy mật khẩu admin ban đầu

```bash
# Lấy mật khẩu
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# OUTPUT:VD: Kq3v2-xxxxx

# Truy cập ArgoCD UI:
#   URL    : https://localhost:8080 (hoặc https://argocd.yas.local.com)
#   User   : admin
#   Pass   : <mật khẩu vừa lấy>
```

### 6.4. ArgoCD CLI — Cài đặt và kết nối

```bash
# Windows
choco install argocd-cli -y

# Linux/macOS
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/download/v2.10.0/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

# Login vào ArgoCD
argocd login localhost:8080 --username admin --password <MẬT-KHẨU>

# Verify
argocd version
```

### 6.5. Apply ArgoCD manifests (Root App + Namespaces)

```bash
cd yas-pj2

# Tạo 3 namespaces (dev, staging, developer) + Istio labels
kubectl apply -f k8s/argocd/namespaces.yaml

# Apply Root Application (app-of-apps pattern)
kubectl apply -f k8s/argocd/root-app.yaml

# Verify ArgoCD apps
argocd app list

# OUTPUT mong đợi:
# NAME           CLUSTER                         NAMESPACE  HEALTH
# yas-root      https://kubernetes.default.svc  argocd     Unknown
```

### 6.6. Verify ArgoCD sync trạng thái

```bash
# Kiểm tra app yas-root
argocd app get yas-root

# Kiểm tra child app dev
argocd app get yas-dev-all-services

# Sync thủ công (nếu cần)
argocd app sync yas-dev-all-services
```

---

## 7. BƯỚC 5 — JENKINS

### 7.1. Cài đặt Jenkins

**Cách 1 — Docker (nhanh nhất):**
```bash
docker run -d \
  --name jenkins \
  -p 8081:8080 \
  -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins/jenkins:lts
```

**Cách 2 — Cài trực tiếp (Windows):**
```powershell
choco install jenkins -y
```

**Cách 3 — Kubernetes (production):**
```bash
# Tạo Helm release cho Jenkins
helm repo add jenkins https://charts.jenkins.io
helm repo update

helm install jenkins jenkins/jenkins \
  -n jenkins --create-namespace \
  --set controller.serviceType=LoadBalancer \
  --set controller.adminPassword=admin123
```

### 7.2. Lấy mật khẩu Jenkins ban đầu

```bash
# Docker
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword

# Kubernetes
kubectl exec -n jenkins \
  $(kubectl get pods -n jenkins -l app=jenkins -o name) \
  -- cat /var/jenkins_home/secrets/initialAdminPassword
```

Truy cập: `http://localhost:8081` (hoặc `<JENKINS-URL>:8080`)

### 7.3. Cài đặt Jenkins Plugins cần thiết

Sau khi đăng nhập Jenkins lần đầu:

1. **Manage Jenkins** → **Manage Plugins** → Tab **Available**
2. Cài đặt các plugins sau:

| Plugin | Mục đích |
|---|---|
| `Git` | Clone Git repository |
| `GitHub` | GitHub integration + webhook |
| `Docker` | Build & push Docker images |
| `Kubernetes` | Deploy vào K8s cluster |
| `Pipeline` | Viết Jenkinsfile dạng Groovy |
| `Configuration as Code` | Quản lý config qua YAML |

### 7.4. Cấu hình Jenkins Credentials

**Manage Jenkins** → **Manage Credentials** → **System** → **Global credentials**

Tạo các credentials sau:

#### Credential 1 — GitHub (đọc/ghi repo)

| Trường | Giá trị |
|---|---|
| Kind | Username with password |
| ID | `github-read-write` |
| Username | `nashtech-garage` (hoặc GitHub username) |
| Password | GitHub Personal Access Token (PAT) |

**Cách tạo GitHub PAT:**
1. GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
2. Permissions:
   - ✅ Contents (Read and Write)
   - ✅ Pull requests (Read and Write)
   - ✅ Webhooks (Read and Write)
3. Generate token → copy ngay (chỉ hiện 1 lần)

#### Credential 2 — Docker Hub

| Trường | Giá trị |
|---|---|
| Kind | Username with password |
| ID | `docker-hub-credentials` |
| Username | `nashtechgarage` |
| Password | Docker Hub Access Token (đã tạo ở Bước 4.2) |

#### Credential 3 — Kubernetes Config (kubeconfig)

| Trường | Giá trị |
|---|---|
| Kind | Kubernetes configuration (kubeconfig) |
| ID | `k8s-cluster-config` |
| Kubeconfig | Nội dung file `~/.kube/config` |

### 7.5. Cấu hình Jenkins Tools

**Manage Jenkins** → **Tools** → **Tool Locations**

```
JDK:
  Name  : JDK21
  Path  : /usr/lib/jvm/java-21-openjdk-amd64  (Linux)
          C:\Program Files\Java\jdk-21          (Windows)

Maven:
  Name  : maven
  Install from Apache: Version: 3.9.6
```

### 7.6. Tạo 4 Jenkins Jobs

#### 7.6.1. Job 1 — `dev_cd`

```
┌──────────────────────────────────────────────────────────────┐
│  New Item → Pipeline                                        │
│  Name: dev_cd                                             │
│  Type: Pipeline                                           │
└──────────────────────────────────────────────────────────────┘
```

**Pipeline Configuration:**
- **Definition:** Pipeline script from SCM
- **SCM:** Git
  - **Repository URL:** `https://github.com/Introduction-To-DevOps-Group-10/yas-pj2.git`
  - **Credentials:** chọn `github-read-write`
  - **Branches:** `*/main`
- **Script Path:** `jenkins/dev-cd-jenkinsfile`
- **Lightweight checkout:** ✅

**Build Triggers:**
- ✅ **GitHub hook trigger for GITScm polling**
- Hoặc SCM poll: `H/2 * * * *` (poll mỗi 2 phút)

#### 7.6.2. Job 2 — `staging_cd`

```
┌──────────────────────────────────────────────────────────────┐
│  New Item → Pipeline                                        │
│  Name: staging_cd                                         │
│  Type: Pipeline                                           │
└──────────────────────────────────────────────────────────────┘
```

**Pipeline Configuration:**
- **Definition:** Pipeline script from SCM
- **SCM:** Git
  - **Repository URL:** `https://github.com/Introduction-To-DevOps-Group-10/yas-pj2.git`
  - **Credentials:** chọn `github-read-write`
  - **Branches:** `*/main`
- **Script Path:** `jenkins/staging-cd-jenkinsfile`
- **Lightweight checkout:** ✅

**Build Triggers:**
- ✅ **Build when a tag is pushed to origin**

#### 7.6.3. Job 3 — `developer_build`

```
┌──────────────────────────────────────────────────────────────┐
│  New Item → Pipeline                                        │
│  Name: developer_build                                     │
│  Type: Pipeline                                           │
└──────────────────────────────────────────────────────────────┘
```

**Pipeline Configuration:**
- **Definition:** Pipeline script from SCM
- **SCM:** Git
  - **Repository URL:** `https://github.com/Introduction-To-DevOps-Group-10/yas-pj2.git`
  - **Credentials:** chọn `github-read-write`
  - **Branches:** `*/main`
- **Script Path:** `jenkins/developer-build-jenkinsfile`
- **Lightweight checkout:** ✅

**Build Triggers:**
- ❌ None (chỉ chạy thủ công)

**Checkbox quan trọng:**
- ❌ **Do not allow concurrent builds** (ngăn chạy trùng lặp)

#### 7.6.4. Job 4 — `developer_delete`

```
┌──────────────────────────────────────────────────────────────┐
│  New Item → Pipeline                                        │
│  Name: developer_delete                                    │
│  Type: Pipeline                                           │
└──────────────────────────────────────────────────────────────┘
```

**Pipeline Configuration:**
- **Definition:** Pipeline script from SCM
- **SCM:** Git
  - **Repository URL:** `https://github.com/Introduction-To-DevOps-Group-10/yas-pj2.git`
  - **Credentials:** chọn `github-read-write`
  - **Branches:** `*/main`
- **Script Path:** `jenkins/developer-delete-jenkinsfile`
- **Lightweight checkout:** ✅

**Build Triggers:**
- ❌ None (chỉ chạy thủ công)

### 7.7. Cấu hình Jenkins Kubernetes Agent (nếu dùng K8s agent)

**Manage Jenkins** → **Manage Nodes and Clouds** → **Configure Clouds**

```yaml
# Kubernetes Cloud Configuration
Kubernetes URL: https://kubernetes.default.sku
Kubernetes Namespace: jenkins
Credentials: k8s-cluster-config
Jenkins URL: http://jenkins:8080
Jenkins tunnel: jenkins:50000
```

---

## 8. BƯỚC 6 — GITHUB WEBHOOK

### 8.1. Tạo GitHub Webhook

1. Truy cập: `https://github.com/Introduction-To-DevOps-Group-10/yas-pj2` → **Settings** → **Webhooks** → **Add webhook**

2. Cấu hình:

| Trường | Giá trị |
|---|---|
| Payload URL | `https://<JENKINS-URL>/github-webhook/` |
| Content type | `application/json` |
| Secret | `<Jenkins GitHub webhook secret>` (tùy chọn) |
| Events | ✅ Push, ✅ Tag push |

### 8.2. Cấu hình Jenkins GitHub Integration

**Manage Jenkins** → **Configure System** → **GitHub**

```
✅ Manage hooks
GitHub Servers:
  Name      : GitHub
  API URL   : https://api.github.com
  Credentials: GitHub PAT (credentials ID: github-read-write)
```

### 8.3. Test Webhook

```bash
# Trên GitHub Webhook UI:
# → Test → Send a test payload → Push events

# Trên Jenkins:
# → dev_cd job → Build Now
# Nếu thành công → webhook đang hoạt động
```

---

## 9. BƯỚC 7 — ARGOCD CLI

### 9.1. Commands thường dùng

```bash
# Login ArgoCD
argocd login localhost:8080 --username admin --password <MẬT-KHẨU>

# Xem tất cả apps
argocd app list

# Xem trạng thái app
argocd app get yas-dev-all-services
argocd app get yas-staging-all-services

# Sync app thủ công
argocd app sync yas-dev-all-services
argocd app sync yas-staging-all-services

# Xem logs sync
argocd app logs yas-dev-all-services

# Sync tất cả apps
argocd app sync --all

# Rollback app về version trước
argocd app rollback yas-dev-all-services

# Xem diff trước khi sync
argocd app diff yas-dev-all-services
```

### 9.2. ArgoCD CLI cho phép debug nhanh

```bash
# Theo dõi trạng thái sync liên tục
watch argocd app get yas-dev-all-services

# Xem resource tree
argocd app resources yas-dev-all-services

# Xem history của app (các lần sync)
argocd app history yas-dev-all-services
```

---

## 10. CHẠY THỬ NGUYÊN LUỒNG CI/CD

### Luồng 1 — Dev (mỗi commit lên main)

```
1. Developer push code lên main branch
   git checkout main
   git merge dev_tax_service
   git push origin main

2. GitHub webhook → trigger dev_cd Jenkins job
   ├── dev_cd chạy: git rev-parse --short HEAD  → abc1234
   ├── Docker build: nashtechgarage/yas-cart:abc1234
   ├── Docker push: nashtechgarage/yas-cart:abc1234
   ├── sed: values.yaml tag → abc1234
   ├── git commit values.yaml (CÓ [skip ci])
   └── git push origin main

3. ArgoCD phát hiện commit mới trên main
   └── ArgoCD sync: helm upgrade dev namespace
       └── pod cart → ghcr.io/nashtech-garage/yas-cart:abc1234

4. ArgoCD CLI verify:
   argocd app get yas-dev-all-services
   argocd app resources yas-dev-all-services

5. Truy cập dev (thêm vào /etc/hosts):
   <WORKER-IP>  storefront.yas.local.com
   http://<WORKER-IP>:30001
```

### Luồng 2 — Staging (tạo release tag)

```
1. Developer tạo và push tag
   git checkout main
   git tag v1.2.3
   git push origin v1.2.3

2. GitHub webhook → trigger staging_cd Jenkins job
   ├── staging_cd chạy: GIT_TAG_NAME = v1.2.3
   ├── Docker build: nashtechgarage/yas-cart:v1.2.3
   ├── Docker push: nashtechgarage/yas-cart:v1.2.3
   ├── sed: values.yaml tag → v1.2.3
   └── git commit values.yaml (CÓ [skip ci])
       └── git push origin main

3. ArgoCD phát hiện tag v1.2.3 (match "v*.*.*")
   └── ArgoCD sync: helm upgrade staging namespace
       └── pod cart → nashtechgarage/yas-cart:v1.2.3

4. ArgoCD CLI verify:
   argocd app get yas-staging-all-services
   kubectl get pods -n staging
```

### Luồng 3 — Developer test (tạm thời)

```
1. Developer vào Jenkins UI → Open developer_build job

2. Nhập parameters:
   SERVICE_NAME   : tax
   BRANCH_NAME    : dev_tax_service
   DOCKER_HUB_USER: nashtechgarage

3. Click "Build"

4. Jenkins chạy:
   ├── Checkout: dev_tax_service branch
   ├── git rev-parse --short HEAD  → 9f8e2a1
   ├── Docker build: nashtechgarage/yas-tax:dev_tax_service-9f8e2a1
   ├── Docker push: nashtechgarage/yas-tax:dev_tax_service-9f8e2a1
   ├── Helm upgrade: developer namespace (tất cả services)
   │   └── tax        → image: dev_tax_service-9f8e2a1
   │   └── all others → image: main
   └── kubectl expose: NodePort 30001, 30002

5. Jenkins output URL:
   http://<WORKER-IP>:30001  (storefront-bff)
   http://<WORKER-IP>:30002  (backoffice-bff)

6. Developer test → Xong → Chạy developer_delete job
```

---

## 11. MONITORING & TROUBLESHOOTING

### ArgoCD

```bash
# Xem logs của ArgoCD Application
argocd app logs yas-dev-all-services --follow

# Xem events của app
kubectl describe application yas-dev-all-services -n argocd

# Xem logs ArgoCD server
kubectl logs -n argocd -l app=argocd-server

# Xem ArgoCD sync errors
argocd app get yas-dev-all-services 2>&1 | grep -i error
```

### Jenkins

```bash
# Xem console output của job
# Jenkins UI → dev_cd → Build History → Click Build Number → Console Output

# Xem logs Jenkins controller
docker logs jenkins   # Docker
kubectl logs -n jenkins -l app=jenkins  # K8s
```

### Kubernetes

```bash
# Xem pods trong dev
kubectl get pods -n dev
kubectl describe pod <pod-name> -n dev
kubectl logs <pod-name> -n dev

# Xem services
kubectl get svc -n dev

# Xem events
kubectl get events -n dev --sort-by=.lastTimestamp

# Xem resources được apply bởi Helm
helm list -n dev
helm history cart -n dev
```

### Istio

```bash
# Xem Envoy proxy logs trong pod
kubectl logs <pod-name> -n dev -c istio-proxy

# Xem mTLS status
istioctl authz show <pod-name> -n dev

# Xem VirtualService routing
kubectl get virtualservice -n dev

# Xem AuthorizationPolicy
kubectl get authorizationpolicy -n dev

# Debug mTLS
istioctl analyze -n dev
```

### Docker Hub

```bash
# Kiểm tra image đã push
docker pull nashtechgarage/yas-cart:abc1234

# Verify image tags
curl -s "https://hub.docker.com/v2/repositories/nashtechgarage/yas-cart/tags/" \
  -u nashtechgarage:<ACCESS_TOKEN> | jq '.results[].name'
```

---

## CHECKLIST CUỐI CÙNG

```
TRƯỚC KHI CHẠY LUỒNG — Kiểm tra từng bước:

✅ Kubernetes cluster đang chạy
   kubectl get nodes  → 2 nodes Ready

✅ Istio đã cài đặt
   kubectl get pods -n istio-system  → istiod Running

✅ ArgoCD đã cài đặt
   kubectl get pods -n argocd  → ArgoCD server Running
   argocd app list           → yas-root, yas-dev-all-services

✅ ArgoCD root app đã sync
   argocd app get yas-root  → yas-root Synced

✅ ArgoCD dev/staging apps đang theo dõi Git
   argocd app get yas-dev-all-services
   argocd app get yas-staging-all-services

✅ Istio policies đã apply
   kubectl get peerauthentication -n istio-system
   kubectl get virtualservice -n dev
   kubectl get authorizationpolicy -n dev

✅ Jenkins credentials đã tạo
   Manage Jenkins → Credentials → 3 credentials

✅ Jenkins jobs đã tạo
   dev_cd, staging_cd, developer_build, developer_delete

✅ GitHub webhook đã kết nối
   GitHub → Settings → Webhooks → webhook active ✅

✅ Docker Hub repos đã tạo
   hub.docker.com → 20 repos

✅ ArgoCD namespaces đã tạo
   kubectl get namespace | grep -E 'dev|staging|developer'
   dev, staging, developer ✅
```

---

## LƯU Ý QUAN TRỌNG

1. **Thứ tự cài đặt:** Làm đúng thứ tự. ArgoCD cần namespaces đã tồn tại trước khi sync.

2. **Webhook secret:** Nếu dùng webhook secret, đảm bảo Jenkins GitHub plugin cũng được cấu hình với secret đó.

3. **`[skip ci]` trong commit message:** Không bao giờ xóa tag này — nó ngăn Jenkins CI chạy vòng lặp vô hạn.

4. **Trên Windows:** Tất cả lệnh `kubectl`, `helm`, `argocd` chạy trong PowerShell hoặc Git Bash. Docker commands cần Docker Desktop đang chạy.

5. **Lấy Worker Node IP:**
   ```bash
   # Minikube
   minikube ip

   # Kind
   kubectl get nodes -o wide

   # Production K8s
   kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}'
   ```

6. **File hosts (Windows):**
   ```
   C:\Windows\System32\drivers\etc\hosts

   # Thêm dòng:
   <WORKER-IP>  storefront.yas.local.com
   <WORKER-IP>  backoffice.yas.local.com
   <WORKER-IP>  argocd.yas.local.com
   ```

7. **Rollback nếu cần:**
   ```bash
   # ArgoCD rollback
   argocd app rollback yas-dev-all-services

   # Helm rollback
   helm rollback cart -n dev
   ```
