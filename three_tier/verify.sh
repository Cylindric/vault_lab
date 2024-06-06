#!/bin/sh

. ./settings.sh

ROOT_CA=root_ca/certs/root.cert.pem
INTERMEDIATE_CA=intermediate.pem
ISSUING_CA=issuing.pem
TEST_CERT=test.pem
TEST_KEY=test-key.pem

###############################################################################
# UTILITY FUNCTIONS
# These are generally just to hide away some of the OpenSSL commands that are
# not really the point of these tests. There's a bunch of tail/cut/sed/etc
# stuff needed to parse a lot of the output, and that's not something we're
# really supposed to be looking at.
###############################################################################
heading_msg()
{
    echo "\n\e[36m$1\e[0m"
}

title_msg()
{
    echo "\e[34m$1\e[0m"
}

success_msg()
{
    echo "\e[32m$1\e[0m"
}

fail_msg()
{
    echo "\e[31m$1\e[0m"
}

get_crl_from_cert()
{
    IN_FILE=$1
    OUT_FILE=$2
    URI=$(openssl asn1parse -in $IN_FILE | grep -A 1 'X509v3 CRL Distribution Points' | tail -1 | cut -d: -f 4 | cut -b21- | perl -ne 's/(..)/print chr(hex($1))/ge; END {print "\n"}')
    wget --quiet --output-document=crl.der $URI
    openssl crl -inform DER -in crl.der -outform PEM -out $OUT_FILE
}


###############################################################################
# VERIFY BASIC CERTIFICATES
###############################################################################
heading_msg "ROOT CA"

title_msg "Check it is a CA certificate..."
result=$(openssl x509 -noout -text -in $ROOT_CA | grep 'CA:TRUE')
if [ "$?" -eq 0 ]; then
    success_msg "It is a CA certificate"
else
    fail_msg "Error: the certificate is not a CA certificate (missing 'CA:True')"
fi


###############################################################################
# VERIFY INTERMEDIATE CA CERTIFICATE
###############################################################################
heading_msg "INTERMEDIATE CA"
wget --quiet --output-document="$INTERMEDIATE_CA" $VAULT_ADDR/v1/$intermediate_engine_name/ca/pem

title_msg "Check it is a CA certificate..."
result=$(openssl x509 -noout -text -in $INTERMEDIATE_CA | grep 'CA:TRUE')
if [ "$?" -eq 0 ]; then
    success_msg "It is a CA certificate"
else
    fail_msg "Error: the certificate is not a CA certificate (missing 'CA:True')"
fi

title_msg "Check that Intermediate CA was signed by Root CA..."
echo Intermediate CA $(openssl x509 -noout -text -in $INTERMEDIATE_CA | grep 'Issuer:')

title_msg "Check that Intermediate was signed by root..."
openssl verify -CAfile $ROOT_CA $INTERMEDIATE_CA

title_msg "Check that the Intermediate has a CRL..."
result=$(openssl x509 -noout -text -in $INTERMEDIATE_CA | grep -A 3 'X509v3 CRL Distribution Points' | grep URI)
if [ "$?" -eq 0 ]; then
    success_msg "The certificate has a CRL"
else
    fail_msg "Error: the certificate does not have a CRL (missing 'X509v3 CRL')"
fi

title_msg "Check that the Intermediate has not been revoked..."
result=$(openssl verify -crl_check -CAfile root_ca/crl/crl_chain.pem $INTERMEDIATE_CA)
if [ "$?" -eq 0 ]; then
    success_msg "The certificate has not been revoked"
else
    fail_msg "Error: the certificate has been revoked (CRL fail)"
fi

title_msg "Check the Vault Issuers"
issuers=$(vault list -format=json $intermediate_engine_name/issuers | jq -r '.[]')
echo "$issuers" | while read line; do
    id=$line
    name=$(vault read -field issuer_name $intermediate_engine_name/issuer/$id)
    echo "Found issuer [$id] with name [$name]"
done


###############################################################################
# VERIFY ISSUING CA CERTIFICATE
###############################################################################
heading_msg "ISSUING CA"

if [ -z "${namespace}" ]; then
    base_url=$VAULT_ADDR/v1
    export VAULT_NAMESPACE=
else
    base_url=$VAULT_ADDR/v1/$namespace
    export VAULT_NAMESPACE=$namespace
fi

wget --quiet --output-document="$ISSUING_CA" $base_url/$issuing_engine_name/ca/pem
wget --quiet --output-document="issuing-chain.pem" $base_url/$issuing_engine_name/ca_chain

title_msg "Check that Issuing CA was signed by Intermediate CA..."
echo Issuing CA $(openssl x509 -noout -text -in issuing.pem | grep 'Issuer:')
# openssl verify -CAfile $INTERMEDIATE_CA $ISSUING_CA

# title_msg "Check that Test was signed by Issuing...\e[0m"
# openssl verify -CAfile $ISSUING_CA $TEST_CERT

# title_msg "Show full chain of test certificate...\e[0m"
# openssl verify -show_chain -CAfile $ISSUING_CA $TEST_CERT

title_msg "Check the Vault Issuers"
issuers=$(vault list -format=json $issuing_engine_name/issuers | jq -r '.[]')
echo "$issuers" | while read line; do
    id=$line
    name=$(vault read -field issuer_name $issuing_engine_name/issuer/$id)
    echo "Found issuer [$id] with name [$name]"
done

###############################################################################
# TEST CERTIFICATES
###############################################################################
heading_msg "CLIENT CERTIFICATES"

title_msg "Get a server certificates..."
expected_cn="test1.example.com"

echo "Requesting a server cert $expected_cn (getting both key and cert from Vault)..."
vault write -format=json $issuing_engine_name/issue/$issuing_role \
     common_name="$expected_cn" ttl="4h" \
     > test1.example.com.json
cat test1.example.com.json | jq -r '.data.certificate' > test1.example.com.pem
cat test1.example.com.json | jq -r '.data.issuing_ca' >> test1.example.com.pem
cat test1.example.com.json | jq -r '.data.private_key' > test1.example.com-key.pem
cat test1.example.com.json | jq -r '.data.ca_chain | join("\n")' > test1.example.com-chain.pem
cn=$(openssl x509 -in test1.example.com.pem -noout -subject -nameopt multiline | grep commonName | awk '{ print $3 }')
if [ "$expected_cn" = "$cn" ]; then
    success_msg "Certificate CN is correct"
else
    fail_msg "Error: Incorrect CN"
fi


echo "Checking private key matches certificate..."
cert=$(openssl x509 -noout -modulus -in test1.example.com.pem | openssl md5)
key=$(openssl rsa -noout -modulus -in test1.example.com-key.pem | openssl md5)
if [ "$cert" = "$key" ]; then
    success_msg "Cert modulus matches key modulus"
else
    fail_msg "Error: Private key does not match certificate!"
fi


echo "Checking certificate is from expected CA chain..."
response=$(openssl verify -CAfile issuing-chain.pem test1.example.com.pem)
if [ "$?" -eq 0 ]; then
    success_msg "Cert was trusted by the CA chain"
else
    fail_msg "Error: Certificate was not trusted by the CA chain!"
fi

echo "Checking certificate against the CRL..."
get_crl_from_cert "test1.example.com.pem" "issuing-crl.pem"
(cat issuing-chain.pem; echo ""; cat issuing-crl.pem) > issuing-crl-chain.pem
response=$(openssl verify -crl_check -CAfile issuing-crl-chain.pem test1.example.com.pem)
if [ "$?" -eq 0 ]; then
    success_msg "Cert has not been revoked"
else
    fail_msg "Error: Certificate has been revoked!"
fi

echo "Checking certificate against the OCSP..."
ocsp_url=$(openssl x509 -noout -ocsp_uri -in test1.example.com.pem)
response=$(openssl ocsp -no_nonce -issuer issuing-chain.pem -cert test1.example.com.pem -text -url $ocsp_url 2>/dev/null | grep -n "Cert Status" | cut -d: -f 3 | xargs)
if [ "$response" = "good" ]; then
    success_msg "Cert has not been revoked"
else
    fail_msg "Error: Certificate has been revoked!"
fi


# revoke the certificate to ensure the CRLs are working correctly
echo "Revoking the certificate..."
serial=$(openssl x509 -noout -text -in test1.example.com.pem | grep -A 1 'Serial' | tail -n 1 | xargs)
vault write $issuing_engine_name/revoke serial_number=$serial 1>/dev/null

echo "Checking certificate against the CRL..."
get_crl_from_cert "test1.example.com.pem" "issuing-crl.pem"
(cat issuing-chain.pem; echo ""; cat issuing-crl.pem) > issuing-crl-chain.pem
set +e
response=$(openssl verify -crl_check -CAfile issuing-crl-chain.pem test1.example.com.pem 2>&1 1>/dev/null)
if [ "$?" -eq 2 ]; then
    success_msg "Certificate has been revoked."
else
    fail_msg "Error: Certificate has been revoked, verify should fail!"
fi

echo "Checking certificate against the OCSP..."
ocsp_url=$(openssl x509 -noout -ocsp_uri -in test1.example.com.pem)
response=$(openssl ocsp -no_nonce -issuer issuing-chain.pem -cert test1.example.com.pem -text -url $ocsp_url 2>/dev/null | grep -n "Cert Status" | cut -d: -f 3 | xargs)
if [ "$response" = "revoked" ]; then
    success_msg "Certificate has been revoked."
else
    fail_msg "Error: Certificate has been revoked, verify should fail!"
fi

set -e
