#!/bin/sh

# This script demonstrates rotating a CA to replace it with a new CA
# We will rotate the Intermediate CA here first.
#
# This currently only works with the non-enterprise version of the test,
# so be sure to unset VAULT_LICENSE, delete the vault binary, and re-run
# the setup.sh

# Load in settings from the initial setup.
. ./settings.sh

# The details of the old expiring CA
export old_intermediate_cn=$intermediate_cn
export old_intermediate_issuer=$intermediate_issuer

# The details for the new replacement CA
export new_intermediate_cn="Intermediate CA v2"
export new_intermediate_issuer="intermediate_ca_v2"

#
# See:
# https://developer.hashicorp.com/vault/docs/secrets/pki/rotation-primitives#suggested-root-rotation-procedure
#
# https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine#step-7-rotate-root-ca
# In this doc:
#    what they call the "Root CA" is our "Intermediate CA"
#    what they call the "Intermediate CA" is our "Issuing CA"
pki=$intermediate_engine_name
root_2023=$new_intermediate_issuer
root_2022=$old_intermediate_issuer

# List the Intermediate CAs created by this CA
# vault pki list-intermediates $intermediate_engine_name/issuer/default

# List the Issuers in the root CA
echo "\e[34mListing initial issuers\e[0m"
vault list $pki/issuers
# e.g.:
# Keys
# ----
# 14dded96-6713-186d-c370-2bd9b436943e (ExampleCorp Root CA)
# 7e545571-ff22-df7b-5c7c-102344221773 (Intermediate CA v1)

# These Issuers can be viewed by reading the /issuer/
# e.g.:
# vault read $intermediate_engine_name/issuer/14dded96-6713-186d-c370-2bd9b436943e
# vault read $intermediate_engine_name/issuer/7e545571-ff22-df7b-5c7c-102344221773
# The returned certificate can be further inspected with openssl tools or decoders
# such as https://certlogik.com/decoder/


###############################################################################
# Step 7: Rotate Root CA
###############################################################################

# 7.1: Generate a new CA certificate
vault write $pki/root/rotate/internal \
    common_name="$new_intermediate_cn" \
    issuer_name="$root_2023"


# 7.2: Verify that a new Issuers is now in the root CA
vault list $pki/issuers

# 7.3: Create a role for the new CA
vault write $pki/roles/v2-servers allow_any_name=true


###############################################################################
# Step 8: Create a cross-signed intermediate
###############################################################################

# 8.1: Extract the Key ID for the new CA
key_id=$(vault read $pki/issuer/$root_2023 | grep -i key_id | awk '{print $2}')

# 8.1: Create a CSR for cross-signing the issuing
vault write -format=json $pki/intermediate/cross-sign \
      common_name="$new_intermediate_cn" \
      key_ref="$key_id" \
      | jq -r '.data.csr' \
      | tee cross-signed-issuing.csr

# 8.2: Sign the CSR with the older root CA
vault write -format=json $pki/issuer/$root_2022/sign-intermediate \
      common_name="example.com" \
      csr=@cross-signed-issuing.csr \
      | jq -r '.data.certificate' | tee cross-signed-issuing.crt


# 8.3: Import the cross-signed certificate
vault write $pki/intermediate/set-signed certificate=@cross-signed-issuing.crt

# 8.4: Read the issuer for the new root CA. You'll notice that there are now more certificates in the ca_chain field.
vault read $pki/issuer/$root_2023
# ERROR: No, the chain has only one cert in it :(


###############################################################################
# Step 9: Set default issuer
###############################################################################

# 9.1: Use the root replace command to do this, and specify the issuer name of
# the new root CA as the value to the default parameter.
vault write $pki/root/replace default=$root_2023

###############################################################################
# Step 10: Sunset defunct Root CA
###############################################################################

vault write $pki/issuer/$root_2022 \
      issuer_name="$root_2022" \
      usage=read-only,crl-signing | tail -n 5

# attempt to issue a certificate directly from the older root CA.
vault write $pki/issuer/$root_2022/issue/v1-servers \
    common_name="super.secret.internal.dev" \
    ttl=10m






###############################################################################
# Attempted code for issuing CA below: <UNDER TESTING>
###############################################################################
# vault write $issuing_engine_name/root/rotate/internal common_name="Issuing Namespace CA v2" issuer_name="issuing_namespace_ca_v2"

# key_id=$(vault read -format=json $issuing_engine_name/issuer/$issuing_issuer | jq -r '.data.key_id')

# vault write -format=json $issuing_engine_name/intermediate/cross-sign \
# common_name="issuing_namespace_ca_v2" \
# key_ref="$key_id" \
# | jq -r '.data.csr' \
# | tee cross-signed-issuing.csr

# vault write -format=json $intermediate_engine_name/issuer/$intermediate_issuer/sign-intermediate \
# common_name="Issuing Namespace CA v2" \
# csr=@cross-signed-issuing.csr \
# | jq -r '.data.certificate' \
# | tee cross-signed-issuing.crt

# vault write -format=json $issuing_engine_name/intermediate/set-signed \
# certificate=@cross-signed-issuing.crt

# vault list $issuing_engine_name/issuers