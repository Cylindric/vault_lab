#!/bin/sh

# These are the copy'n'pasted steps from here:
# https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine#lab-setup

# Lab setup
if [ ! -f "vault" ]; then
    wget 'https://releases.hashicorp.com/vault/1.13.1/vault_1.13.1_linux_amd64.zip'
    unzip vault*.zip
fi

./vault server -dev -dev-listen-address=0.0.0.0:8201 -dev-root-token-id root &
sleep 10

export VAULT_ADDR=http://127.0.0.1:8201
export VAULT_TOKEN=root

# Step 1: Generate root CA
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
vault write -field=certificate pki/root/generate/internal \
     common_name="example.com" \
     issuer_name="root-2022" \
     ttl=87600h > root_2022_ca.crt
vault list pki/issuers/
vault write pki/roles/2022-servers allow_any_name=true
vault write pki/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/pki/crl"

# Step 2: Generate intermediate CA
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int
vault write -format=json pki_int/intermediate/generate/internal \
     common_name="example.com Intermediate Authority" \
     issuer_name="example-dot-com-intermediate" \
     | jq -r '.data.csr' > pki_intermediate.csr
vault write -format=json pki/root/sign-intermediate \
     issuer_ref="root-2022" \
     csr=@pki_intermediate.csr \
     format=pem_bundle ttl="43800h" \
     | jq -r '.data.certificate' > intermediate.cert.pem
vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem

# Step 3: Create a role
vault write pki_int/roles/example-dot-com \
     issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
     allowed_domains="example.com" \
     allow_subdomains=true \
     max_ttl="720h"

# Step 4: Request certificates
vault write pki_int/issue/example-dot-com common_name="test.example.com" ttl="24h"

# Step 5: Revoke certificates
#vault write pki_int/revoke serial_number=<serial_number>

# Step 6: Remove expired certificates
vault write pki_int/tidy tidy_cert_store=true tidy_revoked_certs=true

# Step 7: Rotate Root CA
vault write pki/root/rotate/internal \
    common_name="example.com" \
    issuer_name="root-2023"
vault list pki/issuers
vault write pki/roles/2023-servers allow_any_name=true

# Step 8: Create a cross-signed intermediate
vault write -format=json pki/intermediate/cross-sign \
      common_name="example.com" \
      key_ref="$(vault read pki/issuer/root-2023 \
      | grep -i key_id | awk '{print $2}')" \
      | jq -r '.data.csr' \
      | tee cross-signed-intermediate.csr
vault write -format=json pki/issuer/root-2022/sign-intermediate \
      common_name="example.com" \
      csr=@cross-signed-intermediate.csr \
      | jq -r '.data.certificate' | tee cross-signed-intermediate.crt
vault write pki/intermediate/set-signed \
      certificate=@cross-signed-intermediate.crt
vault read pki/issuer/root-2023

# Step 9: Set default issuer
vault write pki/root/replace default=root-2023

# Step 10: Sunset defunct Root CA
vault write pki/issuer/root-2022 \
      issuer_name="root-2022" \
      usage=read-only,crl-signing | tail -n 5
vault write pki/issuer/root-2022/issue/2022-servers \
    common_name="super.secret.internal.dev" \
    ttl=10m

echo "^^^^ THAT ERROR IS EXPECTED AND CORRECT ^^^^"
echo
echo

# Cleanup
killall vault
rm *.crt *.csr *.pem *.zip