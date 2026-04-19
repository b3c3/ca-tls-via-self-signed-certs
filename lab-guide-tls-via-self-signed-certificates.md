# Lab Guide: TLS via a Private Self-Signed CA

## Document Metadata

- Owner: CIL Academy
- Contact: [team@cil.acdemy](mailto:team@cil.acdemy)
- Classification: Internal
- Version: v17Apr2026T1200BST

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

**File naming in this lab:** use descriptive **kebab-case** names and the **`.pem` extension** for PEM-encoded keys and certificates (what OpenSSL outputs by default).    
The table below lists each file and its role; Part 2 also explains how this relates to Apache (httpd).

### Files used in this lab (reference)

| File | Description |
|------|-------------|
| `templates/server.csr.cnf.template` | Source template for OpenSSL **CSR settings** (DN, key size, etc.). <br/> - Copy to `server.csr.cnf` and use as the CSR config file. <br/> - Alternatively, you can use the `scripts/init-cert-config.sh` script to generate the CSR config file based on this template. <br/> - **Note:** The CSR config file is used to generate the server's private key and CSR in [Step 5](#5-generate-server-private-key--certificate-signing-request-csr). |
| `templates/server_v3.ext.template` | Source template for **X.509 extensions** (SAN, key usage, etc.). <br/> - Copy to `server_v3.ext` and use as the extension config file. <br/> - Alternatively, you can also use the `scripts/init-cert-config.sh` script to generate the extension config file based on this template. <br/> - **Note:** The X.509 extension file is used to generate the server's certificate in [Step 7](#7-sign-the-server-certificate-with-your-ca). |
| `server.csr.cnf` | The CSR config OpenSSL reads when generating `server.csr` and `server-private-key.pem`. |
| `server_v3.ext` | Extension file passed to `openssl x509` when the CA signs the server certificate (SANs must match what clients use in the URL). |
| `root-ca-private-key.pem` | **Root CA private key.** Signs CSRs; proves CA authority. **Secret** — protect like any signing key. |
| `root-ca-cert.pem` | **Root CA certificate** (public). Your trust anchor; safe to copy to clients so they trust certificates issued by this CA. |
| `root-ca-cert.srl` | **CA serial number file** OpenSSL uses when signing (may appear after the first `x509 -req` sign). Tracks issued serials for this CA. |
| `server.csr` | **Certificate Signing Request** (PEM). Contains the server’s public key and subject; intermediate artifact for the signing step. |
| `server-private-key.pem` | **Server TLS private key** for the endpoint (e.g. Apache httpd). **Secret** — restrict permissions (`600`). |
| `server-cert.pem` | **Server (leaf) certificate** (PEM), signed by the Root CA. Public; referenced by Apache `SSLCertificateFile`. |

### Recommended Template Workflow
The following steps will guide you through the process of generating the Root CA and Server certificates.

### 1) Check OpenSSL

```bash
openssl version -a
```

### 2) Create the CA private key

```bash
openssl genrsa -out root-ca-private-key.pem 2048
```

Restrict the CA private key permissions to 600. This makes the file private so that only the owner can read and write to it.

```bash
chmod 600 root-ca-private-key.pem
```

### 3) Create the CA certificate

```bash
openssl req -new -x509 -days 3650 -sha256 -key root-ca-private-key.pem -out root-ca-cert.pem
```

When prompted, set a clear CA Common Name (for example, `Lab Root CA`).

In this lab, this first CA certificate is your **Root CA** (Root Certificate Authority): it signs server certificates directly and becomes the trust anchor you import on clients.

### 4) Create the Configuration Files required for the Server Certificate
Copy the bundled templates to the repo root or a folder of your choice (they come with sample EC2-style values; replace anything that does not match your server):

- `cp templates/server.csr.cnf.template server.csr.cnf`
- `cp templates/server_v3.ext.template server_v3.ext`

Then edit values so `CN` and SAN entries match your real DNS/IP.

Alternatively, instead of a manual copy + paste + edit, you can use the `scripts/init-cert-config.sh` script to generate the CSR config file and extension config file based on the templates as described in the table above. This script provides an interactive approach that copies the templates, shows the distinguished name fields from the CSR template (with an option to update each value), then walks you through steps to add DNS/IP and Subject Alternative Names:

```bash
./scripts/init-cert-config.sh
```

### 5) Create CSR config for server identity

Review the `server.csr.cnf` file created in the previous step to ensure the values are set correctly:

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

### 6) Generate Server Private Key and Certificate Signing Request (CSR)

```bash
openssl req -new -nodes -out server.csr -keyout server-private-key.pem -config server.csr.cnf
```

Restrict the server private key permissions to 600. This makes the file private so that only the owner can read and write to it.

```bash
chmod 600 server-private-key.pem
```

### 7) Create or Review Server Certificate Extensions (SAN) Configuration File

Certificate extensions are additional data fields that define extra features or constraints for a certificate, such as the Subject Alternative Name (SAN) for securing multiple domains.    
For more information, you can explore the technical documentation on certificate configurations online (https://docs.openssl.org/3.6/man5/x509v3_config/#subject-alternative-name).    

Create or review the `server_v3.ext` file created in Step 4 to ensure the values are set correctly:

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

### 8) Sign the server certificate with your CA (Root CA in our case)

```bash
openssl x509 -req \
  -in server.csr \
  -CA root-ca-cert.pem \
  -CAkey root-ca-private-key.pem \
  -CAcreateserial \
  -out server-cert.pem \
  -days 825 \
  -sha256 \
  -extfile server_v3.ext
```

### 9) Verify the issued certificate

```bash
openssl x509 -in server-cert.pem -noout -text
```

Confirm the following:

- `Issuer` is your CA.
- `X509v3 Subject Alternative Name` includes the correct DNS/IP.
- `Basic Constraints: CA:FALSE`.

**Note:** `CA:FALSE` means **Basic Constraints** marks this as a **leaf (end-entity)** certificate: it must not be used to issue other certificates. In this lab, that leaf cert is your **TLS server** (HTTPS endpoint). `CA:TRUE` appears on **CA certificates** (Root or Intermediate) that **sign** other certs in the chain—the flag means “may act as a CA,” not that the cert is “for securing the CA” as a web server.

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
sudo cp server-cert.pem /etc/pki/tls/certs/server-cert.pem
sudo cp server-private-key.pem /etc/pki/tls/private/server-private-key.pem
sudo chown root:root /etc/pki/tls/private/server-private-key.pem
sudo chmod 600 /etc/pki/tls/private/server-private-key.pem
```

### 4) Configure Apache TLS settings

Edit:

```bash
sudo nano /etc/httpd/conf.d/ssl.conf
```

Set:

```apache
SSLCertificateFile /etc/pki/tls/certs/server-cert.pem
SSLCertificateKeyFile /etc/pki/tls/private/server-private-key.pem
```

**Knowledge (PEM content vs filename extension):** What matters for Apache on Amazon Linux is the **file content** — PEM text that begins with lines such as `-----BEGIN CERTIFICATE-----` or `-----BEGIN PRIVATE KEY-----` — not whether the filename ends in `.crt` or `.pem`. Both extensions are used in the wild; **httpd** will serve TLS correctly with either as long as you point `SSLCertificateFile` at a PEM-encoded certificate and `SSLCertificateKeyFile` at the matching PEM-encoded private key. This lab standardizes on `.pem` for consistency with OpenSSL defaults and the Root CA filenames above.

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

At this stage, browser warnings or `curl` trust warnings are expected because your Root CA certificate (`root-ca-cert.pem`) is not trusted on client machines yet.

`--insecure` is used here to confirm TLS is working before client trust is configured.

---

## Part 3: Trust Your Private CA on Client Machines

Now return to trust setup and remove the warnings.

Some steps below copy `root-ca-cert.pem` into a system trust directory where the **destination filename** may end in `.crt` (for example `my_private_ca.crt`). That matches how those distributions expect trust anchors to be installed; the **content** is still the same PEM-encoded CA certificate as `root-ca-cert.pem`.

### Linux (Ubuntu / Debian)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates
sudo cp root-ca-cert.pem /usr/local/share/ca-certificates/my_private_ca.crt
sudo update-ca-certificates
```

### Amazon Linux / RHEL / CentOS

```bash
sudo cp root-ca-cert.pem /etc/pki/ca-trust/source/anchors/my_private_ca.crt
sudo update-ca-trust extract
```

### Windows (PowerShell as Administrator)

```powershell
certutil.exe -addstore Root root-ca-cert.pem
```

### Firefox

Firefox may use its own trust store:

1. `Settings` -> `Privacy & Security`
2. `Certificates` -> `View Certificates`
3. `Authorities` -> `Import`
4. Select `root-ca-cert.pem`, then enable trust for websites

After trust import, test again:

```bash
curl -vI https://localhost --cacert root-ca-cert.pem
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

- Use the **Files used in this lab (reference)** table in Part 1 if you need a quick reminder of what each file is for.
- Keep private files secret: `root-ca-private-key.pem` and `server-private-key.pem`.
- Share only public files: `root-ca-cert.pem` (for trust) and `server-cert.pem` (server certificate).
- If hostname/IP changes, reissue `server-cert.pem` with updated SAN.
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