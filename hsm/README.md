# Vault PKI Test With HSM

This script demonstrates setting up a HashiCorp Vault test-instance with a
three-tier PKI architecture. 

The assumption is that in an enterprise, there will be an external or offline
Root Certificate Authority (here simulated by a Vault PKI engine), and then an
Intermediate CA within Vault that is using an HSM for key operations, and then
one or more Issuing CAs in tenancy namespaces for issuing certificates without HSM
keys.

## Pre-Requisites

The only pre-requisite is that an environment variable `VAULT_LICENSE` is set, 
as the HSM and namespace features require a full Vault feature-set.

## Operation

1. Export a `VAULT_LICENSE` variable with a valid license key
1. Run `./setup.sh`, which will:
    1. download SoftHSM2 and OpenSC for HSM emulation
    1. download Vault Enterprise+HSM
    1. configure a local SoftHSM2 with suitable slots
    1. configure Vault with a Managed Key and three PKI engines
    1. Generate a test certificate called `test.pem`
    1. Leave the Vault instance running.
    1. Leave the root token in the file `token`
1. The script `./verify.sh` has some sample commands to verify the certificates
1. Run `./cleanup.sh` to remove all data (does not uninstall SoftHSM or OpenSC)
