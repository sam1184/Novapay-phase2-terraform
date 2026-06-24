# Module 12 — Manual Validation Runbook

Run these one at a time. Each step says what it does and what to expect.
The recommended sequence is how you understand the stack instead of guessing
— doubles as troubleshooting when something "isn't accessible."

---

## 0. Make sure your AWS credentials are fresh (the #1 cause of failures)

Your session creds are short-lived. When `kubectl` says "you must be logged in
to the server" or a port-forward dies, it's almost always expired creds. Refresh:

```bash
# Refresh the ada session into the default profile that kubectl/aws read:
CREDS=$(ada credentials print --account 390402549817 --role Admin --provider isengard)
printf "[default]\naws_access_key_id=%s\naws_secret_access_key=%s\naws_session_token=%s\n" \
  "$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')" \
  "$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')" \
  "$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')" \
  > ~/.aws/credentials
```

Check which profile is active and who you are:

```bash
aws configure list         # profile should be <not set> => using [default]
aws sts get-caller-identity  # should show .../Admin/sachitri-Isengard, account 390402549817
```

---

## 1. Can you reach the cluster?

What it does: confirms `kubectl` + creds can talk to the EKS API.

```bash
kubectl get nodes -L node.kubernetes.io/instance-type
```

Expect: 3 nodes Ready — two `t3.*` (system) and one `inf2.xlarge` (the accelerator).
If you get "must be logged in" → go back to step 0.

---

## 2. Is the accelerator actually usable by Kubernetes?

What it does: confirms the Neuron device plugin exposed the chip as a schedulable
resource. Without this, the model pod can't get hardware.

```bash
# the device plugin pod:
kubectl get ds neuron-device-plugin -n kube-system

# the node advertising a neuron device:
kubectl get nodes -l neuron.amazonaws.com/neuron-device=true \
  -o jsonpath='{.items[0].status.allocatable.aws\.amazon\.com/neuron}{"\n"}'
```

Expect: device plugin `1/1` ready, and allocatable neuron = `1`.

---

## 3. Is the model running and on the right node?

```bash
kubectl get pods -n vllm -o wide
```

Expect: `mistral-...` pod `1/1 Running`, on the `inf2.xlarge` node (the IP that
matches the inf2 node from step 1).

See it serving in its own logs:

```bash
kubectl logs deploy/mistral -n vllm -c vllm | tail -20
```

Expect: lines ending around `Application startup complete` and `GET /health 200 OK`.

---

## 4. Does the model answer? (in-cluster, no port-forward needed)

What it does: calls the OpenAI-style API from a throwaway pod INSIDE the cluster.
This is the real proof of inference, and it also demonstrates data residency —
the prompt never leaves the cluster.

List the served model:

```bash
kubectl run q --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n vllm -- \
  curl -s http://mistral.vllm:8080/v1/models
```

Expect: JSON listing model id `/models/mistral-7b-v0.3`.

Ask it a real question:

```bash
kubectl run q --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n vllm -- \
  curl -s http://mistral.vllm:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"/models/mistral-7b-v0.3","messages":[{"role":"user","content":"In one sentence, what is a chargeback?"}],"max_tokens":60}'
```

Expect: a JSON response whose `choices[0].message.content` is a real sentence.
(First call after the pod has been idle can take 10–30s.)

Try the lesson question — ask about something only NovaPay would know:

```bash
kubectl run q --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n vllm -- \
  curl -s http://mistral.vllm:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"/models/mistral-7b-v0.3","messages":[{"role":"user","content":"What is NovaPay'\''s refund policy?"}],"max_tokens":60}'
```

Expect: a confident but MADE-UP answer. That's the key learning — the base model
knows general knowledge but nothing about your business. (This is what RAG fixes.)

---

## 5. Confirm data residency (the banking point)

```bash
kubectl get svc mistral -n vllm
```

Expect: `TYPE = ClusterIP`, `EXTERNAL-IP = <none>`. No public endpoint → prompts
stay inside the VPC.

---

## 6. Open the chat UI

What it does: forwards a local port to the in-cluster UI so you can use it in a
browser. The UI is also ClusterIP (internal); port-forward is a secure local tunnel.

```bash
kubectl port-forward svc/chat-ui -n chatbot 8080:80
```

Leave that running, then open http://localhost:8080 in your browser.
- Pick the `mistral` model, start chatting.
- If the browser shows nothing: the port-forward probably died (expired creds) —
  Ctrl-C it, redo step 0, and run the port-forward again.

Verify the tunnel is actually up (in another terminal):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8080/   # expect HTTP 200
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

---

## 7. Run the graded drill (all of the above, automated)

```bash
bash module-12-demo.sh         # interactive
bash module-12-demo.sh --auto  # no pauses
```

Expect: `PASSED: 9  FAILED: 0`.
