#!/bin/sh

###############################################################################
# CLEANUP
###############################################################################
killall vault
rm -rf data ext_root_ca ext_intermediate_ca verify
rm -f *.json *.crt *.csr *.der *.pem *.zip
rm -f EULA.txt TermsOfEvaluation.txt token

unset organization
unset ou
unset country
unset locality
unset province

unset ext_root_ca_path
unset ext_root_engine_name
unset ext_root_cn
unset ext_root_issuer
unset ext_root_ttl
unset ext_root_pem
unset ext_root_role

unset ext_intermediate_ca_path
unset ext_intermediate_engine_name
unset ext_intermediate_cn
unset ext_intermediate_issuer
unset ext_intermediate_ttl
unset ext_intermediate_pem
unset ext_intermediate_role

unset vault_intermediate_engine_name
unset vault_intermediate_cn
unset vault_intermediate_issuer
unset vault_intermediate_ttl
unset vault_intermediate_csr
unset vault_intermediate_pem
unset vault_intermediate_role

unset vault_issuing_engine_name
unset vault_issuing_cn
unset vault_issuing_issuer
unset vault_issuing_ttl
unset vault_issuing_csr
unset vault_issuing_pem
unset vault_issuing_role

unset cert_domains
unset cert_ttl
