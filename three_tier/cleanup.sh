#!/bin/sh

###############################################################################
# CLEANUP
###############################################################################
killall vault
rm -rf data root_ca
rm -f *.json *.crt *.csr *.der *.pem *.zip
rm -f EULA.txt TermsOfEvaluation.txt token

unset organization
unset ou
unset country
unset locality
unset province

unset root_ca_path
unset root_engine_name
unset root_cn
unset root_issuer
unset root_ttl
unset root_pem
unset root_role

unset intermediate_engine_name
unset intermediate_cn
unset intermediate_issuer
unset intermediate_ttl
unset intermediate_csr
unset intermediate_pem
unset intermediate_role

unset issuing_engine_name
unset issuing_cn
unset issuing_issuer
unset issuing_ttl
unset issuing_csr
unset issuing_pem
unset issuing_role

unset cert_domains
unset cert_ttl
