# NovaPay - DevOps Agent Release Readiness Standards (plain English)
- BLOCK any change to token parsing in payment-service unless a backward-compatible
  contract test is included (root cause of the March incident).
- BLOCK any change that opens a security group to 0.0.0.0/0 or deletes a NetworkPolicy.
- BLOCK changes touching card data (PAN, CVV) that remove encryption at rest or in transit.
- WARN (do not block) if a new service lacks a CloudWatch alarm or structured logging.
- Check cross-repository dependencies: a change must not break a downstream consumer.
