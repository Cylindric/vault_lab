#!/bin/sh

###############################################################################
# CLEANUP
###############################################################################
killall vault
rm -rf data 
rm -rf softhsm
rm -f *.json *.csr *.pem *.zip token config-hsm.hcl license.hclic
