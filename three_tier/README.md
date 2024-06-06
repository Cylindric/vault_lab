# Vault PKI Test

This script demonstrates setting up a HashiCorp Vault test-instance with a
three-tier PKI architecture. 

The assumption is that in an enterprise, there will be an external or offline
Root Certificate Authority (here simulated by a Vault PKI engine), and then an
Intermediate CA within Vault, and then one or more Issuing CAs in tenancy 
namespaces for issuing certificates.

This means that the "root" CA that is deployed here using Vault, would normally
be an external offline CA provided either by an HSM, a separate MSCS service or
even some manual openssl commands - a root CA is often just a certificate.

## Pre-Requisites

The only input is that an environment variable `VAULT_LICENSE` can be set, which
enables the creation of a separate namespace for the isusing CA. If not set, the
default namespace is used. If the file `vault.hcli` is present, the license key
will be read from that.

## Operation

1. Specify an Enterprise license (optional):
   * Create a `vault.hclic` file with a valid license key   
   _or_
   * Export a `VAULT_LICENSE` variable with a valid license key
1. Run `./setup.sh`, which will:
    1. download Vault (Community or Enterprise+HSM)
    1. configure Vault with three PKI engines
    1. Generate a test certificate called `test.pem`
    1. Leave the Vault instance running.
    1. Leave the root token in the file `token`
1. The script `./verify.sh` has some sample commands to verify the certificates
1. Run `. ./settings.sh` to have all the same variables available as the scripts (optional)
1. Run `. ./cleanup.sh` to remove all data
