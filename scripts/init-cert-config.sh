#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/templates"

CSR_TARGET="$ROOT_DIR/server.csr.cnf"
EXT_TARGET="$ROOT_DIR/server_v3.ext"

CSR_TEMPLATE="$TEMPLATE_DIR/server.csr.cnf.template"
EXT_TEMPLATE="$TEMPLATE_DIR/server_v3.ext.template"

for required in "$CSR_TEMPLATE" "$EXT_TEMPLATE"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required TLS certificate configuration template file: $required" >&2
    exit 1
  fi
done

echo "Initialising TLS certificate config files"
echo "-----------------------------------------"
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
  dn_replace_line() {
    local key="$1"
    local val="$2"
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$val" '
      $0 ~ "^" k " = " { print k " = " v; next }
      { print }
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
  sed -i.bak "s|^CN = .*|CN = ${primary_dns}|" "$CSR_TARGET"
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
echo "Add extra SAN entries. Press Enter when done."
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

rm -f "$CSR_TARGET.bak"

echo
echo "Done."
echo "Review and adjust the options as needed in the following configuration files:"
echo "  - $CSR_TARGET"
echo "  - $EXT_TARGET"

echo
echo "Here are your next steps (please refer to the Lab Guide for detailed instructions):"
echo "  openssl req -new -nodes -out server.csr -keyout server.key -config server.csr.cnf"
echo "  openssl x509 -req -in server.csr -CA ca.pem -CAkey privkey.pem -CAcreateserial -out server.crt -days 825 -sha256 -extfile server_v3.ext"
