#!/bin/sh
ROOT_CA=root.pem
INTERMEDIATE_CA=intermediate.pem
ISSUING_CA=issuing.pem
TEST_CERT=test.pem
TEST_KEY=test-key.pem

###############################################################################
# TEST
###############################################################################

# Check that Intermediate was signed by root
openssl verify -CAfile $ROOT_CA $INTERMEDIATE_CA

# Check that Issuing was signed by Intermediate
openssl verify -CAfile $INTERMEDIATE_CA $ISSUING_CA

# Check that Test was signed by Issuing
openssl verify -CAfile $ISSUING_CA $TEST_CERT

# Show full chain of test certificate
openssl verify -show_chain -CAfile $ISSUING_CA $TEST_CERT

# Show the certificate in full
openssl x509 -noout -text -in $TEST_CERT