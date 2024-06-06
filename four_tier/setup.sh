#!/bin/sh
set -e

###############################################################################
# PRE-REQUISITES - input-validation and installation of required binaries
# START SERVER   - spinning up the local Vault instance and unsealing it
# CONFIGURE      - Setting up the values of the various items (mostly sourced from settings.sh)
# ROOT CA        - The engine used to simulate the offline root
# INTERMEDIATE1  - The intermediate CA used to simulate the external Intermediate
# INTERMEDIATE2  - The first Vault CA, used as an intermediate CA
# ISSUING        - The leaf Vault CA, used as an issuing CA
# TEST           - A simple test certificate


###############################################################################
# PRE-REQUISITES
###############################################################################
set +e
. ./settings.sh
set -e
export PATH=$(pwd):$PATH

if [ -f "init.json" ]; then
     echo "\e[33mERROR: It looks like some artifacts from a previous test are stil present.\e[0m"
     echo "\e[33m       Run './cleanup.sh' to remove everything\e[0m"
     exit 1
fi
if [ ! -f "vault" ]; then
     if [ "$VAULT_ENTERPRISE" -eq 1 ]; then
          wget 'https://releases.hashicorp.com/vault/1.14.0+ent.hsm/vault_1.14.0+ent.hsm_linux_amd64.zip'
     else
          wget 'https://releases.hashicorp.com/vault/1.14.0/vault_1.14.0_linux_amd64.zip'
     fi
     unzip vault*.zip
fi
if ! type "jq" > /dev/null; then
     sudo apt install -y jq
fi

###############################################################################
# START SERVER
###############################################################################
unset VAULT_TOKEN
export VAULT_ADDR="http://127.0.0.1:8200"
mkdir ./data
echo "\e[34mStarting vault\e[0m"
./vault server --config config.hcl &

echo "\e[34mWaiting for vault to be ready...\e[0m"
n=0
while [ "$n" -lt 10 ]; do
     n=$(( n + 1 ))
     set +e
     # vault status > /dev/null
     ss -tl | grep 8200
     if [ $? -eq 0 ]; then
          echo "\e[34mReady\e[0m"
          n=99
     else
          echo "\e[34mWaiting...\e[0m"
          sleep 1
     fi
     set -e
done

echo "\e[34mUnsealing vault...\e[0m"
vault operator init -key-shares=1 -key-threshold=1 -format=json > init.json
UNSEAL1="$(cat init.json | jq -r '.unseal_keys_b64[0]')"
export VAULT_TOKEN="$(cat init.json | jq -r '.root_token')"
echo $VAULT_TOKEN > token
vault operator unseal $UNSEAL1
vault audit enable file file_path=$(pwd)/data/vault_audit.log

###############################################################################
# CONFIGURE
###############################################################################
set +e
. ./settings.sh
set -e

###############################################################################
# OFFLINE EXTERNAL ROOT CA
# This is usually done by a "real" external CA team, and here is just for test
###############################################################################
echo "\e[34mCreating and configuring OFFLINE ROOT CA\e[0m"

# Create the offline-root CA core data configuration
mkdir -p $ext_root_ca_path
cp ext_root_ca_config.cnf $ext_root_ca_path/openssl.cnf
cd $ext_root_ca_path
mkdir certs crl newcerts private
chmod 700 private
touch index.txt
echo unique_subject = yes > index.txt.attr
echo 1000 > serial
echo 1000 > crlnumber

# Create the Root Key
openssl genrsa -aes256 -out $ext_root_key -passout pass:rootpass 4096
chmod 400 $ext_root_key

# Create the Root CA certificate
openssl req -config openssl.cnf -key $ext_root_key -passin pass:rootpass \
        -new -x509 -days 7300 -extensions v3_ca -out $ext_root_pem
chmod 444 $ext_root_pem

# Done
cd ..

###############################################################################
# OFFLINE EXTERNAL INTERMEDIATE CA
# This is usually done by a "real" external CA team, and here is just for test
###############################################################################
echo "\e[34mCreating and configuring OFFLINE INTERMEDIATE CA\e[0m"

# Create the offline-intermediate CA core data configuration
mkdir -p $ext_intermediate_ca_path
cp ext_intermediate_ca_config.cnf $ext_intermediate_ca_path/openssl.cnf
cd $ext_intermediate_ca_path
mkdir certs crl newcerts private csr
chmod 700 private
touch index.txt
echo unique_subject = yes > index.txt.attr
echo 1000 > serial
echo 1000 > crlnumber

# Create the Intermediate Key
openssl genrsa -aes256 -out $ext_intermediate_key -passout pass:intermediatepass 4096
chmod 400 $ext_intermediate_key

# Create the Intermediate CA signing request
openssl req \
        -config openssl.cnf \
        -new -sha256 \
        -key $ext_intermediate_key \
        -passin pass:intermediatepass \
        -out $ext_intermediate_csr
cd ..

# Sign the Intermediate CA certificate with the offline Root CA
cd $ext_root_ca_path
openssl ca \
     -batch \
     -config openssl.cnf \
     -extensions v3_intermediate_ca \
     -days 3650 \
     -notext \
     -in $ext_intermediate_csr \
     -passin pass:rootpass \
     -out $ext_intermediate_pem
cd ..

# Create the certificate chain file
cat $ext_intermediate_pem $ext_root_pem > $ext_intermediate_chain

# Done

###############################################################################
# VAULT INTERMEDIATE
###############################################################################
echo "\e[34mCreating and configuring INTERMEDIATE CA\e[0m"

# 1. Create a new Secrets Engine in Vault
vault secrets enable -path=$vault_intermediate_engine_name pki

# 2. Tune the pki_int secrets engine to issue certificates with a maximum time-to-live (TTL) 
vault secrets tune -max-lease-ttl=$vault_intermediate_ttl $vault_intermediate_engine_name

vault write -field=csr $vault_intermediate_engine_name/intermediate/generate/internal \
     common_name="$vault_intermediate_cn" \
     add_basic_constraints=true > $vault_intermediate_csr

# 4. Sign the intermediate certificate with the external intermediate CA private key, and save the generated certificate.
# This is usually done by a central external CA team, so the details of this step aren't particulary relevant.
cd $ext_intermediate_ca_path
openssl ca -batch -config openssl.cnf -extensions v3_intermediate_ca -days 365 -notext -in $vault_intermediate_csr -passin pass:intermediatepass -out certs/signed.pem

# Create the External Intermediate CA's CRL
openssl ca -config openssl.cnf -gencrl -passin pass:intermediatepass -cert $ext_intermediate_pem -out $ext_intermediate_crl_pem
openssl crl -inform PEM -in $ext_intermediate_crl_pem -outform DER -out $ext_intermediate_crl
cat $ext_intermediate_chain $ext_intermediate_crl_pem > $ext_intermediate_crl_chain
cd ..

# 5. Once the CSR is signed and the root CA returns a certificate, it can be imported back into Vault.
cat $ext_intermediate_pem $ext_intermediate_ca_path/certs/signed.pem > $vault_intermediate_pem
vault write $vault_intermediate_engine_name/intermediate/set-signed certificate=@$vault_intermediate_pem

# 6. Attach issuer_name to the default issuer for the intermediate engine
vault write $vault_intermediate_engine_name/issuer/$(vault read -field=default $vault_intermediate_engine_name/config/issuers) issuer_name=$vault_intermediate_issuer

# Import the Root CA certificate
vault write $vault_intermediate_engine_name/issuers/import/cert pem_bundle=@$ext_root_pem

# 7. Create a role for the CA
vault write $vault_intermediate_engine_name/roles/$vault_intermediate_role \
     issuer_ref="$(vault read -field=default $vault_intermediate_engine_name/config/issuers)" \
     allow_any_name=true \
     organization="$organization" ou="$vault_intermediate_role" country="$country" locality="$locality" province="$province"

# 8. Configure the CA and CRL URLs.
vault write $vault_intermediate_engine_name/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/$vault_intermediate_engine_name/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/$vault_intermediate_engine_name/crl" \
     ocsp_servers="$VAULT_ADDR/v1/$vault_intermediate_engine_name/ocsp"

###############################################################################
# ISSUING
# Repeat this in every namespace that needs PKI
###############################################################################
echo "\e[34mCreating and configuring ISSUING CA\e[0m"

# 0. Create the namespace
if [ "$VAULT_ENTERPRISE" -eq 1 ]; then
     vault namespace create $namespace
fi

# 1. Create a new Secrets Engine in Vault
vault secrets enable -namespace "$namespace" -path=$vault_issuing_engine_name pki

# 2. Tune the pki_int secrets engine to issue certificates with a maximum time-to-live (TTL) 
vault secrets tune -namespace "$namespace" -max-lease-ttl=$vault_issuing_ttl $vault_issuing_engine_name

# 4. Execute the following command to generate a CSR
vault write -namespace "$namespace" -format=json $vault_issuing_engine_name/intermediate/generate/internal \
     common_name="$vault_issuing_cn" \
     issuer_name="$vault_issuing_issuer" \
     | jq -r '.data.csr' > $vault_issuing_csr

# 5. Sign the issuing certificate with the intermediate private key, and save the generated certificate
intermediate_issuer_id=$(vault read -field=default $vault_intermediate_engine_name/config/issuers)
vault write -field=certificate $vault_intermediate_engine_name/root/sign-intermediate \
     issuer_ref="$intermediate_issuer_id" \
     csr=@$vault_issuing_csr \
     format=pem_bundle ttl="$vault_issuing_ttl" > $vault_issuing_pem

# 6. Once the CSR is signed and the root CA returns a certificate, it can be imported back into Vault.
vault write -namespace "$namespace" $vault_issuing_engine_name/intermediate/set-signed certificate=@$vault_issuing_pem

# Add an issuer_name to the issuer for ease of access later
vault write --namespace "$namespace" $vault_issuing_engine_name/issuer/$(vault read -field=default --namespace "$namespace" $vault_issuing_engine_name/config/issuers) issuer_name=$vault_issuing_issuer

# 7. Create a role for the CA
vault write -namespace "$namespace" $vault_issuing_engine_name/roles/$vault_issuing_role \
     issuer_ref="$(vault read -namespace "$namespace" -field=default $vault_issuing_engine_name/config/issuers)" \
     allowed_domains="$cert_domains" \
     allow_subdomains=true \
     organization="$organization" ou="Namespace $namespace" country="$country" locality="$locality" province="$province" \
     max_ttl="$cert_ttl"

# 8. Configure the CA and CRL URLs.
if [ -z "${namespace}" ]; then
    base_url=$VAULT_ADDR/v1
else
    base_url=$VAULT_ADDR/v1/$namespace
fi

vault write -namespace "$namespace" $vault_issuing_engine_name/config/urls \
     issuing_certificates="$base_url/$vault_issuing_engine_name/ca" \
     crl_distribution_points="$base_url/$vault_issuing_engine_name/crl" \
     ocsp_servers="$base_url/$vault_issuing_engine_name/ocsp"


###############################################################################
# TEST
###############################################################################
echo "\e[34mCreating a test certificate\e[0m"

vault write -format=json -namespace "$namespace" $vault_issuing_engine_name/issue/$vault_issuing_role \
     common_name="test.example.com" ttl="4h" \
     > test.json

cat test.json | jq -r '.data.certificate' > test.pem
cat test.json | jq -r '.data.issuing_ca' > test-issuer.pem
cat test.json | jq -r '.data.ca_chain | join("\n")' > test-chain.pem
cat test.json | jq -r '.data.private_key' > test-key.pem

###############################################################################
# END
###############################################################################
echo ""
echo "\e[32mIf all went well, the vault instance is still running and there is now a \e[0m"
echo "\e[32mtest.pem file.\e[0m"
echo ""
echo "\e[32mThe Root Token for the Vault instance is in the file 'token'.\e[0m"
echo ""
echo "\e[32mRemove everything by running './cleanup.sh'\e[0m"
echo ""
###############################################################################
