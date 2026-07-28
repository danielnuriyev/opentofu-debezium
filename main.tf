terraform {
  required_version = ">= 1.12.5"

  backend "local" {
    path = ".terraform.tfstate"
  }

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3.0"
    }
  }
}

locals {
  kubeconfig     = "${path.module}/../opentofu-kind/.kubeconfig"
  connector_name = "mongodb-local-test"
  connector_file = "${path.module}/connector.json"
}

resource "null_resource" "debezium" {
  triggers = {
    manifest       = filemd5("${path.module}/debezium.yaml")
    connector      = filemd5(local.connector_file)
    kubeconfig     = local.kubeconfig
    manifest_path  = "${path.module}/debezium.yaml"
    connector_path = local.connector_file
    connector_name = local.connector_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      test -f "${local.kubeconfig}" || { echo "Kubeconfig not found. Run tofu apply in opentofu-kind first."; exit 1; }
      kubectl --kubeconfig="${local.kubeconfig}" get namespace minio >/dev/null || { echo "MinIO namespace not found. Run tofu apply in opentofu-minio first."; exit 1; }
      kubectl --kubeconfig="${local.kubeconfig}" get namespace mongodb >/dev/null || { echo "MongoDB namespace not found. Run tofu apply in opentofu-mongodb first."; exit 1; }
      kubectl --kubeconfig="${local.kubeconfig}" get namespace kafka >/dev/null || { echo "Kafka namespace not found. Run tofu apply in opentofu-kafka first."; exit 1; }
      kubectl --kubeconfig="${local.kubeconfig}" get crd servicemonitors.monitoring.coreos.com >/dev/null || {
        echo "ServiceMonitor CRD not found. Run tofu apply in opentofu-monitoring first."
        exit 1
      }

      primary_ready=false
      for i in $(seq 1 60); do
        if kubectl --kubeconfig="${local.kubeconfig}" exec -n mongodb mongodb-0 -c mongodb -- mongosh -u root -p example --authenticationDatabase admin --quiet --eval 'rs.status().members.some(m => m.stateStr === "PRIMARY")' 2>/dev/null | grep -q true; then
          echo "mongodb replica set primary ready"
          primary_ready=true
          break
        fi
        sleep 2
      done
      if [ "$primary_ready" != true ]; then
        echo "MongoDB replica set primary did not become ready"
        exit 1
      fi

      kubectl --kubeconfig="${local.kubeconfig}" wait --for=delete namespace/debezium --timeout=120s 2>/dev/null || true
      kubectl --kubeconfig="${local.kubeconfig}" apply -f "${path.module}/debezium.yaml"
      kubectl --kubeconfig="${local.kubeconfig}" wait --for=condition=ready pod -l app=debezium-connect -n debezium --timeout=300s

      PF_PID=""
      trap 'if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi' EXIT
      connect_ready=false
      for i in $(seq 1 30); do
        kubectl --kubeconfig="${local.kubeconfig}" port-forward -n debezium svc/debezium-connect 8081:8083 >/tmp/debezium-pf.log 2>&1 &
        PF_PID=$!
        for j in $(seq 1 10); do
          if curl -sf http://127.0.0.1:8081/ >/dev/null; then
            echo "debezium connect api ready"
            connect_ready=true
            break 2
          fi
          kill -0 "$PF_PID" 2>/dev/null || break
          sleep 1
        done
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
        PF_PID=""
        sleep 1
      done
      if [ "$connect_ready" != true ]; then
        echo "Debezium Connect REST API did not become ready"
        exit 1
      fi

      if curl -sf "http://127.0.0.1:8081/connectors/${local.connector_name}" >/dev/null; then
        curl -sf -X PUT -H "Content-Type: application/json" \
          --data "$(python3 -c 'import json; print(json.dumps(json.load(open("${local.connector_file}"))["config"]))')" \
          "http://127.0.0.1:8081/connectors/${local.connector_name}/config"
        echo "connector updated"
      else
        curl -sf -X POST -H "Content-Type: application/json" \
          --data "@${local.connector_file}" \
          "http://127.0.0.1:8081/connectors"
        echo "connector created"
      fi

      connector_ready=false
      for i in $(seq 1 60); do
        connector_state=$(curl -sf "http://127.0.0.1:8081/connectors/${local.connector_name}/status" | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('tasks') or []; print(d['connector']['state'], t[0]['state'] if t else 'NONE')")
        echo "connector status: $connector_state"
        if [ "$connector_state" = "RUNNING RUNNING" ]; then
          echo "connector ready"
          connector_ready=true
          break
        fi
        sleep 3
      done
      if [ "$connector_ready" != true ]; then
        echo "Debezium connector did not become RUNNING"
        exit 1
      fi

      debezium_targets_up=false
      for i in $(seq 1 36); do
        if kubectl --kubeconfig="${local.kubeconfig}" exec -n monitoring \
          prometheus-kube-prometheus-prometheus-0 -c prometheus -- \
          wget -qO- 'http://localhost:9090/api/v1/query?query=up{service="debezium-connect"}' 2>/dev/null \
          | grep -q '"value":\[.*,"1"\]'; then
          echo "debezium-connect prometheus target up"
          debezium_targets_up=true
          break
        fi
        sleep 5
      done
      if [ "$debezium_targets_up" != true ]; then
        echo "Debezium Connect Prometheus target did not become ready (check Prometheus targets UI)"
        exit 1
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl --kubeconfig="${self.triggers.kubeconfig}" delete -f "${self.triggers.manifest_path}" --ignore-not-found --wait=false
    EOT
  }
}
