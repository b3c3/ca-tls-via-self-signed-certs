#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/templates"
SERVER_TLS_DIR="$ROOT_DIR/server-tls-items"
ROOT_CA_TLS_DIR="$ROOT_DIR/root-ca-tls-items"

CSR_TARGET="$SERVER_TLS_DIR/server.csr.cnf"
EXT_TARGET="$SERVER_TLS_DIR/server_v3.ext"

CSR_TEMPLATE="$TEMPLATE_DIR/server.csr.cnf.template"
EXT_TEMPLATE="$TEMPLATE_DIR/server_v3.ext.template"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Replace a single "KEY = VALUE" line in $CSR_TARGET via awk so we don't mix
# awk and sed for in-place rewrites. Adds the line if the key is absent.
dn_replace_line() {
  local key="$1"
  local val="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    BEGIN { replaced = 0 }
    $0 ~ "^" k " = " { print k " = " v; replaced = 1; next }
    { print }
    END { if (!replaced) print k " = " v }
  ' "$CSR_TARGET" > "$tmp" && mv "$tmp" "$CSR_TARGET"
}

dn_prompt_one() {
  local key="$1"
  local current newval trimmed
  current="$(grep "^${key} = " "$CSR_TARGET" | head -n1 | sed "s/^${key} = //")"
  read -r -p "${key} [${current}]: " newval || true
  trimmed="$(printf '%s' "$newval" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -n "$trimmed" ]]; then
    dn_replace_line "$key" "$trimmed"
  fi
}

for required in "$CSR_TEMPLATE" "$EXT_TEMPLATE"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required TLS certificate configuration template file: $required" >&2
    exit 1
  fi
done

echo "Initialising TLS certificate config files"
echo "-----------------------------------------"
mkdir -p "$SERVER_TLS_DIR" "$ROOT_CA_TLS_DIR"
cp "$CSR_TEMPLATE" "$CSR_TARGET"
cp "$EXT_TEMPLATE" "$EXT_TARGET"

echo
echo "TLS Certificate Configuration Files copied to:"
echo "----------------------------------------------"
echo "  - $CSR_TARGET"
echo "  - $EXT_TARGET"
echo

echo "Distinguished Name (DN) Fields (sourced from the template):"
echo "-----------------------------------------------------------"

grep -E '^C = |^ST = |^L = |^O = |^OU = |^emailAddress = ' "$CSR_TARGET" | while IFS= read -r dn_line; do
  printf '  %s\n' "$dn_line"
done

echo
read -r -p "Do you want to update any of these DN fields? [y/N]: " update_dn
update_dn="$(printf '%s' "${update_dn:-}" | tr '[:upper:]' '[:lower:]')"
update_dn="${update_dn//[[:space:]]/}"

if [[ "$update_dn" == "y" || "$update_dn" == "yes" ]]; then
  dn_prompt_one "C"
  dn_prompt_one "ST"
  dn_prompt_one "L"
  dn_prompt_one "O"
  dn_prompt_one "OU"
  dn_prompt_one "emailAddress"
  echo
fi

read -r -p "Enter Primary DNS name (leave empty to skip): " primary_dns
read -r -p "Enter Primary IP address (leave empty to skip): " primary_ip

if [[ -n "${primary_dns}" ]]; then
  dn_replace_line "CN" "${primary_dns}"
fi

alt_lines=()
dns_idx=1
ip_idx=1

if [[ -n "${primary_dns}" ]]; then
  alt_lines+=("DNS.${dns_idx} = ${primary_dns}")
  dns_idx=$((dns_idx + 1))
fi

if [[ -n "${primary_ip}" ]]; then
  alt_lines+=("IP.${ip_idx} = ${primary_ip}")
  ip_idx=$((ip_idx + 1))
fi

echo
if [[ -n "${primary_dns}" || -n "${primary_ip}" ]]; then
  echo "Note: your primary DNS and/or IP will replace the SAN entries from the template."
  echo "Add any other SAN entries you also need below, or press Enter to finish."
else
  echo "Optional: add extra DNS or IP SAN entries below."
  echo "  - Press Enter now to skip and keep the SAN list from the copied template as-is."
  echo "  - Any entries you add will REPLACE the template's SAN list (they do not merge)."
fi
while true; do
  read -r -p "Add SAN type [dns/ip/none]: " san_type
  san_type="$(printf '%s' "$san_type" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$san_type" || "$san_type" == "none" ]]; then
    break
  fi

  case "$san_type" in
    dns)
      read -r -p "DNS value: " dns_val
      if [[ -n "$dns_val" ]]; then
        alt_lines+=("DNS.${dns_idx} = ${dns_val}")
        dns_idx=$((dns_idx + 1))
      fi
      ;;
    ip)
      read -r -p "IP value: " ip_val
      if [[ -n "$ip_val" ]]; then
        alt_lines+=("IP.${ip_idx} = ${ip_val}")
        ip_idx=$((ip_idx + 1))
      fi
      ;;
    *)
      echo "Unknown type. Use dns, ip, none, or simply press <Enter> to continue."
      ;;
  esac
done

if [[ "${#alt_lines[@]}" -gt 0 ]]; then
  # Remove any existing [alt_names] block before rebuilding.
  awk '/^\[alt_names\]/{flag=1; next} flag{next} {print}' "$EXT_TARGET" > "${EXT_TARGET}.tmp"
  {
    cat "${EXT_TARGET}.tmp"
    printf '\n[alt_names]\n'
    for line in "${alt_lines[@]}"; do
      printf '%s\n' "$line"
    done
  } > "$EXT_TARGET"
  rm -f "${EXT_TARGET}.tmp"
fi

echo
echo "Done."
echo "Review and adjust the options as needed in the following configuration files:"
echo "  - $CSR_TARGET"
echo "  - $EXT_TARGET"

echo
echo "Here are your next steps (please refer to the Lab Guide for detailed instructions):"
echo "  openssl req -new -nodes \\"
echo "    -out server-tls-items/server.csr \\"
echo "    -keyout server-tls-items/server-private-key.pem \\"
echo "    -config server-tls-items/server.csr.cnf"
echo "  chmod 600 server-tls-items/server-private-key.pem"
echo "  openssl x509 -req \\"
echo "    -in server-tls-items/server.csr \\"
echo "    -CA root-ca-tls-items/root-ca-cert.pem \\"
echo "    -CAkey root-ca-tls-items/root-ca-private-key.pem \\"
echo "    -CAcreateserial \\"
echo "    -CAserial root-ca-tls-items/root-ca-cert.srl \\"
echo "    -out server-tls-items/server-cert.pem \\"
echo "    -days 825 \\"
echo "    -sha256 \\"
echo "    -extfile server-tls-items/server_v3.ext"
echo
