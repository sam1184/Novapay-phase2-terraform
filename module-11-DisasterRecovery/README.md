# NovaPay Module 11 — Disaster Recovery with Velero

A real DR drill for NovaPay on EKS. It backs up a namespace **including persistent
volume data** to S3, destroys the namespace for real, restores it, and proves the
data came back byte-for-byte. No synthetic data – a real workload writes real
records, and we checksum them before and after.

## What this demonstrates

Velero is the standard tool for Kubernetes backup/restore and DR. It backs up:
- **Kubernetes objects** (Deployments, Services, ConfigMaps, PVCs, etc.) to S3
- **Persistent volume data** – either via EBS snapshots or, as configured here,
  filesystem-level backup with the node-agent (Kopia), which also lands in S3

The drill runs the core DR mechanic: **back up → lose everything → restore → verify.**

## Files

| File | Purpose |
|------|---------|
| `main.tf` | VPC + EKS + **EBS CSI driver** (for real volumes) + S3 backup bucket + Velero/EBS-CSI IAM (Pod Identity) |
| `post-cluster.sh` | Installs Velero (Pod Identity auth, node-agent on), gp3 StorageClass, NovaPay services, and a stateful `ledger` with a real PVC |
| `module-11-demo.sh` | The DR drill: 7 parts, write data → backup → delete namespace → restore → verify checksum |
| `teardown.sh` | Cleanup (deletes backups, releases the volume, then `terraform destroy`) |

## Prerequisites

- AWS account + credentials configured (needs EKS, EC2, S3, IAM permissions)
- Terraform ≥ 1.5, `kubectl`, `curl` (the script installs the `velero` CLI if missing)

## Quick start

```bash
cd dr-velero-lab
terraform init
terraform apply                # ~14 min  (EKS + EBS CSI + S3 bucket + IAM)
bash post-cluster.sh           # ~5 min   (Velero + NovaPay + stateful ledger)
bash module-11-demo.sh         # the DR drill (add --auto for CI)
bash teardown.sh                # cleanup
```

## The drill, step by step

| Part | What happens |
|------|--------------|
| A | Confirm Velero is healthy and the S3 BackupStorageLocation is `Available` |
| B | Write 500 real transaction records to the ledger volume; record count + md5 |
| C | `velero backup create` the whole namespace incl. the PV data → S3 |
| D | **Disaster:** delete the namespace – pods, PVC, and the EBS volume are destroyed |
| E | `velero restore create` from the backup; measure RTO |
| F | Verify namespace, deployments, PVC, ConfigMap, **and** the ledger data (md5 must match → zero data loss) |
| G | Create a recurring backup `Schedule` (RPO) and explain cross-region/cross-cluster DR |

Expected result: `PASSED: 12  FAILED: 0`, with the before/after md5 identical.

## RTO and RPO

- **RTO** (Recovery Time Objective) – how long recovery takes. The drill measures it live (restore + workload ready).
- **RPO** (Recovery Point Objective) – how much data you can lose. It equals your backup frequency. Part G sets an hourly schedule = 1-hour RPO.

## How real DR differs from this lab

This lab restores into the **same cluster** to keep it cheap and fast. Production DR restores into a **different cluster, usually in another Region**:
1. Replicate the S3 backup bucket to the DR Region (S3 replication or a multi-region setup).
2. Stand up a DR EKS cluster there with Velero pointed at the same backups.
3. `velero restore create --from-backup <name>` in the DR cluster.
4. Repoint DNS / Global Accelerator to the DR cluster.

The backup/restore mechanic is identical – only the target cluster changes.

## Notes

- Velero authenticates via **Pod Identity** – no static AWS keys are stored anywhere.
- PV data is backed up at the **filesystem level** (node-agent/Kopia), so it works
  regardless of snapshot class support and lands in the same S3 bucket.
- Idempotent: each `module-11-demo.sh` run uses a fresh, timestamped backup name,
  and ends with the namespace restored – safe to re-run.

## Cost

~$0.35/hour while running (EKS + 2× t3.medium + NAT + a small S3 bucket + one EBS
volume). **Always run `bash teardown.sh` when done.**
