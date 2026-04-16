# Lab Guide: TLS via a Private Self-Signed CA

## Document Metadata

- Owner: CIL Academy
- Contact: [team@cil.acdemy](mailto:team@cil.acdemy)
- Classification: Internal
- Version: v16Apr2026T0849BST

## Purpose

This guide shows how to:

1. Create a private Certificate Authority (CA).
2. Issue a TLS certificate for a server using that CA.
3. Configure Apache on Amazon Linux (EC2) to serve HTTPS.
4. Trust the CA on client machines so browsers stop issuing warnings.

Use this for lab and internal environments only. Do not use a private self-signed CA for public internet production traffic.

---

## Part 1: Generate CA and Server Certificates

### Prerequisites

- OpenSSL installed (`openssl version -a`)
- A working shell with sudo access where required
- A hostname/IP you will actually use to access the server (must match SAN)
- Template files available in `templates/`

### Recommended Template Workflow

Use one of these options before generating the CSR:

- Start from placeholders:
  - `cp templates/server.csr.cnf.template server.csr.cnf`
  - `cp templates/server_v3.ext.template server_v3.ext`
- Start from a pre-filled EC2-style example:
  - `cp templates/server.csr.cnf.example server.csr.cnf`
  - `cp templates/server_v3.ext.example server_v3.ext`

Then edit values so `CN` and SAN entries match your real DNS/IP.

If you prefer an interactive setup, run:

```bash
./scripts/init-cert-config.sh
```

### 1) Check OpenSSL

```bash
openssl version -a
```

### 2) Create the CA private key

```bash
openssl genrsa -out privkey.pem 2048
chmod 600 privkey.pem
```

### 3) Create the CA certificate

```bash
openssl req -new -x509 -days 3650 -sha256 -key privkey.pem -out ca.pem
```

When prompted, set a clear CA Common Name (for example, `Lab Root CA`).

In this lab, this first CA certificate is your **Root CA** (Root Certificate Authority): it signs server certificates directly and becomes the trust anchor you import on clients.

### 4) Create CSR config for server identity

Create or edit `server.csr.cnf`:

```ini
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
C = US
ST = StateName
L = CityName
O = OrganizationName
OU = DepartmentName
emailAddress = admin@example.com
CN = your-domain-or-ip
```

Replace `your-domain-or-ip` with your real DNS name or IP.

### 5) Generate server key + CSR

```bash
openssl req -new -nodes -out server.csr -keyout server.key -config server.csr.cnf
chmod 600 server.key
```

### 6) Create certificate extensions (SAN)

Create or edit `server_v3.ext`:

```ini
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = your-domain.example.com
IP.1 = 1.2.3.4
```

Set SAN values to what clients will use in the URL. Add/remove `DNS.n` and `IP.n` entries as needed.

### 7) Sign the server certificate with your CA

```bash
openssl x509 -req -in server.csr -CA ca.pem -CAkey privkey.pem -CAcreateserial -out server.crt -days 825 -sha256 -extfile server_v3.ext
```

### 8) Verify the issued certificate

```bash
openssl x509 -in server.crt -noout -text
```

Confirm:

- `Issuer` is your CA.
- `X509v3 Subject Alternative Name` includes the correct DNS/IP.
- `Basic Constraints: CA:FALSE`.

---

## Part 2: Deploy the Self-Signed TLS Certificate on Amazon EC2 (Apache on Amazon Linux)

### 1) Open inbound HTTPS in Security Group

- Protocol: TCP
- Port: `443`
- Source: your test IP (preferred) or `0.0.0.0/0` for broad access

### 2) Install Apache SSL module

For Amazon Linux 2 / Amazon Linux 2023:

```bash
sudo dnf install -y mod_ssl || sudo yum install -y mod_ssl
```

### 3) Copy certificate files to the right location on the EC2 instance and set the correct permissions

```bash
sudo cp server.crt /etc/pki/tls/certs/server.crt
sudo cp server.key /etc/pki/tls/private/server.key
sudo chown root:root /etc/pki/tls/private/server.key
sudo chmod 600 /etc/pki/tls/private/server.key
```

### 4) Configure Apache TLS settings

Edit:

```bash
sudo nano /etc/httpd/conf.d/ssl.conf
```

Set:

```apache
SSLCertificateFile /etc/pki/tls/certs/server.crt
SSLCertificateKeyFile /etc/pki/tls/private/server.key
```

### 5) Validate and restart Apache

```bash
sudo apachectl configtest
sudo systemctl restart httpd
sudo systemctl status httpd --no-pager
```

### 6) Test HTTPS

```bash
curl -vI --insecure https://localhost
```

At this stage, browser warnings or `curl` trust warnings are expected because your CA certificate (`ca.pem`) is not trusted on client machines yet.

`--insecure` is used here to confirm TLS is working before client trust is configured.

---

## Part 3: Trust Your Private CA on Client Machines

Now return to trust setup and remove the warnings.

### Linux (Ubuntu / Debian)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates
sudo cp ca.pem /usr/local/share/ca-certificates/my_private_ca.crt
sudo update-ca-certificates
```

### Amazon Linux / RHEL / CentOS

```bash
sudo cp ca.pem /etc/pki/ca-trust/source/anchors/my_private_ca.crt
sudo update-ca-trust extract
```

### Windows (PowerShell as Administrator)

```powershell
certutil.exe -addstore Root ca.pem
```

### Firefox

Firefox may use its own trust store:

1. `Settings` -> `Privacy & Security`
2. `Certificates` -> `View Certificates`
3. `Authorities` -> `Import`
4. Select `ca.pem`, then enable trust for websites

After trust import, test again:

```bash
curl -vI https://localhost --cacert ca.pem
```

You should no longer need `--insecure` when trust is configured correctly.

---

## Optional: Force HTTP -> HTTPS Redirect

Important security group requirement:

- Keep inbound `443` open as configured in Part 2, Step 1.
- Also open inbound `80` (HTTP), otherwise clients cannot reach port 80 to receive the redirect response.

Recommended inbound rules for this optional section:

- HTTPS: TCP `443`
- HTTP: TCP `80`
- Source: your test IP (preferred) or `0.0.0.0/0` for broader access

Create `/etc/httpd/conf.d/redirect.conf`:

```apache
<VirtualHost *:80>
    ServerName your-domain-or-ip
    Redirect permanent / https://your-domain-or-ip/
</VirtualHost>
```

Apply:

```bash
sudo apachectl configtest
sudo systemctl restart httpd
curl -I http://your-domain-or-ip
```

Expected response includes `HTTP/1.1 301` and a `Location: https://...` header.

---

## Final Checklist

- Keep private files secret: `privkey.pem` and `server.key`.
- Share only public files: `ca.pem` (for trust) and `server.crt` (server cert).
- If hostname/IP changes, reissue `server.crt` with updated SAN.
- If CA private key is compromised, revoke trust and rebuild everything.

---

## Addendum: Lab Debrief

This lab intentionally uses a private self-signed root CA (Certificate Authority) to demonstrate how TLS works end to end.

Why warnings appeared earlier:

- Browsers and operating systems do not trust your private lab CA by default.
- The certificate can still encrypt traffic, but identity is untrusted until you import the CA.

How production differs:

- In the real-world public deployments, certificates are typically issued by public CAs that are already trusted by browsers.
- That avoids browser trust warnings for users.
- For training labs, creating your own CA is faster and lower cost than obtaining and managing publicly trusted certificates.


End-of-Lab
---