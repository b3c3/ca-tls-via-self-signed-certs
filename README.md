# ca-tls-via-self-signed-certs
Implementing TLS via Self Signed Certificates in AWS

## Summary

This repository contains a hands-on lab for learning TLS by creating a private Root Certificate Authority (CA), issuing a server certificate, deploying it on Apache in Amazon EC2, observing trust warnings, and then resolving those warnings by importing the CA trust anchor.

The lab content is designed for step-by-step learning:

- Main guide: `lab-guide-tls-via-self-signed-certificates.md`
- Reusable config templates: `templates/`
- Interactive config bootstrap script: `scripts/init-cert-config.sh`

OpenSSL commands in the guide use descriptive **kebab-case** filenames (for example `root-ca-cert.pem`, `server-private-key.pem`, `server-cert.crt`) so keys and certificates are easy to tell apart.

This is intended for lab/internal training environments, not public production certificate management.