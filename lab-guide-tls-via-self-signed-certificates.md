# Lab Guide: TLS via a Private Self-Signed CA

## Document Metadata

- Owner: CIL Academy
- Contact: [team@cil.academy](mailto:team@cil.academy)
- Classification: Internal
- Version: v22Apr2026T1921BST

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
The table below lists each file and its role. For how `.pem` and `.crt` relate to Apache `httpd`, see [Dot PEM vs Dot CRT: A Note on Certificate Filename Extensions](#dot-pem-vs-dot-crt-a-note-on-certificate-filename-extensions).

### Files used in this lab

| File | File Location | Description |
|------|---------------|-------------|
| `root-ca-private-key.pem` | `root-ca-tls-items/` | **Root CA private key.** Signs CSRs; proves CA authority. **Secret** — protect like any signing key. |
| `root-ca-cert.pem` | `root-ca-tls-items/` | **Root CA certificate** (public). Your trust anchor; safe to copy to clients so they trust certificates issued by this CA. |
| `root-ca-cert.srl` | `root-ca-tls-items/` | **CA serial number file** OpenSSL uses when signing (may appear after the first `x509 -req` sign). Tracks issued serials for this CA. |
| `server.csr.cnf.template` | `templates/` | Source template for OpenSSL **CSR settings** (DN, key size, etc.). <br/> - Copy to `server-tls-items/server.csr.cnf` and use as the **CSR config file**. <br/> - Alternatively, you can use the `scripts/init-cert-config.sh` script to generate the CSR config file based on this template. <br/> - **Note:** The CSR config file is used to generate the server's private key and CSR in [Step 6](#6-generate-the-server-private-key-and-certificate-signing-request-csr). |
| `server_v3.ext.template` | `templates/` | Source template for **X.509 extensions** (SAN, key usage, etc.). <br/> - Copy to `server-tls-items/server_v3.ext` and use as the X.509 extension config file. <br/> - Alternatively, you can also use the `scripts/init-cert-config.sh` script to generate the extension config file based on this template. <br/> - **Note:** The X.509 extension file is used to generate the server's certificate in [Step 8](#8-sign-the-server-certificate-with-your-ca-root-ca-in-our-case). |
| `server.csr.cnf` | `server-tls-items/` | The CSR config OpenSSL reads when generating `server-tls-items/server.csr` and `server-tls-items/server-private-key.pem`. |
| `server_v3.ext` | `server-tls-items/` | Extension file passed to `openssl x509` when the CA signs the server certificate (SANs must match what clients use in the URL). |
| `server.csr` | `server-tls-items/` | **Certificate Signing Request** (PEM). Contains the server’s public key and subject; intermediate artifact for the signing step. |
| `server-private-key.pem` | `server-tls-items/` | **Server TLS private key** for the endpoint (e.g. Apache httpd). **Secret** — restrict permissions (`600`). |
| `server-cert.pem` | `server-tls-items/` | **Server (leaf) certificate** (PEM), signed by the Root CA. Public; referenced by Apache `SSLCertificateFile`. |

<br/>

### Recommended Template Workflow
The following steps will guide you through the process of generating the Root CA and Server certificates.

### 1) Check OpenSSL

```bash
openssl version -a
```

### 2) Create the CA Private Key

```bash
openssl genrsa -out root-ca-tls-items/root-ca-private-key.pem 2048
```

Restrict the CA private key permissions to 600. This makes the file private so that only the owner can read and write to it.

```bash
chmod 600 root-ca-tls-items/root-ca-private-key.pem
```

### 3) Create the CA Certificate

```bash
openssl req -new -x509 \
  -days 3650 \
  -sha256 \
  -key root-ca-tls-items/root-ca-private-key.pem \
  -out root-ca-tls-items/root-ca-cert.pem
```

| Option / Parameter | Meaning |
|------|-------------|
| `openssl req` | `openssl req` starts the OpenSSL certificate request tool. In this command, it is used together with `-x509` to create a certificate directly. |
| `-new` | The `-new` option tells OpenSSL to create a new request/certificate operation instead of reusing an existing one. |
| `-x509` | The `-x509` option tells OpenSSL to output a self-signed X.509 certificate (your Root CA certificate) rather than only creating a CSR. |
| `-days 3650` | The `-days` option sets how long the certificate is valid. Here, `3650` means 3650 days. |
| `-sha256` | The `-sha256` option tells OpenSSL to use SHA-256 as the signing hash algorithm. |
| `-key root-ca-tls-items/root-ca-private-key.pem` | The `-key` option specifies which private key to use for signing. Here, it uses the Root CA private key file. |
| `-out root-ca-tls-items/root-ca-cert.pem` | The `-out` option specifies the output path for the generated certificate. Here, it writes the Root CA certificate to `root-ca-tls-items/root-ca-cert.pem`. |

When prompted, set a clear CA Common Name (for example, `Lab Root CA`).

In this lab, this first CA certificate is your **Root CA** (Root Certificate Authority): it signs server certificates directly and becomes the trust anchor you import on clients.

### 4) Create the Configuration Files Required for the Server Certificate
You may have noticed that when creating the Root CA items above, you were asked a lot of questions about the CA such a location, state, city, organization, etc.
Instead of answering these questions interactively every time, you can create configuration files to store these values, and simply pass the configuration file to the `openssl req` command.    

For the server certificate, you will need two configuration files:

1. `server.csr.cnf` - Certificate Signing Request (CSR) configuration file
2. `server_v3.ext` - X.509 extensions configuration file

These configuration files are used to provide default values for the CSR and to specify the extensions to be included in the certificate.

<br/>You have two options for generating these files:
- Option A: Manual copy/paste edit
- Option B: Use the bash script provided: `scripts/init-cert-config.sh`

For Option A:
Create the lab artifact directories in the repo root, then copy the bundled templates into `server-tls-items/` (they come with sample EC2-style values; replace anything that does not match your server):

- `mkdir -p server-tls-items root-ca-tls-items`
- `cp templates/server.csr.cnf.template server-tls-items/server.csr.cnf`
- `cp templates/server_v3.ext.template server-tls-items/server_v3.ext`

Then edit values so `CN` and SAN entries match your real DNS/IP.

Alternatively, instead of manual copy/paste/edit steps, you can use the `scripts/init-cert-config.sh` script to generate both configuration files from the templates listed above. The script copies the templates, shows the distinguished name fields from the CSR template (with an option to update each value), then walks you through adding DNS/IP Subject Alternative Names:

```bash
./scripts/init-cert-config.sh
```

### 5) Create CSR Configuration for Server Identity

Review the `server-tls-items/server.csr.cnf` file created in the previous step to ensure the values are set correctly:

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

### 6) Generate the Server Private Key and Certificate Signing Request (CSR)

```bash
openssl req -new -nodes \
  -out server-tls-items/server.csr \
  -keyout server-tls-items/server-private-key.pem \
  -config server-tls-items/server.csr.cnf
```

| Option / Parameter | Meaning |
|------|-------------|
| `openssl req` | `openssl req` starts the OpenSSL certificate request tool. In this step, it is used to generate a server private key and CSR. |
| `-new` | The `-new` option tells OpenSSL to create a brand-new CSR. |
| `-nodes` | The `-nodes` option means "no DES/encryption" for the private key output, so the key is not protected by a passphrase. |
| `-out server-tls-items/server.csr` | The `-out` option specifies the location or path to output the generated CSR file to. In this case, it writes the generated CSR to `server-tls-items/server.csr`. |
| `-keyout server-tls-items/server-private-key.pem` | The `-keyout` option specifies where to save the generated server private key. In this case, it writes the key to `server-tls-items/server-private-key.pem`. |
| `-config server-tls-items/server.csr.cnf` | The `-config` option tells OpenSSL which configuration file to read for subject details and request settings. Here, it reads `server-tls-items/server.csr.cnf`. |

Restrict the server private key permissions to 600. This makes the file private so that only the owner can read and write to it.

```bash
chmod 600 server-tls-items/server-private-key.pem
```

### 7) Create or Review Server Certificate Extensions (SAN) Configuration File

Certificate extensions are additional data fields that define extra features or constraints for a certificate, such as the Subject Alternative Name (SAN) for securing multiple domains.    
For more information, you can explore the technical documentation on certificate configurations online (https://docs.openssl.org/3.6/man5/x509v3_config/#subject-alternative-name).    

Create or review the `server-tls-items/server_v3.ext` file created in Step 4 to ensure the values are set correctly:

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

### 8) Sign the Server Certificate with your CA (Root CA in our case)

```bash
openssl x509 -req \
  -in server-tls-items/server.csr \
  -CA root-ca-tls-items/root-ca-cert.pem \
  -CAkey root-ca-tls-items/root-ca-private-key.pem \
  -CAcreateserial \
  -CAserial root-ca-tls-items/root-ca-cert.srl \
  -out server-tls-items/server-cert.pem \
  -days 825 \
  -sha256 \
  -extfile server-tls-items/server_v3.ext
```

| Option / Parameter | Meaning |
|------|-------------|
| `openssl x509` | `openssl x509` starts the OpenSSL certificate signing/inspection tool. In this step, it signs the server CSR to issue a server certificate. |
| `-req` | The `-req` option tells OpenSSL that the input is a CSR request (not an existing certificate). |
| `-in server-tls-items/server.csr` | The `-in` option specifies the CSR file to read and sign. Here, it reads `server-tls-items/server.csr`. |
| `-CA root-ca-tls-items/root-ca-cert.pem` | The `-CA` option specifies the CA certificate to use as the issuer certificate. Here, it uses your Root CA certificate. |
| `-CAkey root-ca-tls-items/root-ca-private-key.pem` | The `-CAkey` option specifies the CA private key used to sign the server certificate. |
| `-CAcreateserial` | The `-CAcreateserial` option tells OpenSSL to create a serial-number file if it does not exist yet. |
| `-CAserial root-ca-tls-items/root-ca-cert.srl` | The `-CAserial` option specifies the serial-number file OpenSSL should use/manage for issued certificates. |
| `-out server-tls-items/server-cert.pem` | The `-out` option specifies where to save the signed server certificate. Here, it writes to `server-tls-items/server-cert.pem`. |
| `-days 825` | The `-days` option sets the certificate validity period. Here, the server certificate is valid for 825 days. |
| `-sha256` | The `-sha256` option tells OpenSSL to sign using SHA-256. |
| `-extfile server-tls-items/server_v3.ext` | The `-extfile` option points to the extension file (including SAN entries) to include in the issued server certificate. |

- **Note:** You may use any `-days` value you like for this lab (for example `365` for one year or `90` for three months).

The sample command uses **825** because that number often appears in older examples about **public** TLS certificates (the kind issued by well-known CAs that browsers trust by default). Since **September 2020**, major browsers have pushed toward **shorter maximum lifetimes** for **public** certificates—often around **398 days**.   

In this lab, your server certificate is signed by **your private Root CA** (not by a **public** CA), so limits on **public** certificate lifetimes do not apply to your `-days` choice here.    
However, when you work on real **public** sites later, shorter certificate lifetimes help because:

1. **Less time at risk if a certificate is stolen or mis-issued** (smaller window for abuse).
2. **Faster rollout of stronger algorithms** when the industry deprecates older ones (e.g., SHA-1).
3. **Easier renewal at scale** when teams automate with ACME, managed PKI, or similar tools (for example Let’s Encrypt).

### 9) Verify the Issued Certificate

```bash
openssl x509 -in server-tls-items/server-cert.pem -noout -text
```

Confirm the following:

- `Issuer` is your CA.
- `X509v3 Subject Alternative Name` includes the correct DNS/IP.
- `Basic Constraints: CA:FALSE`.

**Note:** `CA:FALSE` means **Basic Constraints** marks this as a **leaf (end-entity)** certificate: it must NOT be used to issue other certificates.
- In this lab, this leaf certificate is used to secure your **TLS server** (HTTPS endpoint) which is the **end-entity**.
- In contrast, `CA:TRUE` usually appears on **CA certificates** (Root or Intermediate) that **sign** other certificates in the chain.

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

### 3) Copy Certificate Files to the Right Locations on the EC2 Instance and Set the Correct Permissions

```bash
sudo cp server-tls-items/server-cert.pem /etc/pki/tls/certs/server-cert.pem
sudo cp server-tls-items/server-private-key.pem /etc/pki/tls/private/server-private-key.pem
sudo chown root:root /etc/pki/tls/private/server-private-key.pem
sudo chmod 600 /etc/pki/tls/private/server-private-key.pem
```

### 4) Configure Apache TLS Settings

Edit:

```bash
sudo nano /etc/httpd/conf.d/ssl.conf
```

Set:

```apache
SSLCertificateFile /etc/pki/tls/certs/server-cert.pem
SSLCertificateKeyFile /etc/pki/tls/private/server-private-key.pem
```

### 5) Validate and Restart Apache

```bash
sudo apachectl configtest
sudo systemctl restart httpd
sudo systemctl status httpd --no-pager
```

### 6) Test HTTPS

```bash
curl -vI --insecure https://localhost
```

At this stage, browser warnings or `curl` trust warnings are expected because your Root CA certificate (`root-ca-tls-items/root-ca-cert.pem`) is not trusted on client machines yet.

`--insecure` is used here to confirm TLS is working before client trust is configured.

---

## Part 3: Trust Your Private CA on Client Machines

As noted in the preceding section, browsers will not trust your private CA by default. This is expected: only well-known public CAs are trusted by default. The following steps show how to enable trust for your private CA on client machines (browsers, `curl`, and similar tools).

Some steps below change both the destination filename and the extension (for example, from `root-ca-tls-items/root-ca-cert.pem` to `my_private_ca.crt`) to satisfy the target operating system trust-store conventions. As explained in ["Dot PEM vs Dot CRT"](#dot-pem-vs-dot-crt-a-note-on-certificate-filename-extensions), both extensions can store the same certificate data; only the filename and extension labels change, not the certificate content itself.

### Linux (Ubuntu / Debian)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates
sudo cp root-ca-tls-items/root-ca-cert.pem /usr/local/share/ca-certificates/my_private_ca.crt
sudo update-ca-certificates
```

### Amazon Linux / RHEL / CentOS

```bash
sudo cp root-ca-tls-items/root-ca-cert.pem /etc/pki/ca-trust/source/anchors/my_private_ca.crt
sudo update-ca-trust extract
```

### Windows (PowerShell as Administrator)

```powershell
certutil.exe -addstore Root root-ca-tls-items/root-ca-cert.pem
```

### Firefox

Firefox may use its own trust store:

1. `Settings` -> `Privacy & Security`
2. `Certificates` -> `View Certificates`
3. `Authorities` -> `Import`
4. Select `root-ca-tls-items/root-ca-cert.pem`, then enable trust for websites

After trust import, test again:

```bash
curl -vI https://localhost --cacert root-ca-tls-items/root-ca-cert.pem
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

Create the **REDIRECT** vhost configuration file: `/etc/httpd/conf.d/redirect.conf`:

```apache
<VirtualHost *:80>
    ServerName <your-domain-or-ip>
    ServerAlias <your-public-ip>
    Redirect permanent / https://<your-domain-or-ip>/
</VirtualHost>
```

**Why `ServerAlias`?** <br/>
`ServerName` is the main host Apache matches for this **vhost** (Virtual Host). <br/>If you only set that to your DNS name, a client that opens `http://<public-ip>/` may **not** match this vhost, so **no redirect** occurs. <br/>You need to add **`ServerAlias`** with your EC2 instance’s **public IPv4 address** (and any other IPs/DNS names clients use to access the server, separated by spaces) so both **DNS** and **IP** HTTP requests hit the same redirect.

You can put **several** DNS names or IPs on one `ServerAlias` line (space-separated) or split them across multiple `ServerAlias` lines if you prefer:

```apache
    # Inside the same <VirtualHost *:80> … </VirtualHost> block:
    ServerAlias 34.204.91.3 10.0.0.50 api.example.com
```

- Use only hostnames or addresses clients **actually** use to reach this server (for a typical public EC2 test, the **public DNS** and **public IPv4** are enough).

An example is shown below using a DNS name and a public IP address as `ServerName` and `ServerAlias` respectively:

```apache
<VirtualHost *:80>
    ServerName ec2-34-204-91-3.compute-1.amazonaws.com
    ServerAlias 34.204.91.3
    Redirect permanent / https://ec2-34-204-91-3.compute-1.amazonaws.com/
</VirtualHost>
```

- Ensure the **`Redirect`** line points to a URL whose hostname appears in your **Server Certificate Subject Alternative Name (SAN)** (usually the DNS name).
- Replace the example values above with your EC2 hostname (Public DNS) and IP (Public IPv4 address).

Apply the changes and test the redirect:

```bash
sudo apachectl configtest
sudo systemctl restart httpd
curl -I http://your-dns-name
curl -I http://your-public-ip
```

Expected response includes `HTTP/1.1 301` and a `Location: https://...` header for **both** requests when `ServerName` / `ServerAlias` match how you connect.

---

## Final Checklist

- Use the **Files used in this lab (reference)** table in Part 1 if you need a quick reminder of what each file is for.
- Keep private files secret: `root-ca-tls-items/root-ca-private-key.pem` and `server-tls-items/server-private-key.pem`.
- Share only public files: `root-ca-tls-items/root-ca-cert.pem` (for trust) and `server-tls-items/server-cert.pem` (server certificate).
- If hostname/IP changes, reissue `server-tls-items/server-cert.pem` with updated SAN.
- If CA private key is compromised, revoke trust and rebuild everything.


## Dot PEM vs Dot CRT: A Note on Certificate Filename Extensions

In this lab, we use `.pem` for all certificate and key files. However, you may see `.crt` used elsewhere. Both extensions are actually used in the wild.

- What matters for Apache on Amazon Linux (and most other web servers) is the **file content** not whether the filename ends in `.crt` or `.pem`
- The server expects PEM-formatted text, which is easily identified by headers such as `-----BEGIN CERTIFICATE-----` or `-----BEGIN PRIVATE KEY-----`
- Apache **httpd** will serve TLS correctly with either as long as you point `SSLCertificateFile` at a PEM-encoded certificate and `SSLCertificateKeyFile` at the matching PEM-encoded private key.
- This lab standardizes on `.pem` for consistency with OpenSSL defaults and the Root CA filenames.

---

## Addendum: Lab Debrief

This lab intentionally uses a private self-signed root CA (Certificate Authority) to demonstrate how TLS works end to end.

Why warnings appeared earlier:

- Browsers and operating systems do not trust your private lab CA by default.
- The certificate can still encrypt traffic, but identity is untrusted until you import the CA.

How production differs:

- In real-world public deployments, certificates are typically issued by public CAs that browsers already trust.
- That avoids browser trust warnings for users.
- For training labs, creating your own CA is faster and lower cost than obtaining and managing publicly trusted certificates.


End-of-Lab
---