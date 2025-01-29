#!/bin/sh
set -e

###############################################################################
# PRE-REQUISITES - input-validation and installation of required binaries
# START SERVER   - spinning up the local Vault instance and unsealing it
# CONFIGURE      - Setting up the values of the various items (mostly sourced from settings.sh)
# ROOT CA        - The engine used to simulate the offline root
# INTERMEDIATE   - The first Vault CA, used as an intermediate CA
# ISSUING        - The leaf Vault CA, used as an issuing CA
# TEST           - A simple test certificate


###############################################################################
# PRE-REQUISITES
###############################################################################
. ./settings.sh
export PATH=$(pwd):$PATH

if [ -f "init.json" ]; then
     echo "\e[33mERROR: It looks like some artifacts from a previous test are stil present.\e[0m"
     echo "\e[33m       Run './cleanup.sh' to remove everything\e[0m"
     exit 1
fi
if [ ! -f "vault" ]; then
     if [ "$VAULT_ENTERPRISE" -eq 1 ]; then
          wget 'https://releases.hashicorp.com/vault/1.14.2+ent.hsm/vault_1.14.2+ent.hsm_linux_amd64.zip'
     else
          wget 'https://releases.hashicorp.com/vault/1.14.2/vault_1.14.2_linux_amd64.zip'
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
VAULT_TOKEN="$(cat init.json | jq -r '.root_token')"
echo $VAULT_TOKEN > token
vault operator unseal $UNSEAL1

###############################################################################
# CONFIGURE
###############################################################################
. settings.sh

###############################################################################
# OFFLINE EXTERNAL ROOT CA
# This is usually done by a "real" external CA team, and here is just for test
###############################################################################
echo "\e[34mCreating and configuring OFFLINE ROOT CA\e[0m"

# Create the offline-root CA core data configuration
mkdir -p $root_ca_path
cp root_ca_config.cnf $root_ca_path/openssl.cnf
cd $root_ca_path
mkdir certs crl newcerts private
chmod 700 private
touch index.txt
echo unique_subject = yes > index.txt.attr
echo 1000 > serial
echo 1000 > crlnumber

# Create the Root Key
openssl genrsa -aes256 -out private/root.key.pem -passout pass:rootpass 4096
chmod 400 private/root.key.pem

# Create the Root CA certificate
openssl req -config openssl.cnf -key private/root.key.pem -passin pass:rootpass \
        -new -x509 -days 7300 -extensions v3_ca -out certs/root.cert.pem
chmod 444 certs/root.cert.pem

# Done
cd ..

###############################################################################
# INTERMEDIATE
###############################################################################
echo "\e[34mCreating and configuring INTERMEDIATE CA\e[0m"

# 1. Create a new Secrets Engine in Vault
vault secrets enable -path=$intermediate_engine_name pki

# 2. Tune the pki_int secrets engine to issue certificates with a maximum time-to-live (TTL) 
vault secrets tune -max-lease-ttl=$intermediate_ttl $intermediate_engine_name

# 3. Use the pki issue command to handle the intermediate CA generation process
# vault pki issue \
#      --issuer_name=$intermediate_issuer \
#      /$root_engine_name/issuer/$(vault read -field=default $root_engine_name/config/issuers) \
#      /$intermediate_engine_name/ \
#      common_name="$intermediate_cn" \
#      o="$organization" ou="$Security" \
#      key_type="rsa" key_bits="4096" \
#      max_depth_len=1 \
#      permitted_dns_domains="$cert_domains" \
#      ttl="$intermediate_ttl"

vault write -field=csr $intermediate_engine_name/intermediate/generate/internal \
     common_name="$intermediate_cn" \
     add_basic_constraints=true > $intermediate_csr

# 4. Sign the intermediate certificate with the root CA private key, and save the generated certificate.
# This is usually done by a central external CA team, so the details of this step aren't particulary relevant.
cd $root_ca_path
openssl ca -batch -config openssl.cnf -extensions v3_intermediate_ca -days 365 -notext -in ../$intermediate_csr -passin pass:rootpass -out certs/$intermediate_pem
openssl ca -config openssl.cnf -gencrl -passin pass:rootpass -cert certs/root.cert.pem -out crl/root.crl.pem
openssl crl -inform PEM -in crl/root.crl.pem -outform DER -out crl/root.crl
cat certs/root.cert.pem crl/root.crl.pem > crl/crl_chain.pem
cd ..

# 5. Once the CSR is signed and the root CA returns a certificate, it can be imported back into Vault.
cat $root_ca_path/certs/root.cert.pem $root_ca_path/certs/$intermediate_pem > $intermediate_pem
vault write $intermediate_engine_name/intermediate/set-signed certificate=@$intermediate_pem

# 6. Attach issuer_name to the default issuer for the intermediate engine
vault write $intermediate_engine_name/issuer/$(vault read -field=default $intermediate_engine_name/config/issuers) issuer_name=$intermediate_issuer

# 7. Create a role for the CA
vault write $intermediate_engine_name/roles/$intermediate_role \
     issuer_ref="$(vault read -field=default $intermediate_engine_name/config/issuers)" \
     allow_any_name=true \
     organization="$organization" ou="$intermediate_role" country="$country" locality="$locality" province="$province"

# 8. Configure the CA and CRL URLs.
vault write $intermediate_engine_name/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/$intermediate_engine_name/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/$intermediate_engine_name/crl" \
     ocsp_servers="$VAULT_ADDR/v1/$intermediate_engine_name/ocsp"


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
vault secrets enable -namespace "$namespace" -path=$issuing_engine_name pki

# 2. Tune the pki_int secrets engine to issue certificates with a maximum time-to-live (TTL) 
vault secrets tune -namespace "$namespace" -max-lease-ttl=$issuing_ttl $issuing_engine_name

# 4. Execute the following command to generate a CSR
vault write -namespace "$namespace" -format=json $issuing_engine_name/intermediate/generate/internal \
     common_name="$issuing_cn" \
     issuer_name="$issuing_issuer" \
     | jq -r '.data.csr' > $issuing_csr

# 5. Sign the issuing certificate with the intermediate private key, and save the generated certificate
intermediate_issuer_id=$(vault read -field=default $intermediate_engine_name/config/issuers)
vault write -field=certificate $intermediate_engine_name/root/sign-intermediate \
     issuer_ref="$intermediate_issuer_id" \
     csr=@$issuing_csr \
     format=pem_bundle ttl="$issuing_ttl" > $issuing_pem

# 6. Once the CSR is signed and the root CA returns a certificate, it can be imported back into Vault.
vault write -namespace "$namespace" $issuing_engine_name/intermediate/set-signed certificate=@$issuing_pem

# Add an issuer_name to the issuer for ease of access later
vault write --namespace "$namespace" $issuing_engine_name/issuer/$(vault read -field=default --namespace "$namespace" $issuing_engine_name/config/issuers) issuer_name=$issuing_issuer

# 7. Create a role for the CA
vault write -namespace "$namespace" $issuing_engine_name/roles/$issuing_role \
     issuer_ref="$(vault read -namespace "$namespace" -field=default $issuing_engine_name/config/issuers)" \
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

vault write -namespace "$namespace" $issuing_engine_name/config/urls \
     issuing_certificates="$base_url/$issuing_engine_name/ca" \
     crl_distribution_points="$base_url/$issuing_engine_name/crl" \
     ocsp_servers="$base_url/$issuing_engine_name/ocsp"


###############################################################################
# TEST
###############################################################################
echo "\e[34mCreating a test certificate\e[0m"
if [ ! -d "./tests" ]; then
    mkdir ./tests
fi

vault write -format=json -namespace "$namespace" $issuing_engine_name/issue/$issuing_role \
     common_name="test.example.com" ttl="4h" \
     > ./tests/test.json

cat ./tests/test.json | jq -r '.data.certificate' > ./tests/test.pem
cat ./tests/test.json | jq -r '.data.issuing_ca' >> ./tests/test.pem
cat ./tests/test.json | jq -r '.data.private_key' > ./tests/test-key.pem

###############################################################################
# END
###############################################################################
echo ""
echo "\e[32mIf all went well, the vault instance is still running and there is now a \e[0m"
echo "\e[32mtest.pem file.\e[0m"
echo ""
echo "\e[32mThe Root Token for the Vault instance is in the file 'token'.\e[0m"
echo ""
echo "\e[32mTo use vault:"
echo "\e[32mexport VAULT_ADDR=\"http://127.0.0.1:8200\"\e[0m"
echo "\e[32mexport VAULT_TOKEN=\$(cat ./token)\e[0m"
echo ""
echo "\e[32mRemove everything by running './cleanup.sh'\e[0m"
echo ""
###############################################################################
