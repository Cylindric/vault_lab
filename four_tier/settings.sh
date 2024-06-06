#!/bin/sh

###############################################################################
# WORK OUT ENTERPRISE STATUS
###############################################################################
if [ -f vault.hclic ]; then
    echo "INFO: Enterprise license file found, using Enterprise Vault."
    export VAULT_LICENSE="$(cat vault.hclic)"
fi
if [ -z "${VAULT_LICENSE}" ]; then
    echo "WARNING: No VAULT_LICENSE found, using Community vault."
    export VAULT_ENTERPRISE=0
    export namespace=
else
    echo "INFO: Using Enterprise Vault."
    export VAULT_ENTERPRISE=1
    export namespace="testing"
fi

# Make sure we have the correct binary
if [ -f "vault" ]; then
    version=$(./vault --version | grep '-ent')
    if [ "$?" -eq 1 ]; then
        if [ "$VAULT_ENTERPRISE" -eq 1 ]; then
            echo "Enterprise was expected but Community found, removing incorrect binary"
            rm vault
        fi
    else
        if [ "$VAULT_ENTERPRISE" -ne 1 ]; then
            echo "Community was expected but Enterprise found, removing incorrect binary"
            rm vault
        fi
    fi
fi

###############################################################################
# GENERAL SERVER SETTINGS
###############################################################################
export VAULT_TOKEN=
if [ -f init.json ]; then
    export VAULT_TOKEN="$(cat init.json | jq -r '.root_token')"
fi
export VAULT_ADDR="http://127.0.0.1:8200"

###############################################################################
# CA SETTINGS
###############################################################################
export organization="ExampleCorp"
export ou="Security"
export country="GB"
export locality="London"
export province="London"

export ext_root_ca_path=$(pwd)/ext_root_ca
export ext_root_engine_name=ext_root_ca
export ext_root_cn="External Root CA v1"
export ext_root_issuer="ext_root_ca_v1"
export ext_root_ttl="48h"
export ext_root_pem="$ext_root_ca_path/certs/ext_root.pem"
export ext_root_key="$ext_root_ca_path/private/ext_root.key.pem"
export ext_root_role=ext_ca_cert

export ext_intermediate_ca_path=$(pwd)/ext_intermediate_ca
export ext_intermediate_engine_name=ext_intermediate_ca
export ext_intermediate_cn="Intermediate 1 CA v1"
export ext_intermediate_issuer="ext_intermediate_ca_v1"
export ext_intermediate_ttl="48h"
export ext_intermediate_crl="$ext_intermediate_ca_path/crl/ext_intermediate.crl"
export ext_intermediate_crl_pem="$ext_intermediate_ca_path/crl/ext_intermediate.crl.pem"
export ext_intermediate_crl_chain="$ext_intermediate_ca_path/crl/crl_chain.chain"
export ext_intermediate_csr="$ext_intermediate_ca_path/csr/ext_intermediate.csr.pem"
export ext_intermediate_pem="$ext_intermediate_ca_path/certs/ext_intermediate.pem"
export ext_intermediate_key="$ext_intermediate_ca_path/private/ext_intermediate.key.pem"
export ext_intermediate_chain="$ext_intermediate_ca_path/certs/ca-chain.pem"
export ext_intermediate_role=vault_ca_cert

export vault_intermediate_engine_name=vault_intermediate_ca
export vault_intermediate_cn="Vault Intermediate CA v1"
export vault_intermediate_issuer="vault_intermediate_ca_v1"
export vault_intermediate_ttl="24h"
export vault_intermediate_csr=$(pwd)/vault_intermediate.csr
export vault_intermediate_pem=$(pwd)/vault_intermediate.pem
export vault_intermediate_role=issuing_ca_cert

export vault_issuing_engine_name=vault_issuing_ca
export vault_issuing_cn="Vault Issuing Namespace CA v1"
export vault_issuing_issuer="issuing_namespace_ca_v1"
export vault_issuing_ttl="6h"
export vault_issuing_csr=$(pwd)/vault_issuing.csr
export vault_issuing_pem=$(pwd)/vault_issuing.pem
export vault_issuing_role="server_cert"

export cert_domains="example.com"
export cert_ttl="4h"