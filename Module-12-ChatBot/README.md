# NovaPay Module 12 — Self-hosted LLM Chatbot on EKS (vLLM + AWS Neuron)

Adapted from the EKS Workshop ("Large Language Models with vLLM"). This module, reframed as NovaPay's customer-support assistant, deploys a self-hosted Mistral-7B served by vLLM on an accelerator node (`inf2.xlarge`), behind a chat UI. The banking context makes the key angle clear: the model runs **inside your VPC**, so customer prompts (which may mention account or payment details) never leave your boundary to a third-party LLM API. The drill proves it with **real inferences** — it asks the model real support questions and checks real answers come back.

> **Cost warning.** This is the most expensive lab. The `inf2.xlarge` node bills at ~**$0.76/hour** on-demand, and the first run pulls a ~10 GB image + model (18–25 min). Run `teardown.sh` as soon as you're done.

---

## What it demonstrates

- Exposing accelerator hardware to Kubernetes with the **Neuron device plugin**
- Placing an expensive model pod on the accelerator with **taints + tolerations**
- Serving an LLM with **vLLM** (PagedAttention, OpenAI-compatible API)
- A **chat UI** (Open WebUI) wired to the model's OpenAI endpoint
- **Data residency** — the model is internal-only (ClusterIP), prompts stay in-VPC
- Scaling and cost thinking for accelerators (cores, tensor-parallel, scale-to-zero)

---

## Files

| File | Purpose |
|---|---|
| `main.tf` | EKS cluster + a system node group + a **Neuron node group** (`inf2.xlarge`, AL2023 Neuron AMI, tainted) + LB controller |
| `post-cluster.sh` | Installs the Neuron device plugin, deploys Mistral-7B on vLLM, and the chat UI |
| `module-12-demo.sh` | The drill: prerequisites → serving → **real inferences** → UI → data residency → scaling |
| `teardown.sh` | Cleanup (deletes workloads, then `terraform destroy`) |
| `chatbot-guide.html` | The teaching guide (open in a browser) |

---

## Prerequisites

- AWS account with **Neuron (`inf2`/`trn1`) capacity** in `us-east-1` and a service quota that allows it (accelerator instances often need a quota increase).
- Terraform ≥ 1.5, `kubectl`, `helm`, `curl`.

---

## Quick start

```bash
cd chatbot-llm-lab
terraform init
terraform apply        # ~16 min (EKS + system + inf2 Neuron node)
bash post-cluster.sh   # ~15 min (Neuron plugin + vLLM + model download + UI)
bash module-12-demo.sh # the drill — runs end-to-end
```

> **Loads in the background.** If `post-cluster.sh` is still running, watch it and re-run once done:
> ```bash
> kubectl get pod -n vllm -w
> kubectl logs deploy/mistral -n vllm -c vllm -f
> ```

---

## What the drill checks

| Check | Detail |
|---|---|
| Neuron device plugin running | Accelerator node exposes Neuron cores |
| vLLM pod scheduled | LLM healthy; the OpenAI `/v1/models` endpoint lists Mistral |
| Real inferences | Sends NovaPay support questions, verifies real completions return |
| Open WebUI chat UI | UI is running and wired to the model |
| Data residency | Model service is `ClusterIP` — internal only, prompts never leave the VPC |
| Scaling & cost notes | Neuron cores, tensor-parallel, scale-to-zero |

---

## How this maps to / differs from the Workshop

**Core:** Neuron device plugin → accelerator node → Mistral-7B on vLLM → chat UI.

The Workshop provisions the Neuron node with **Karpenter** on demand. This lab uses **managed node groups** with the AL2023 Neuron AMI so it's deterministic and reproducible, skipping the Karpenter scale-to-zero pattern.

The Workshop uses the `retail-store` sample UI; here we use **Open WebUI** so the lab is self-contained.

---

## Teardown & cleanup

Run `teardown.sh` as soon as you're done — it removes workloads via `terraform destroy`.

The `inf2.xlarge` node is the cost driver. Confirm no accelerator instances are still running after teardown — check it, as `inf2` instances are easy to forget and expensive to leave on.
