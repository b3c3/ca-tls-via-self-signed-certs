# Lab Guide: TLS via a Private Self-Signed CA

## Document Metadata

- Owner: CIL Academy
- Contact: [team@cil.academy](mailto:team@cil.academy)
- Classification: Internal
- Version: v26Apr2026T0755BST

## Purpose

This guide shows how to:

1. Create a private Certificate Authority (CA).
2. Issue a TLS certificate for a server using that CA.
3. Configure Apache on Amazon Linux (EC2) to serve HTTPS.
4. Trust the CA on client machines so browsers stop issuing warnings.

Use this for lab and internal environments only. Do not use a private self-signed CA for public internet production traffic.

---

## Part 1: General Overview, Prerequisites, and Artefacts List for the Lab

### Map of outputs

Before diving in, keep this mental picture in mind — it shows how the artefacts you will generate in Part 2 relate to one another:

```text
Root CA key ──► Root CA cert ──► (signs) ──► Server cert ◄── Server key + CSR + ext file
```

- The **Root CA key** signs the self-signed **Root CA cert** (your trust anchor).
- The **Root CA key** is then used (together with the **Root CA cert**) to sign a **Server cert**.
- The **Server cert** is derived from the **Server key**, the **CSR**, and the **X.509 extensions file** (which carries the SAN values).

### Prerequisites

- OpenSSL installed (`openssl version -a`)
- A working shell with sudo access where required
- A hostname/IP you will actually use to access the server (must match SAN)
- Template files available in `templates/`

### File naming in this lab
Use descriptive **kebab-case** names and the **`.pem` extension** for PEM-encoded keys and certificates (what OpenSSL outputs by default).    


### Files used in this lab
The table below lists each file and its role. For how `.pem` and `.crt` relate to Apache `httpd`, see [Dot PEM vs Dot CRT: A Note on Certificate Filename Extensions](#dot-pem-vs-dot-crt-a-note-on-certificate-filename-extensions).

| File | File Location | Description |
|------|---------------|-------------|
| `root-ca-private-key.pem` | `root-ca-tls-items/` | **Root CA private key.** Signs CSRs; proves CA authority. Treat this file like a **Secret** — protect like any signing key. |
| `root-ca-cert.pem` | `root-ca-tls-items/` | **Root CA certificate** (public). Your trust anchor. This is your Root CA's Public Certificate. It is a self-signed certificate. <br/>Note: It is safe to copy this file to clients so they can trust certificates issued by your Root CA. |
| `root-ca-cert.srl` | `root-ca-tls-items/` | **CA serial number file** <br/> This file is used by OpenSSL when signing, and keeps track of issued certificate serial numbers for this CA. <br/> It may appear after the first `x509 -req` command to sign a CSR (see [Step 8](#8-sign-the-server-certificate-with-your-certificate-authority-the-root-ca-in-our-case)). |
| `server.csr.cnf.template` | `templates/` | Source template for OpenSSL **CSR settings** (DN, key size, etc.). <br/> - Copy to `server-tls-items/server.csr.cnf` and use as the **CSR config file**. <br/> - Alternatively, you can use the `scripts/init-cert-config.sh` script to generate the CSR config file based on this template. <br/> - **Note:** The CSR config file is used to generate the server's private key and CSR in [Step 6](#6-generate-the-server-private-key-and-certificate-signing-request-csr). |
| `server_v3.ext.template` | `templates/` | Source template for **X.509 extensions** (SAN, key usage, etc.). <br/> - Copy to `server-tls-items/server_v3.ext` and use as the X.509 extension config file. <br/> - Alternatively, you can also use the `scripts/init-cert-config.sh` script to generate the extension config file based on this template. <br/> - **Note:** The X.509 extension file is used to generate the server's certificate in [Step 8](#8-sign-the-server-certificate-with-your-certificate-authority-the-root-ca-in-our-case). |
| `server.csr.cnf` | `server-tls-items/` | The CSR configuration file that is read by OpenSSL when generating the following two files (see [Step 6](#6-generate-the-server-private-key-and-certificate-signing-request-csr)): <br/> - the CSR (Certificate Signing Request) file: `server-tls-items/server.csr` and <br/> - the Server's Private Key file: `server-tls-items/server-private-key.pem`. <br/> |
| `server_v3.ext` | `server-tls-items/` | This configuration file contains information about the X.509 extensions (SAN, key usage, etc.) that will be included in the server certificate. It is passed to `openssl x509` when the CA signs the server certificate (See [Step 8](#8-sign-the-server-certificate-with-your-certificate-authority-the-root-ca-in-our-case)). <br/> - Note: SANs must match what clients use in the URL. |
| `server.csr` | `server-tls-items/` | This is the actual **Certificate Signing Request** (CSR) file, encoded in PEM format. It contains the server's public key and subject information; it is an intermediate artefact for the signing step. This file is generated in [Step 6](#6-generate-the-server-private-key-and-certificate-signing-request-csr). |
| `server-private-key.pem` | `server-tls-items/` | The **Server's Private Key**. Treat this file like a **Secret**, restrict its permissions (`chmod 600`) and keep it protected. <br/> This file is generated in [Step 6](#6-generate-the-server-private-key-and-certificate-signing-request-csr) and copied to the endpoint server (e.g. Apache httpd) alongside the Server's TLS Certificate (`server-cert.pem`). |
| `server-cert.pem` | `server-tls-items/` | The **Server's TLS Certificate**, signed by the Root CA and encoded in PEM format. <br/>This is considered a public file, i.e., it is generally safe to share; it contains no private key. <br/> Along with the Server's Private key (`server-private-key.pem`), this file is copied to the endpoint server and referenced by the **Web Server's** configuration (e.g. Apache's `SSLCertificateFile`). This file is generated in [Step 8](#8-sign-the-server-certificate-with-your-certificate-authority-the-root-ca-in-our-case). |

<br/>

## Part 2: Generate CA and Server Certificates

### Recommended Template Workflow
The following steps will guide you through the process of generating the Root CA and Server certificates.

Before starting, if the two lab artefact directories (`root-ca-tls-items` and `server-tls-items`) do not exist in the repo root, please create them using the command below:

```bash
mkdir -p root-ca-tls-items server-tls-items
```

- **Note:** 
  - The `mkdir -p` command is **idempotent**, so it is safe to run even if the directories already exist.
  - The commands in the subsequent steps will write certificates and keys into these directories. Use `ls -lhart` to verify their creation and content.

#### 1) Check OpenSSL

```bash
openssl version -a
```

#### 2) Create the CA Private Key

Use the `openssl genrsa` command to generate the **Root CA**'s Private Key.

```bash
openssl genrsa -out root-ca-tls-items/root-ca-private-key.pem 2048
```

| Option / Parameter | Meaning |
|------|-------------|
| `openssl genrsa` | `openssl genrsa` runs the OpenSSL RSA key generation command. In this step, it is used to create the Root CA private key. |
| `-out root-ca-tls-items/root-ca-private-key.pem` | The `-out` option specifies where to save the generated private key file. Here, it writes the key to `root-ca-tls-items/root-ca-private-key.pem`. |
| `2048` | This sets the RSA key size (in bits). Here, `2048` means a 2048-bit private key is generated. |

Restrict the CA private key permissions to 600. This makes the file private so that only the owner can read and write to it.

```bash
chmod 600 root-ca-tls-items/root-ca-private-key.pem
```

- **Note on RSA key sizes:** This lab uses **2048-bit** RSA for both the Root CA and the server certificate, which is still considered safe today and is fast enough for lab use. In production, many organisations prefer **4096-bit** for long-lived Root CA keys (often valid for 10–20 years) and **2048- or 3072-bit** for shorter-lived server certificates, trading extra CPU work for a larger security margin.

#### 3) Create the CA Certificate

Command in one line:    
```bash
openssl req -new -x509 -days 3650 -sha256 -key root-ca-tls-items/root-ca-private-key.pem -out root-ca-tls-items/root-ca-cert.pem
```

Command in multiple lines (applicable to native bash terminals)
```bash
openssl req -new -x509 \
  -days 3650 \
  -sha256 \
  -key root-ca-tls-items/root-ca-private-key.pem \
  -out root-ca-tls-items/root-ca-cert.pem
```

| Option / Parameter | Meaning |
|------|-------------|
| `openssl req` | `openssl req` starts the OpenSSL certificate request tool. <br/> In this command, it is used together with the `-x509` option to create a certificate directly. |
| `-new` | The `-new` option tells OpenSSL to create a new request/certificate operation instead of reusing an existing one. |
| `-x509` | The `-x509` option tells OpenSSL to output a self-signed X.509 certificate (your Root CA certificate) rather than only creating a CSR. |
| `-days 3650` | The `-days` option sets how long the certificate is valid. Here, `3650` means 3650 days (i.e. ten years). |
| `-sha256` | The `-sha256` option tells OpenSSL to use SHA-256 as the signing hash algorithm. |
| `-key root-ca-tls-items/root-ca-private-key.pem` | The `-key` option specifies which private key to use for signing the certificate. <br/> Here, it uses the Root CA private key file. |
| `-out root-ca-tls-items/root-ca-cert.pem` | The `-out` option specifies the output path for the generated certificate. <br/> Here, it writes the Root CA certificate to `root-ca-tls-items/root-ca-cert.pem`. |

When you run this command, OpenSSL will prompt you interactively for a series of **Distinguished Name (DN)** fields — Country Name, State/Province, Locality (City), Organisation Name, Organisational Unit Name, Common Name, and Email Address. Provide suitable values for each; in particular, set a clear CA Common Name (for example, `Lab Root CA`).

**Important Note:** In this lab, this first CA certificate is your **Root CA** (Root Certificate Authority): it signs server certificates directly and becomes the trust anchor you import on clients.

#### 4) Create the Configuration Files Required for the Server Certificate
You may have noticed that when creating the Root CA items above, you were asked a lot of questions about the CA such as `location`, `state`, `city`, `organisation`, etc. <br/>
Instead of answering these questions interactively every time, you can create configuration files to store these values, and simply pass the configuration file to the `openssl req` command. <br/>
We will use this approach to create the server certificate configuration files. <br/>

For the server certificate, you will need **two configuration files**:

1. `server.csr.cnf` - Certificate Signing Request (CSR) configuration file
2. `server_v3.ext` - X.509 extensions configuration file

These configuration files are used to provide default values for the CSR and to specify the X.509 **extensions** to be included in the certificate.

You have **two options** for generating **these files** (Option B is recommended):

- Option A: Manually **copy, paste** and **edit** the provided template files
- Option B: Use the **interactive** bash script provided: `scripts/init-cert-config.sh`

**For Option A:**
- You should already have created `server-tls-items/` and `root-ca-tls-items/` in the "Before starting" step above; if not, run the `mkdir -p` command from that section now.
  - **Note:** a *directory* on Linux/macOS is the same concept as a *folder* on Windows.
- Copy the provided templates into `server-tls-items/` (they come with sample EC2-style values; replace anything that does not match your server).
- Remember to replace placeholders in the files as needed, e.g., edit the `CN` entry to match your real DNS/IP, and the `DNS.n`/`IP.n` entries in `server_v3.ext` for your Subject Alternative Names.

```bash
# Copy the provided templates into server-tls-items/
cp templates/server.csr.cnf.template server-tls-items/server.csr.cnf
cp templates/server_v3.ext.template server-tls-items/server_v3.ext
```

**For Option B:**
- Alternatively, instead of manual copy/paste/edit steps, you can use the `scripts/init-cert-config.sh` script to generate both configuration files from the templates listed above.
- The script copies the templates, shows the distinguished name fields from the CSR template (with an option to update each value), then walks you through adding DNS/IP Subject Alternative Names.

```bash
./scripts/init-cert-config.sh
```

#### 5) Review CSR Configuration for Server Identity

Review the `server-tls-items/server.csr.cnf` file created in Step 4 to ensure the values are set correctly. If not, make any updates required.
- **Important**: remember to replace placeholders like `your-domain-or-ip` with your real DNS name or IP in the `CN` entry. (Subject Alternative Names are set separately in `server_v3.ext` — see Step 7.)

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
O = OrganisationName
OU = DepartmentName
emailAddress = admin@example.com
CN = your-domain-or-ip
```


#### 6) Generate the Server Private Key and Certificate Signing Request (CSR)

The command below generates two items in the `server-tls-items` folder: 
1. The **Server Private Key** (`server-tls-items/server-private-key.pem`) and
2. The Certificate Signing Request (**CSR**) for the Server (`server-tls-items/server.csr`).

The `server.csr` file is generated using the configuration file created in the previous step (i.e., `server-tls-items/server.csr.cnf`).

Command in one line:    
```bash
openssl req -new -nodes -out server-tls-items/server.csr -keyout server-tls-items/server-private-key.pem -config server-tls-items/server.csr.cnf
```

Command in multiple lines (applicable to native bash terminals)
```bash
openssl req -new -nodes \
  -out server-tls-items/server.csr \
  -keyout server-tls-items/server-private-key.pem \
  -config server-tls-items/server.csr.cnf
```

| Option / Parameter | Meaning |
|------|-------------|
| `openssl req` | `openssl req` starts the OpenSSL certificate request tool. In this step, it is used to generate a server private key and a CSR. |
| `-new` | The `-new` option tells OpenSSL to create a brand-new CSR. |
| `-nodes` | The `-nodes` option (originally short for "no DES") tells OpenSSL not to encrypt the private key output. <br/> In practice this means the generated private key file is not protected by a passphrase, so tools can read it without prompting. |
| `-out server-tls-items/server.csr` | The `-out` option specifies the location or path to output the generated CSR file to. <br/> In this case, it saves the generated CSR to `server-tls-items/server.csr`. |
| `-keyout server-tls-items/server-private-key.pem` | The `-keyout` option specifies where to save the generated server private key. <br/> In this case, it saves the key to `server-tls-items/server-private-key.pem`. |
| `-config server-tls-items/server.csr.cnf` | The `-config` option tells OpenSSL which configuration file to read for subject details and request settings. <br/> In this case, it reads `server-tls-items/server.csr.cnf`. |

<br/>
Restrict the server private key permissions to 600. This makes the file private so that only the owner can read and write to it.

```bash
chmod 600 server-tls-items/server-private-key.pem
```

#### 7) Create or Review the Server Certificate Extensions Configuration File

Certificate extensions are additional data fields that define extra features or constraints for a certificate, such as the Subject Alternative Name (SAN) for securing multiple domains.    
For more information, see the [OpenSSL `x509v3_config` documentation](https://docs.openssl.org/3.6/man5/x509v3_config/#subject-alternative-name).    

Create or review the `server-tls-items/server_v3.ext` file created in Step 4 to ensure the values are set correctly.

- Set SAN values to what clients will use in the URL. Add/remove `DNS.n` and `IP.n` entries as needed.

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

#### 8) Sign the Server Certificate with your Certificate Authority (the Root CA in our case)

In the [Step 6](#6-generate-the-server-private-key-and-certificate-signing-request-csr), you created a CSR (Certificate Signing Request) for the server. <br/>
In this step, you will sign the CSR with your CA's private key to generate a server certificate. <br/>
This is how it works in the real world — you would typically have your CSR signed by a well-known commercial CA (for public websites) or an internal well-known CA (for internal-only websites and systems).

<br/>
The signing command is as follows:

Command in one line:    
```bash
openssl x509 -req -in server-tls-items/server.csr -CA root-ca-tls-items/root-ca-cert.pem -CAkey root-ca-tls-items/root-ca-private-key.pem -CAcreateserial -CAserial root-ca-tls-items/root-ca-cert.srl -out server-tls-items/server-cert.pem -days 825 -sha256 -extfile server-tls-items/server_v3.ext
```

Command in multiple lines (applicable to native bash terminals)
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
| `openssl x509` | `openssl x509` starts the OpenSSL certificate signing/inspection tool. <br/> In this step, it signs the server CSR to issue a server certificate. |
| `-req` | The `-req` option tells OpenSSL that the input is a CSR request (not an existing certificate). |
| `-in server-tls-items/server.csr` | The `-in` option specifies the CSR file to read and sign. <br/> Here, it reads `server-tls-items/server.csr`. |
| `-CA root-ca-tls-items/root-ca-cert.pem` | The `-CA` option specifies the CA certificate to use as the issuer certificate. <br/> Here, it uses your Root CA certificate. |
| `-CAkey root-ca-tls-items/root-ca-private-key.pem` | The `-CAkey` option specifies the CA private key used to sign the server certificate. |
| `-CAcreateserial` | The `-CAcreateserial` option tells OpenSSL to create a serial-number file if it does not exist yet. |
| `-CAserial root-ca-tls-items/root-ca-cert.srl` | The `-CAserial` option specifies the serial-number file OpenSSL should use/manage for issued certificates. |
| `-out server-tls-items/server-cert.pem` | The `-out` option specifies where to save the signed server certificate. <br/> Here, it writes to `server-tls-items/server-cert.pem`. |
| `-days 825` | The `-days` option sets the certificate validity period. <br/> Here, the server certificate is valid for 825 days. |
| `-sha256` | The `-sha256` option tells OpenSSL to sign using SHA-256. |
| `-extfile server-tls-items/server_v3.ext` | The `-extfile` option points to the extension file (including SAN entries) to include in the issued server certificate. |

- **Note:** You may use any `-days` value you like for this lab (for example `365` for one year or `90` for three months).

The sample command uses **825** because that number often appears in older examples about **public** TLS certificates (the kind issued by well-known CAs that browsers trust by default). Since **September 2020**, major browsers and the **CA/Browser Forum** have pushed toward ever-shorter maximum lifetimes for **public** certificates. The headline figure for some years was **398 days**, but under CA/Browser Forum ballot **SC-081** that maximum is now being reduced in phases: **200 days** from **15 March 2026**, **100 days** from **15 March 2027**, and **47 days** from **15 March 2029**.   

In this lab, your server certificate is signed by **your private Root CA** (not by a **public** CA), so these public-certificate limits do not apply to your `-days` choice here.    
However, when you work on real **public** sites later, shorter certificate lifetimes help because of the following reasons:

1. **Less time at risk if a certificate is stolen or mis-issued** (smaller window for abuse).
2. **Faster rollout of stronger algorithms** when the industry deprecates older ones (e.g., SHA-1).
3. **Easier renewal at scale** when teams automate with ACME, managed PKI, or similar tools (for example Let’s Encrypt).

#### 9) Verify the Issued Certificate

In this step, you will verify the server certificate created in the previous step. Use the command below to do so:

```bash
openssl x509 -in server-tls-items/server-cert.pem -noout -text
```

| Option / Parameter | Meaning |
|------|-------------|
| `openssl x509` | `openssl x509` runs the OpenSSL certificate inspection/signing tool. <br/> In this step, it is used to inspect and verify the issued server certificate. |
| `-in server-tls-items/server-cert.pem` | The `-in` option specifies which certificate file to read. <br/> Here, it reads `server-tls-items/server-cert.pem`. |
| `-noout` | The `-noout` option prevents OpenSSL from printing the PEM-encoded certificate itself, so only the information requested by other flags (for example, `-text`) is shown. |
| `-text` | The `-text` option prints the certificate details in a readable text format (issuer, subject, SANs, validity, extensions, and more). |

<br/>
You should see output similar to the (abbreviated) example below:

```text
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 4f:2a:...:9c
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: C=US, ST=Virginia, L=Ashburn, O=CIL Academy, OU=Cloud Engineering, CN=Lab Root CA
        Validity
            Not Before: Apr 22 10:00:00 2026 GMT
            Not After : Jul 25 10:00:00 2028 GMT
        Subject: C=US, ST=Virginia, L=Ashburn, O=CIL Academy, OU=Cloud Engineering, CN=ec2-203-0-113-10.compute-1.amazonaws.com
        ...
        X509v3 extensions:
            X509v3 Basic Constraints:
                CA:FALSE
            X509v3 Key Usage:
                Digital Signature, Key Encipherment
            X509v3 Extended Key Usage:
                TLS Web Server Authentication
            X509v3 Subject Alternative Name:
                DNS:ec2-203-0-113-10.compute-1.amazonaws.com, IP Address:203.0.113.10
    Signature Algorithm: sha256WithRSAEncryption
        ...
```

Based on the output of the command above, confirm the following:

- The `Issuer` is your Root CA (the CN should match the Root CA's Common Name you set in Step 3).
- The `X509v3 Subject Alternative Name` includes the correct DNS/IP (the values you set in `server-tls-items/server_v3.ext`).
- The `X509v3 Basic Constraints` confirms `CA:FALSE`.

**Note:** `CA:FALSE` means the **Basic Constraints** marks this as a **leaf (end-entity)** certificate: it must NOT be used to issue other certificates.
- In this lab, this leaf certificate is used to secure your **Web Server** (HTTPS endpoint) which is the **end-entity**.
- In contrast, `CA:TRUE` usually appears on **CA certificates** (Root or Intermediate) that **sign** other certificates in the chain.

---

## Part 3: Deploy the Self-Signed TLS Certificate on Amazon EC2 (Apache on Amazon Linux)

### Prerequisites

The following steps assume that you have an EC2 instance running with Apache **httpd** installed and configured, and that the repository (or at least the `templates/` folder) is available on that instance.

**Tip:** use the `templates/apache-index.html` file for a simple landing page to serve — nicer than the default Apache "It Works!" page.

From the repository root on the EC2 instance, run:

```bash
sudo cp templates/apache-index.html /var/www/html/index.html
```

- **Note:** the template contains a placeholder element with the text `YOUR_PUBLIC_IP`. After copying, edit `/var/www/html/index.html` and replace `YOUR_PUBLIC_IP` with the instance's Public IPv4 address so the "Click to Copy" box shows a real value.

### 1) Open inbound HTTPS in Security Group

- Protocol: HTTPS (TCP)
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

Edit the `/etc/httpd/conf.d/ssl.conf` file using nano, vim, or any other editor of your choice.

```bash
sudo nano /etc/httpd/conf.d/ssl.conf
```

Navigate through the `ssl.conf` file and update or add the following SSL directives.  
- **Note:** Make sure the paths match where you copied the files in the previous step.

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

The `--insecure` flag on the `curl` command above is used to confirm TLS is working before client trust is configured.
- The flags `-k` and `--insecure` perform the same function in `curl`. They tell `curl` to skip the verification of the server's SSL/TLS certificate. Therefore, any of these flags allow you to connect to a server that has an invalid, expired, or self-signed certificate without `curl` throwing an error (like `curl: (60) SSL certificate problem`).

- Note that this is OK for testing purposes but should be avoided in production. While the connection is still encrypted, it is unverified. This means you are vulnerable to "**person-in-the-middle**" attacks because `curl` isn't checking if the server you're interacting with is actually who it claims to be, hence the need to avoid in production. 

---

## Part 4: Trust Your Private CA on Client Machines

As noted in the preceding section, browsers will not trust your private CA by default. This is expected: only well-known public CAs are trusted by default.    
The following steps show how to enable trust for your private CA on client machines (browsers, `curl`, and similar tools).

Some steps below change both the destination filename and the extension to satisfy the target operating system trust-store conventions.
- For example, from `root-ca-cert.pem` to `my_private_ca.crt`.    

As explained in ["Dot PEM vs Dot CRT"](#dot-pem-vs-dot-crt-a-note-on-certificate-filename-extensions), both extensions can store the same certificate data; only the filename and extension labels change, not the certificate content itself.    

Follow the steps below to import your Root CA certificate into the trust stores of different operating systems and browsers.  

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

After trust import, test again (in Firefox or any other browser). For `curl`, you can use the command below:

```bash
curl -vI https://localhost --cacert root-ca-tls-items/root-ca-cert.pem
```

You should no longer need the `--insecure` or `-k` flags when trust is configured correctly.

---

## Optional: Force HTTP -> HTTPS Redirect

Once you have configured TLS/HTTPS correctly on your Web Server, you may (optionally) want to force all HTTP traffic to be redirected to HTTPS.    
So in practice, when a user visits your site using HTTP, the server will immediately respond with a redirect telling their browser to connect using HTTPS instead, and the user will be landed on the HTTPS version of your site without any user intervention. The steps below accomplish this by configuring a separate Apache Virtual Host to enable that redirection. 

### Important security group requirement

- Keep inbound `443` open as configured in Part 3, Step 1.
- Also open inbound `80` (HTTP), otherwise clients cannot reach port 80 to receive the redirect response.

### Recommended inbound rules for this optional section

- HTTPS: TCP `443`
- HTTP: TCP `80`
- Source: your test IP (preferred) or `0.0.0.0/0` for broader access

### Create the **REDIRECT** vhost configuration file: `/etc/httpd/conf.d/redirect.conf`

- If the `/etc/httpd/conf.d/redirect.conf` file does not exist, create it.
- If the file exists, add the following lines to it or update as necessary (if other redirect rules are already present).

```apache
<VirtualHost *:80>
    ServerName <your-domain-or-ip>
    ServerAlias <your-public-ip>
    Redirect permanent / https://<your-domain-or-ip>/
</VirtualHost>
```

### Why `ServerAlias`?
As per the configuration above, when Apache httpd receives a request on `port 80` (HTTP), it matches the incoming HTTP `Host` header against each **vhost**'s `ServerName` and `ServerAlias` values to decide which **vhost** (Virtual Host) to apply.
- `ServerName` is the primary host Apache matches for this **vhost** configuration. However, if you only set that to your DNS name, a client that opens `http://<public-ip>/` sends `Host: <public-ip>`, which will **not** match this vhost — so **no redirect** occurs.
- Therefore, you need to add **`ServerAlias`** with your EC2 instance’s **public IPv4 address** (and any other IPs/DNS names clients use to access the server, separated by spaces) so both **DNS** and **IP** HTTP requests hit the same redirect.

You can put **several** DNS names or IPs on one `ServerAlias` line (space-separated) or split them across multiple `ServerAlias` lines if you prefer (example below):

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

- Ensure the **`Redirect`** line points to a URL whose hostname appears in your **Server Certificate Subject Alternative Name (SAN)**. This is usually the DNS name.
- Replace the example values above with your EC2 hostname (Public DNS) and IP (Public IPv4 address).


### Apply the changes and test the redirect

```bash
sudo apachectl configtest
sudo systemctl restart httpd
curl -I http://your-dns-name
curl -I http://your-public-ip
```

Expected response includes `HTTP/1.1 301` and a `Location: https://...` header for **both** requests when `ServerName` / `ServerAlias` match how you connect.

---

## Final Checklist

- Use the **Files used in this lab** table in Part 1 if you need a quick reminder of what each file is for.
- Keep private files secret: `root-ca-tls-items/root-ca-private-key.pem` and `server-tls-items/server-private-key.pem`.
- Ensure private keys are restricted with `chmod 600` and never committed to version control (the bundled `.gitignore` already excludes the contents of `root-ca-tls-items/` and `server-tls-items/` for this reason).
- Share only public files: `root-ca-tls-items/root-ca-cert.pem` (for trust) and `server-tls-items/server-cert.pem` (server certificate).
- If hostname/IP changes, reissue `server-tls-items/server-cert.pem` with updated SAN.
- If CA private key is compromised, revoke trust and rebuild everything.


## Dot PEM vs Dot CRT: A Note on Certificate Filename Extensions

In this lab, we use `.pem` for all certificate and key files. However, you may see `.crt` used elsewhere. Both extensions are actually used in the wild.

- What matters for Apache on Amazon Linux (and most other Web Servers) is the **file content**, not whether the filename ends in `.crt` or `.pem`.
- The server expects PEM-formatted text, which is easily identified by headers such as `-----BEGIN CERTIFICATE-----` or `-----BEGIN PRIVATE KEY-----`.
- Apache **httpd** will serve TLS correctly with either as long as you point `SSLCertificateFile` at a PEM-encoded certificate and `SSLCertificateKeyFile` at the matching PEM-encoded private key.
- This lab standardises on `.pem` for consistency with OpenSSL defaults and the Root CA filenames.

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


### Markdown Display & Print Styles
If the display & print CSS styles show up in your view (below this notice), please ignore them, they are not part of the lab guide.
They are just used to make the display and print formatting better.
<style>
/* Wrap long code lines so commands don't get cut off in narrow previews or in printed output.
   Applies on-screen and in print. */
pre, pre code {
  white-space: pre-wrap !important;
  word-break: break-word !important;
  overflow-wrap: anywhere !important;
}
</style>

End-of-Lab
---