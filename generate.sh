#!/usr/bin/env bash

set -eu

CN="${CN:-kafka-admin}"
PASSWORD="${PASSWORD:-supersecret}"
TO_GENERATE_PEM="${TO_GENERATE_PEM:-yes}"

# Set location details
COUNTRY="IN"
STATE="Karnataka"
CITY="Bangalore"
ORGANIZATION="Techlanz Private Limited"

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

echo
echo "First we will create our own certificate authority"
echo "  Two files will be created if not existing:"
echo "    - $CA_WORKING_DIRECTORY/$CA_KEY_FILE -- the private key used later to sign certificates"
echo "    - $CA_WORKING_DIRECTORY/$CA_CERT_FILE -- the certificate that will be stored in the trust store" 
echo "                                                        and serve as the certificate authority (CA)."
if [ -f "$CA_WORKING_DIRECTORY/$CA_KEY_FILE" ] && [ -f "$CA_WORKING_DIRECTORY/$CA_CERT_FILE" ]; then
  echo "Use existing $CA_WORKING_DIRECTORY/$CA_KEY_FILE and $CA_WORKING_DIRECTORY/$CA_CERT_FILE ..."
else
  rm -rf $CA_WORKING_DIRECTORY && mkdir $CA_WORKING_DIRECTORY
  echo
  echo "Generate $CA_WORKING_DIRECTORY/$CA_KEY_FILE and $CA_WORKING_DIRECTORY/$CA_CERT_FILE ..."
  echo
  openssl req -new -newkey rsa:4096 -days $VALIDITY_IN_DAYS -x509 \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORGANIZATION/CN=$CN" \
    -keyout $CA_WORKING_DIRECTORY/$CA_KEY_FILE -out $CA_WORKING_DIRECTORY/$CA_CERT_FILE -nodes
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
while read -r KAFKA_HOST || [ -n "$KAFKA_HOST" ]; do
  if [[ $KAFKA_HOST =~ ^kafka-[0-9]+$ ]]; then
      SUFFIX="server"
      DNAME="CN=$KAFKA_HOST,OU=$ORGANIZATION,O=$ORGANIZATION,L=$CITY,ST=$STATE,C=$COUNTRY"
  else
      SUFFIX="client"
      DNAME="CN=client,OU=$ORGANIZATION,O=$ORGANIZATION,L=$CITY,ST=$STATE,C=$COUNTRY"
  fi
  KEY_STORE_FILE_NAME="$KAFKA_HOST.$SUFFIX.keystore.jks"
  KEYSTORE_PATH="$KEYSTORE_WORKING_DIRECTORY/$KEY_STORE_FILE_NAME"

  # Safety check
  if [ -d "$KEYSTORE_PATH" ]; then
    echo "Error: '$KEYSTORE_PATH' is a directory. Please remove or rename it before proceeding."
    exit 1
  fi

  echo
  echo "'$KEYSTORE_PATH' will contain a key pair and a self-signed certificate."
  keytool -genkey -keystore "$KEYSTORE_PATH" \
    -alias localhost -validity $VALIDITY_IN_DAYS -keyalg RSA \
    -noprompt -dname "$DNAME" -keypass $PASSWORD -storepass $PASSWORD

  echo
  echo "Now a certificate signing request will be made to the keystore."
  keytool -certreq -keystore "$KEYSTORE_PATH" \
    -alias localhost -file $KEYSTORE_SIGN_REQUEST -keypass $PASSWORD -storepass $PASSWORD

  echo
  echo "Now the private key of the certificate authority (CA) will sign the keystore's certificate."
  openssl x509 -req -CA $CA_WORKING_DIRECTORY/$CA_CERT_FILE \
    -CAkey $CA_WORKING_DIRECTORY/$CA_KEY_FILE \
    -in $KEYSTORE_SIGN_REQUEST -out $KEYSTORE_SIGNED_CERT \
    -days $VALIDITY_IN_DAYS -CAcreateserial

  echo
  echo "Now the CA will be imported into the keystore."
  keytool -keystore "$KEYSTORE_PATH" -alias CARoot \
    -import -file $CA_WORKING_DIRECTORY/$CA_CERT_FILE -keypass $PASSWORD -storepass $PASSWORD -noprompt

  echo
  echo "Now the keystore's signed certificate will be imported back into the keystore."
  keytool -keystore "$KEYSTORE_PATH" -alias localhost \
    -import -file $KEYSTORE_SIGNED_CERT -keypass $PASSWORD -storepass $PASSWORD

  echo
  echo "Complete keystore generation!"
  echo
  echo "Deleting intermediate files:"
  rm -f $CA_WORKING_DIRECTORY/$KEYSTORE_SIGN_REQUEST_SRL $KEYSTORE_SIGN_REQUEST $KEYSTORE_SIGNED_CERT
done < "$KAFKA_HOSTS_FILE"

echo
echo "Now the trust store will be generated from the certificate."
rm -rf $TRUSTSTORE_WORKING_DIRECTORY && mkdir $TRUSTSTORE_WORKING_DIRECTORY
keytool -keystore $TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILE \
  -alias CARoot -import -file $CA_WORKING_DIRECTORY/$CA_CERT_FILE \
  -noprompt -dname "CN=$CN,OU=$ORGANIZATION,O=$ORGANIZATION,L=$CITY,ST=$STATE,C=$COUNTRY" -keypass $PASSWORD -storepass $PASSWORD

if [ "$TO_GENERATE_PEM" == "yes" ]; then
  echo
  echo "Creating PEM files for non-Java clients"
  rm -rf $PEM_WORKING_DIRECTORY && mkdir $PEM_WORKING_DIRECTORY

  # Use the first non-kafka host entry as the client for PEM generation
  CLIENT_KEYSTORE="$KEYSTORE_WORKING_DIRECTORY/${CLIENT_HOST}.client.keystore.jks"
  
  keytool -exportcert -alias CARoot -keystore "$CLIENT_KEYSTORE" \
    -rfc -file $PEM_WORKING_DIRECTORY/ca-root.pem -storepass $PASSWORD

  keytool -exportcert -alias localhost -keystore "$CLIENT_KEYSTORE" \
    -rfc -file $PEM_WORKING_DIRECTORY/client-certificate.pem -storepass $PASSWORD

  keytool -importkeystore -srcalias localhost -srckeystore "$CLIENT_KEYSTORE" \
    -destkeystore cert_and_key.p12 -deststoretype PKCS12 -srcstorepass $PASSWORD -deststorepass $PASSWORD

  openssl pkcs12 -in cert_and_key.p12 -nocerts -nodes -password pass:$PASSWORD \
    | awk '/-----BEGIN PRIVATE KEY-----/,/-----END PRIVATE KEY-----/' > $PEM_WORKING_DIRECTORY/client-private-key.pem
  rm -f cert_and_key.p12
fi