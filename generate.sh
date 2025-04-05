#!/usr/bin/env bash

set -eu

# Main configuration
CN="${CN:-10.14.7.55}"
PASSWORD="${PASSWORD:-supersecret}"
TO_GENERATE_PEM="${TO_GENERATE_PEM:-yes}"

# Set location details
COUNTRY="IN"
STATE="Karnataka"
CITY="Bangalore"
ORGANIZATION="Techlanz Private Limited"

# Certificate settings
VALIDITY_IN_DAYS=3650
CA_WORKING_DIRECTORY="certificate-authority"
TRUSTSTORE_WORKING_DIRECTORY="truststore"
KEYSTORE_WORKING_DIRECTORY="keystore"
PEM_WORKING_DIRECTORY="pem"
CA_KEY_FILE="ca-key"
CA_CERT_FILE="ca-cert"
DEFAULT_TRUSTSTORE_FILE="kafka.truststore.jks"
KEYSTORE_SIGN_REQUEST="cert-file"
KEYSTORE_SIGN_REQUEST_SRL="ca-cert.srl"
KEYSTORE_SIGNED_CERT="cert-signed"
KAFKA_HOSTS_FILE="kafka-hosts.txt"
OPENSSL_CNF="openssl-san.cnf"

# Check if hosts file exists
if [ ! -f "$KAFKA_HOSTS_FILE" ]; then
  echo "'$KAFKA_HOSTS_FILE' does not exist. Create this file"
  exit 1
fi

# Get the client host from the kafka-hosts.txt file
# We'll use the non-kafka entry as the client host
CLIENT_HOST=$(grep -v "^kafka-" "$KAFKA_HOSTS_FILE" | head -1)
if [ -z "$CLIENT_HOST" ]; then
  echo "No client host found in $KAFKA_HOSTS_FILE. Please add a non-kafka host entry."
  exit 1
fi

echo "Welcome to the Kafka SSL certificate authority, key store and trust store generator script."

# Create openssl configuration with SAN support
cat > $OPENSSL_CNF << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $CITY
O = $ORGANIZATION
CN = \${ENV::SAN_DNS}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[v3_ca]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
basicConstraints = CA:true
subjectAltName = @alt_names

[alt_names]
DNS.1 = \${ENV::SAN_DNS}
IP.1 = \${ENV::SAN_IP}
EOF

echo
echo "First we will create our own certificate authority"
echo "  Two files will be created if not existing:"
echo "    - $CA_WORKING_DIRECTORY/$CA_KEY_FILE -- the private key used later to sign certificates"
echo "    - $CA_WORKING_DIRECTORY/$CA_CERT_FILE -- the certificate that will be stored in the trust store" 
echo "                                                        and serve as the certificate authority (CA)."

# Create CA directory if it doesn't exist
mkdir -p $CA_WORKING_DIRECTORY

# Create CA certificate with SAN support
if [ -f "$CA_WORKING_DIRECTORY/$CA_KEY_FILE" ] && [ -f "$CA_WORKING_DIRECTORY/$CA_CERT_FILE" ]; then
  echo "Use existing $CA_WORKING_DIRECTORY/$CA_KEY_FILE and $CA_WORKING_DIRECTORY/$CA_CERT_FILE ..."
else
  rm -rf $CA_WORKING_DIRECTORY && mkdir $CA_WORKING_DIRECTORY
  echo
  echo "Generate $CA_WORKING_DIRECTORY/$CA_KEY_FILE and $CA_WORKING_DIRECTORY/$CA_CERT_FILE ..."
  echo
  
  # Export SAN variables
  export SAN_DNS=$CN
  export SAN_IP=$CN
  
  # Generate CA certificate with SAN extensions
  openssl req -new -newkey rsa:4096 -days $VALIDITY_IN_DAYS -x509 \
    -config $OPENSSL_CNF \
    -keyout $CA_WORKING_DIRECTORY/$CA_KEY_FILE -out $CA_WORKING_DIRECTORY/$CA_CERT_FILE -nodes
  
  # Verify the certificate
  echo "Verifying CA certificate SAN extensions:"
  openssl x509 -in $CA_WORKING_DIRECTORY/$CA_CERT_FILE -text -noout | grep -A1 "Subject Alternative Name"
fi

echo
echo "A keystore will be generated for each host in $KAFKA_HOSTS_FILE as each broker and logical client needs its own keystore"
echo
echo " NOTE: currently in Kafka, the Common Name (CN) does not need to be the FQDN of"
echo " this host. However, at some point, this may change. As such, make the CN"
echo " the FQDN. Some operating systems call the CN prompt 'first / last name'" 
echo " To learn more about CNs and FQDNs, read:"
echo " https://docs.oracle.com/javase/7/docs/api/javax/net/ssl/X509ExtendedTrustManager.html"

rm -rf $KEYSTORE_WORKING_DIRECTORY && mkdir $KEYSTORE_WORKING_DIRECTORY

# Process each host in the hosts file
while read -r KAFKA_HOST || [ -n "$KAFKA_HOST" ]; do
  if [[ $KAFKA_HOST =~ ^kafka-[0-9]+$ ]]; then
      SUFFIX="server"
      HOST_IP="$CN" # Using the CN (IP address) for Kafka servers
  else
      SUFFIX="client"
      HOST_IP="$CN" # Using the CN (IP address) for clients as well
  fi
  
  KEY_STORE_FILE_NAME="$KAFKA_HOST.$SUFFIX.keystore.jks"
  KEYSTORE_PATH="$KEYSTORE_WORKING_DIRECTORY/$KEY_STORE_FILE_NAME"
  CSR_FILE="$KAFKA_HOST.csr"
  
  # Safety check
  if [ -d "$KEYSTORE_PATH" ]; then
    echo "Error: '$KEYSTORE_PATH' is a directory. Please remove or rename it before proceeding."
    exit 1
  fi

  echo
  echo "'$KEYSTORE_PATH' will contain a key pair and a self-signed certificate."
  
  # Create keystore with appropriate hostname/IP
  keytool -genkey -keystore "$KEYSTORE_PATH" \
    -alias localhost -validity $VALIDITY_IN_DAYS -keyalg RSA \
    -keysize 2048 -storetype JKS \
    -dname "CN=$KAFKA_HOST,OU=$ORGANIZATION,O=$ORGANIZATION,L=$CITY,ST=$STATE,C=$COUNTRY" \
    -keypass $PASSWORD -storepass $PASSWORD

  echo
  echo "Now a certificate signing request will be made for $KAFKA_HOST."
  keytool -certreq -keystore "$KEYSTORE_PATH" \
    -alias localhost -file $CSR_FILE -keypass $PASSWORD -storepass $PASSWORD
  
  # Set SAN environment variables for this host
  export SAN_DNS=$KAFKA_HOST
  export SAN_IP=$HOST_IP
  
  echo
  echo "Signing the certificate with IP address $HOST_IP and hostname $KAFKA_HOST"
  # Sign the certificate with SANs
  openssl x509 -req -CA $CA_WORKING_DIRECTORY/$CA_CERT_FILE \
    -CAkey $CA_WORKING_DIRECTORY/$CA_KEY_FILE \
    -in $CSR_FILE -out $KEYSTORE_SIGNED_CERT \
    -days $VALIDITY_IN_DAYS -CAcreateserial \
    -extfile $OPENSSL_CNF -extensions v3_req
  
  # Verify the signed certificate
  echo "Verifying certificate SAN extensions for $KAFKA_HOST:"
  openssl x509 -in $KEYSTORE_SIGNED_CERT -text -noout | grep -A1 "Subject Alternative Name"

  echo
  echo "Now the CA will be imported into the keystore."
  keytool -keystore "$KEYSTORE_PATH" -alias CARoot \
    -import -file $CA_WORKING_DIRECTORY/$CA_CERT_FILE -keypass $PASSWORD -storepass $PASSWORD -noprompt

  echo
  echo "Now the keystore's signed certificate will be imported back into the keystore."
  keytool -keystore "$KEYSTORE_PATH" -alias localhost \
    -import -file $KEYSTORE_SIGNED_CERT -keypass $PASSWORD -storepass $PASSWORD

  echo
  echo "Complete keystore generation for $KAFKA_HOST!"
  
  # Clean up temporary files
  rm -f $CSR_FILE
done < "$KAFKA_HOSTS_FILE"

echo
echo "Now the trust store will be generated from the certificate."
rm -rf $TRUSTSTORE_WORKING_DIRECTORY && mkdir $TRUSTSTORE_WORKING_DIRECTORY
keytool -keystore $TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILE \
  -alias CARoot -import -file $CA_WORKING_DIRECTORY/$CA_CERT_FILE \
  -noprompt -keypass $PASSWORD -storepass $PASSWORD

# Generate PEM files if requested
if [ "$TO_GENERATE_PEM" == "yes" ]; then
  echo
  echo "Creating PEM files for non-Java clients"
  rm -rf $PEM_WORKING_DIRECTORY && mkdir $PEM_WORKING_DIRECTORY

  # Use the first non-kafka host entry as the client for PEM generation
  CLIENT_KEYSTORE="$KEYSTORE_WORKING_DIRECTORY/${CLIENT_HOST}.client.keystore.jks"
  
  echo "Exporting CA certificate to PEM format"
  keytool -exportcert -alias CARoot -keystore "$CLIENT_KEYSTORE" \
    -rfc -file $PEM_WORKING_DIRECTORY/ca-root.pem -storepass $PASSWORD

  echo "Exporting client certificate to PEM format"
  keytool -exportcert -alias localhost -keystore "$CLIENT_KEYSTORE" \
    -rfc -file $PEM_WORKING_DIRECTORY/client-certificate.pem -storepass $PASSWORD

  echo "Exporting client private key to PKCS12 format"
  keytool -importkeystore -srcalias localhost -srckeystore "$CLIENT_KEYSTORE" \
    -destkeystore cert_and_key.p12 -deststoretype PKCS12 -srcstorepass $PASSWORD -deststorepass $PASSWORD

  echo "Converting PKCS12 to PEM format for the private key"
  openssl pkcs12 -in cert_and_key.p12 -nocerts -nodes -password pass:$PASSWORD \
    | awk '/-----BEGIN PRIVATE KEY-----/,/-----END PRIVATE KEY-----/' > $PEM_WORKING_DIRECTORY/client-private-key.pem
  
  # Set appropriate permissions
  chmod 600 $PEM_WORKING_DIRECTORY/client-private-key.pem
  
  # Clean up temporary files
  rm -f cert_and_key.p12
  
  echo "PEM files generated successfully:"
  ls -la $PEM_WORKING_DIRECTORY/
fi

# Clean up intermediate files
rm -f $KEYSTORE_SIGNED_CERT $OPENSSL_CNF $CA_WORKING_DIRECTORY/$KEYSTORE_SIGN_REQUEST_SRL 2>/dev/null || true

echo
echo "Certificate generation completed successfully!"
