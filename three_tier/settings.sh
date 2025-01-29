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
    version=$(./vault --version | { grep '-ent' || true; })
    if [ -z "$version" ]; then
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

export root_ca_path=./root_ca
export root_engine_name=root_ca
export root_cn="Root CA v1"
export root_issuer="root_ca_v1"
export root_ttl="48h"
export root_pem=root.pem
export root_role=intermediate

export intermediate_engine_name=intermediate_ca
export intermediate_cn="Intermediate CA v1"
export intermediate_issuer="intermediate_ca_v1"
export intermediate_ttl="24h"
export intermediate_csr=intermediate.csr
export intermediate_pem=intermediate.pem
export intermediate_role=issuing

export issuing_engine_name=issuing_ca
export issuing_cn="Issuing Namespace CA v1"
export issuing_issuer="issuing_namespace_ca_v1"
export issuing_ttl="6h"
export issuing_csr=issuing.csr
export issuing_pem=issuing.pem
export issuing_role="server"

export cert_domains="example.com"
export cert_ttl="4h"
