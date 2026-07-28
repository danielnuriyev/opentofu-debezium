output "kubeconfig" {
  description = "Path to the Kind cluster kubeconfig (from opentofu-kind)"
  value       = local.kubeconfig
}

output "connect_url" {
  description = "Debezium Connect REST API (via port-forward to localhost:8081)"
  value       = "http://localhost:8081"
}

output "connector_name" {
  description = "Registered MongoDB connector name"
  value       = local.connector_name
}

output "kafka_topic" {
  description = "Kafka topic receiving MongoDB change events"
  value       = "test"
}

output "verify" {
  description = "Commands to verify MongoDB to Kafka CDC"
  value       = <<-EOT
    export KUBECONFIG=${local.kubeconfig}

    kubectl get pods -n debezium
    kubectl port-forward -n debezium svc/debezium-connect 8081:8083
    curl http://localhost:8081/connectors/${local.connector_name}/status

    # insert a document
    kubectl exec -n mongodb mongodb-0 -- mongosh "mongodb://root:example@localhost:27017/dev?authSource=admin&replicaSet=rs0&retryWrites=false" --eval 'db.test.insertOne({source: "debezium-verify", ts: new Date()})'

    # read from kafka topic test
    kubectl exec -n kafka kafka-0 -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test --from-beginning --max-messages 1 --timeout-ms 30000
  EOT
}
