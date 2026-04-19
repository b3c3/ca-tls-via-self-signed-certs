# ca-tls-via-self-signed-certs
Implementing TLS via Self Signed Certificates in AWS

## Summary

This repository contains a hands-on lab for learning TLS by creating a private Root Certificate Authority (CA), issuing a server certificate, deploying it on Apache in Amazon EC2, observing trust warnings, and then resolving those warnings by importing the CA trust anchor.

The lab content is designed for step-by-step learning:

- Main guide: `lab-guide-tls-via-self-signed-certificates.md`
- Reusable config templates: `templates/`
- Interactive config bootstrap script: `scripts/init-cert-config.sh`

OpenSSL commands in the guide use descriptive **kebab-case** filenames and **`.pem`** for PEM-encoded keys and certificates (for example `root-ca-cert.pem`, `server-private-key.pem`, `server-cert.pem`) so material is easy to tell apart and matches common tooling defaults.

This is intended for lab/internal training environments, not public production certificate management.