#!/bin/bash
set -x

echo "🚀 Bắt đầu cài đặt Hạ tầng (Bản Lite cho Đồ án DevOps)..."

# 1. Thêm chart repo (Chỉ giữ lại PostgreSQL)
helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator
helm repo update

# 2. Đọc cấu hình từ cluster-config.yaml (Chỉ đọc các biến của Postgres)
read -rd '' DOMAIN POSTGRESQL_REPLICAS POSTGRESQL_USERNAME POSTGRESQL_PASSWORD \
< <(yq -r '.domain, .postgresql.replicas, .postgresql.username, .postgresql.password' ./cluster-config.yaml)

echo "📦 Đang cài đặt Postgres Operator..."
helm upgrade --install postgres-operator postgres-operator-charts/postgres-operator \
 --create-namespace --namespace postgres

echo "🗄️ Đang cài đặt PostgreSQL Cluster..."
helm upgrade --install postgres ./postgres/postgresql \
--create-namespace --namespace postgres \
--set replicas="$POSTGRESQL_REPLICAS" \
--set username="$POSTGRESQL_USERNAME" \
--set password="$POSTGRESQL_PASSWORD"

echo "🐘 Đang cài đặt pgAdmin (Giao diện quản lý DB)..."
pg_admin_hostname="pgadmin.$DOMAIN" yq -i '.hostname=env(pg_admin_hostname)' ./postgres/pgadmin/values.yaml
helm upgrade --install pgadmin ./postgres/pgadmin \
--create-namespace --namespace postgres

echo "✅ Cài đặt Hạ tầng (Lite) hoàn tất! Tiết kiệm thành công ~10GB RAM."