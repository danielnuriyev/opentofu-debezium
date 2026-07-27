# Debezium on Kind (OpenTofu)

Deploys [Debezium Connect](https://debezium.io/) on the Kind cluster and streams new documents from MongoDB `dev.test` into the Kafka `test` topic.

> **Note:** MongoDB reserves the internal `local` database (oplog, replica set metadata). Change streams — and therefore Debezium — cannot CDC from `local.*`. The test senders use `dev.test` instead.

## What it does

- Creates a `debezium` namespace on the Kind cluster
- Runs Kafka Connect with Debezium (`quay.io/debezium/connect:3.1.3.Final`)
- Registers a MongoDB connector for `dev.test` → Kafka topic `test`
- Captures existing documents via initial snapshot, then streams inserts/updates/deletes

## Prerequisites

Deploy these first (in order):

1. [opentofu-kind](https://github.com/danielnuriyev/opentofu-kind) — Kind cluster
2. [opentofu-mongodb](https://github.com/danielnuriyev/opentofu-mongodb) — MongoDB as a single-node replica set (`rs0`)
3. [opentofu-kafka](https://github.com/danielnuriyev/opentofu-kafka) — Kafka broker

MongoDB must run as a replica set for Debezium change streams. `opentofu-mongodb` configures `--replSet rs0` and initializes the replica set on apply.

> **Database name:** Use `dev.test`, not `local.test`. MongoDB reserves the internal `local` database and change streams cannot run on it.

## Deploy

```bash
tofu init
tofu apply
```

## Verify

Check Debezium Connect and connector status:

```bash
export KUBECONFIG=../opentofu-kind/.kubeconfig
kubectl get pods -n debezium

kubectl port-forward -n debezium svc/debezium-connect 8081:8083
curl http://localhost:8081/connectors/mongodb-local-test/status
```

Insert a document into MongoDB:

```bash
kubectl exec -n mongodb deploy/mongodb -- mongosh \
  "mongodb://root:example@localhost:27017/dev?authSource=admin&replicaSet=rs0&retryWrites=false" \
  --eval 'db.test.insertOne({source: "debezium-verify", ts: new Date()})'
```

Read the change event from Kafka:

```bash
kubectl exec -n kafka deploy/kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic test \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 30000
```

You should see a Debezium JSON envelope with the document in the `payload.after` field.

## Pipeline

```text
MongoDB dev.test  →  Debezium MongoDB connector  →  Kafka topic test
(replica set rs0)      (change streams + snapshot)
```

If you redeploy Kafka (`opentofu-kafka`), Debezium's internal Connect topics are wiped. Re-register the connector:

```bash
tofu apply -replace=null_resource.debezium
```

## Cleanup

```bash
tofu destroy   # removes Debezium Connect and the connector deployment
```

MongoDB, Kafka, and the Kind cluster are managed separately.

## Files

| File | Purpose |
|------|---------|
| `main.tf` | Deploy Connect, register MongoDB connector |
| `debezium.yaml` | Debezium Connect Kubernetes manifest |
| `connector.json` | MongoDB → Kafka connector configuration |
| `outputs.tf` | Connect URL, topic name, verify commands |
