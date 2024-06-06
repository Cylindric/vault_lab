#!/bin/sh
set -e

###############################################################################
# PRE-REQUISITES
###############################################################################
if [ -z "${VAULT_LICENSE}" ]; then
     echo "ERROR: You must export VAULT_LICENSE with a valid Enterprise license key"
     exit 1
fi
if [ -f "init.json" ]; then
     echo "ERROR: It looks like some artifacts from a previous test are stil present."
     echo "       Run './cleanup.sh' to remove everything."
     exit 1
fi
if [ ! -f "vault" ]; then
     wget https://releases.hashicorp.com/vault/1.12.2+ent.hsm/vault_1.12.2+ent.hsm_linux_amd64.zip
     unzip vault*.zip
fi
if ! type "softhsm2-util" > /dev/null; then
     sudo apt install -y softhsm2
fi
if ! type "pkcs11-tool" > /dev/null; then
     sudo apt install -y opensc
fi
if ! type "jq" > /dev/null; then
     sudo apt install -y jq
fi
export VAULT_CMD=./vault

###############################################################################
# CONFIGURE
###############################################################################
export HSM_PIN=12345678
export HSM_SO_PIN=1234
export HSM_LABEL="vault-intermediate"
export HSM_SLOT=2103421315
export HSM_NAME=myhsm

export namespace=foobar

export organization="ExampleCorp"
export ou="Security"
export country="GB"
export locality="London"
export province="London"

export root_engine_name=root_ca
export root_cn="Root CA"
export root_issuer="root_ca"
export root_ttl="48h"
export root_pem=root.pem
export root_role=intermediate

export intermediate_engine_name=intermediate_ca
export intermediate_managed_key=intermediate-key
export intermediate_cn="Intermediate CA"
export intermediate_issuer="intermediate_ca"
export intermediate_ttl="24h"
export intermediate_csr=intermediate.csr
export intermediate_pem=intermediate.pem
export intermediate_role=issuing

export issuing_engine_name=issuing_ca
export issuing_cn="Issuing CA $namespace"
export issuing_issuer="issuing_ca_$namespace"
export issuing_ttl="6h"
export issuing_csr=issuing.csr
export issuing_pem=issuing.pem
export issuing_role="server"

export cert_domains="example.com"
export cert_ttl="4h"

###############################################################################
# HSM SETUP
# Do these manually first, and then capture the correct slot number
###############################################################################
mkdir -p softhsm/tokens
export SOFTHSM2_CONF=$(pwd)/softhsm/softhsm2.conf
echo "directories.tokendir = $(pwd)/softhsm/tokens/" > $SOFTHSM2_CONF
echo "objectstore.backend = file" >> $SOFTHSM2_CONF
echo "log.level = DEBUG" >> $SOFTHSM2_CONF

softhsm2-util --init-token --free --so-pin=$HSM_SO_PIN --pin=$HSM_PIN --label="$HSM_LABEL"
export HSM_SLOT=$(softhsm2-util --show-slots | grep ^Slot | sed "${N}q;d" | cut -d ' ' -f2)
pkcs11-tool --module=/usr/lib/softhsm/libsofthsm2.so \
    --token-label $HSM_LABEL --login --pin $HSM_PIN --keypairgen \
    --mechanism ECDSA-KEY-PAIR-GEN --key-type EC:secp384r1 --usage-sign \
    --label root --id 0

###############################################################################
# START SERVER
###############################################################################
unset VAULT_TOKEN
export VAULT_ADDR="http://127.0.0.1:8200"
mkdir ./data
echo $VAULT_LICENSE > license.hclic
cat config.hcl > config-hsm.hcl
echo "
kms_library \"pkcs11\" {
    name = \"$HSM_NAME\"
    library = \"/usr/lib/softhsm/libsofthsm2.so\"
}
" >> config-hsm.hcl

$VAULT_CMD server --config config-hsm.hcl &
sleep 1
vault operator init -key-shares=1 -key-threshold=1 -format=json > init.json
export UNSEAL1="$(cat  init.json | jq -r '.unseal_keys_b64[0]')"
export VAULT_TOKEN="$(cat  init.json | jq -r '.root_token')"
echo $VAULT_TOKEN > token
vault operator unseal $UNSEAL1


###############################################################################
# OFFLINE EXTERNAL ROOT CA
# This is usually done by a "real" external CA team, and here is just for test
###############################################################################
# 1. Enable the pki secrets engine at the pki path.
vault secrets enable -path=$root_engine_name pki

# 2. Tune the pki secrets engine to issue certificates with a maximum time-to-live (TTL) 
vault secrets tune -max-lease-ttl=$root_ttl $root_engine_name

# 3. Configure the CA and CRL URLs.
vault write $root_engine_name/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/$root_engine_name/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/$root_engine_name/crl"

# 4. Generate the root CA
vault write -field=certificate $root_engine_name/root/generate/internal \
     common_name="$root_cn" \
     issuer_name="$root_issuer" \
     ttl=$root_ttl > $root_pem \
     organization="$organization" ou="$ou" country="$country" locality="$locality" province="$province"

# 5. List the issuer information for the root CA.
#vault list $root_engine_name/issuers/

# 6. You can read the issuer with its ID to get the certificates and other metadata about the issuer. 
#vault read $root_engine_name/issuer/$(vault read -field=default $root_engine_name/config/issuers)

# 7. Create a role for the root CA
vault write $root_engine_name/roles/$root_role \
     allow_any_name=true \
     organization="$organization" ou="$root_role" country="$country" locality="$locality" province="$province"


###############################################################################
# INTERMEDIATE
###############################################################################

# Add the managed key
vault write sys/managed-keys/pkcs11/$intermediate_managed_key \
      library=$HSM_NAME \
      slot=$HSM_SLOT \
      pin=$HSM_PIN \
      key_label=$HSM_LABEL-key \
      allow_store_key=true \
      allow_generate_key=true \
      mechanism=0x0001 key_bits=4096 \
      any_mount=false

# 1. Create a new Secrets Engine in Vault
vault secrets enable -path=$intermediate_engine_name pki

# 1.a Add Managed key
vault secrets tune -allowed-managed-keys=$intermediate_managed_key $intermediate_engine_name

# 2. Tune the pki_int secrets engine to issue certificates with a maximum time-to-live (TTL) 
vault secrets tune -max-lease-ttl=$intermediate_ttl $intermediate_engine_name

# 3. Configure the CA and CRL URLs.
vault write $intermediate_engine_name/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/$intermediate_engine_name/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/$intermediate_engine_name/crl"

# 4. Execute the following command to generate a CSR
vault write -format=json $intermediate_engine_name/intermediate/generate/kms \
     managed_key_name="$intermediate_managed_key" \
     common_name="$intermediate_cn" \
     issuer_name="$intermediate_issuer" \
     | jq -r '.data.csr' > $intermediate_csr

# 5. Sign the intermediate certificate with the root CA private key, and save the generated certificate
# This is usually done by a "real" external CA team
vault write -format=json $root_engine_name/root/sign-intermediate \
     issuer_ref="$root_issuer" \
     csr=@$intermediate_csr \
     format=pem_bundle ttl="$intermediate_ttl" \
     | jq -r '.data.certificate' > $intermediate_pem

# 6. Once the CSR is signed and the root CA returns a certificate, it can be imported back into Vault.
vault write $intermediate_engine_name/intermediate/set-signed certificate=@$intermediate_pem

# 7. Create a role for the CA
vault write $intermediate_engine_name/roles/$intermediate_role \
     allow_any_name=true \
     organization="$organization" ou="$intermediate_role" country="$country" locality="$locality" province="$province"

###############################################################################
# ISSUING
# Repeat this in every namespace that needs PKI
###############################################################################
# 0. Create the namespace
vault namespace create $namespace

# 1. Create a new Secrets Engine in Vault
vault secrets enable -namespace $namespace -path=$issuing_engine_name pki

# 2. Tune the pki_int secrets engine to issue certificates with a maximum time-to-live (TTL) 
vault secrets tune -namespace $namespace -max-lease-ttl=$issuing_ttl $issuing_engine_name

# 3. Configure the CA and CRL URLs.
vault write -namespace $namespace $issuing_engine_name/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/$issuing_engine_name/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/$issuing_engine_name/crl"

# 4. Execute the following command to generate a CSR
vault write -namespace $namespace -format=json $issuing_engine_name/intermediate/generate/internal \
     common_name="$issuing_cn" \
     issuer_name="$issuing_issuer" \
     | jq -r '.data.csr' > $issuing_csr

# 5. Sign the issuing certificate with the intermediate private key, and save the generated certificate
vault write -format=json $intermediate_engine_name/root/sign-intermediate \
     issuer_ref="$(vault read -field=default $intermediate_engine_name/config/issuers)" \
     csr=@$issuing_csr \
     format=pem_bundle ttl="$issuing_ttl" \
     | jq -r '.data.certificate' > $issuing_pem

# 6. Once the CSR is signed and the root CA returns a certificate, it can be imported back into Vault.
vault write -namespace $namespace $issuing_engine_name/intermediate/set-signed certificate=@$issuing_pem

# 7. Create a role for the CA
vault write -namespace $namespace $issuing_engine_name/roles/$issuing_role \
     issuer_ref="$(vault read -namespace $namespace -field=default $issuing_engine_name/config/issuers)" \
     allowed_domains="$cert_domains" \
     allow_subdomains=true \
     organization="$organization" ou="$namespace" country="$country" locality="$locality" province="$province" \
     max_ttl="$cert_ttl"



###############################################################################
# CREATE A TEST CERTIFICATE
###############################################################################

vault write -format=json -namespace $namespace $issuing_engine_name/issue/$issuing_role \
     common_name="test.example.com" ttl="4h" \
     > test.json

cat test.json | jq -r '.data.certificate' > test.pem
cat test.json | jq -r '.data.issuing_ca' >> test.pem
cat test.json | jq -r '.data.private_key' > test-key.pem

###############################################################################
# END
###############################################################################
echo ""
echo "If all went well, the vault instance is still running and there is now a "
echo "test.pem file."
echo ""
echo "The Root Token for the Vault instance is in the file 'token'."
echo ""
echo "Remove everything by running './cleanup.sh'"
echo ""
###############################################################################
