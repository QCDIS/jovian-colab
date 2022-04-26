#!/usr/bin/env bash
# Generated by Fablo and *heavily* modified by Rik Janssen (used Fabric CA for crypto and fixed networkDown(): typos in container and image removal)

#
# Generate crypto-config using Fabric CA
# Based in part on: https://github.com/hyperledger/fabric-samples/blob/main/test-network (commit 9e9b8d313833ce46c72b44dbc74cd627508407c4 - Feb 2, 2022)
#
generateCryptoFabricCA() {
  printItalics "Generating crypto material" "U1F512"

  # Check if existing crypto-config present
  if [ -d "$FABLO_NETWORK_ROOT/fabric-config/crypto-config" ]; then
    echo "Can't generate certs, directory already exists: '$FABLO_NETWORK_ROOT/fabric-config/crypto-config'"
    echo "Try using 'reset' or 'down' to remove whole network or 'start' to reuse it"
    exit 1
  fi

  # Organizations
  local ORGs=("orga.fabric.localhost" "orgb.fabric.localhost" "orgc.fabric.localhost")

  # CA Admin username of each organization (retrieved from .env file)
  declare -A CA_ADMIN_NAMES=( [orga.fabric.localhost]="$ORGA_CA_ADMIN_NAME" [orgb.fabric.localhost]="$ORGB_CA_ADMIN_NAME" [orgc.fabric.localhost]="$ORGC_CA_ADMIN_NAME" )

  # CA Admin password of each organization (retrieved from .env file)
  declare -A CA_ADMIN_PASSWORDS=( [orga.fabric.localhost]="$ORGA_CA_ADMIN_PASSWORD" [orgb.fabric.localhost]="$ORGB_CA_ADMIN_PASSWORD" [orgc.fabric.localhost]="$ORGC_CA_ADMIN_PASSWORD" )
 
  inputLog "ORGs: $(echo ${ORGs[@]})"
  inputLog "CA_ADMIN_NAMES: $(echo ${CA_ADMIN_NAMES[@]})"

  # Create directory hierarchy (account for file permissions on Linux because of Docker bind mounts)
  printItalics "Creating 'crypto-config' directory hierarchy" "U1F512"
  for ORG in "${ORGs[@]}"; do
    # Fabric CA Server
    mkdir -p "$FABLO_NETWORK_ROOT"/fabric-config/crypto-config/fabric-ca/organizations/"$ORG"/msp/{cacerts,keystore,signcerts}
    # Peer Organizations
    mkdir -p "$FABLO_NETWORK_ROOT"/fabric-config/crypto-config/peerOrganizations/"$ORG"/{msp,tlsca,ca,peers,users}
    mkdir -p "$FABLO_NETWORK_ROOT"/fabric-config/crypto-config/peerOrganizations/"$ORG"/msp/{cacerts,keystore,signcerts,user,tlscacerts}
    mkdir -p "$FABLO_NETWORK_ROOT"/fabric-config/crypto-config/peerOrganizations/"$ORG"/peers/{{peer0,peer1}."$ORG"/{msp/{cacerts,keystore,signcerts,user},tls/{cacerts,tlscacerts,signcerts,keystore,user}},orderer0.consortium."$ORG"/{msp/{cacerts,keystore,signcerts,user},tls/{cacerts,tlscacerts,signcerts,keystore,user}}}
    mkdir -p "$FABLO_NETWORK_ROOT"/fabric-config/crypto-config/peerOrganizations/"$ORG"/users/orgadmin@"$ORG"/msp/{cacerts,keystore,signcerts,user}
  done
  local ORG="orgb.fabric.localhost"
  for ORDERER in "orderer0.orgb.$ORG" "orderer1.orgb.$ORG"; do
    mkdir -p "$FABLO_NETWORK_ROOT"/fabric-config/crypto-config/peerOrganizations/"$ORG"/peers/"$ORDERER"/{msp/{cacerts,keystore,signcerts,user},tls/{cacerts,tlscacerts,signcerts,keystore,user}}
  done

  # Start Fabric CA containers
  printItalics "Starting Fabric CA containers" "U1F512"
  (cd "$FABLO_NETWORK_ROOT"/fabric-docker && docker-compose -f compose.fabric-ca.yaml --project-name "${COMPOSE_PROJECT_NAME}-ca" up -d)

  # Wait for Fabric CA containers to have started
  for ORG in "${ORGs[@]}"; do
    while :; do
      if [ ! -f "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/fabric-ca/organizations/$ORG/tls-cert.pem" ]; then
        sleep 1
      else
        break
      fi
    done
  done
  
  # Register identities function
  fabric-ca-client-register() {
    local ORG_DOMAIN="$1"
    local CA_CONTAINER="$2"
    local ID_TYPE="$3"
    local ID_NAME="$4"
    local ID_SECRET="$5"

    docker exec "$CA_CONTAINER" fabric-ca-client register --caname "ca.$ORG_DOMAIN" --id.name "$ID_NAME" --id.secret "$ID_SECRET" --id.type "$ID_TYPE" --tls.certfiles "/etc/hyperledger/fabric-ca-server/ca-cert.pem"
  }
  
  # Enroll identities function
  fabric-ca-client-enroll() {
    local ORG_DOMAIN="$1"
    local CA_CONTAINER="$2"
    local USER="$3"
    local USER_PW="$4"

    docker exec "$CA_CONTAINER" fabric-ca-client enroll -u "https://$USER:$USER_PW@localhost:7054" --caname "ca.$ORG_DOMAIN" --tls.certfiles "/etc/hyperledger/fabric-ca-server/ca-cert.pem"
  }

  # Enroll: create MSP function
  fabric-ca-client-enroll-msp() {
    local ORG_DOMAIN="$1"
    local CA_CONTAINER="$2"
    local ID_TYPE="$3"
    local USER="$4"
    local USER_PW="$5"

    case "$ID_TYPE" in
      peer)
        docker exec "$CA_CONTAINER" fabric-ca-client enroll -u "https://$USER:$USER_PW@localhost:7054" --caname "ca.$ORG_DOMAIN" -M "/etc/hyperledger/fabric-ca-client/peers/$USER/msp" --csr.hosts "$USER" --tls.certfiles "/etc/hyperledger/fabric-ca-server/ca-cert.pem"
        ;;
      user)
        docker exec "$CA_CONTAINER" fabric-ca-client enroll -u "https://$USER:$USER_PW@localhost:7054" --caname "ca.$ORG_DOMAIN" -M "/etc/hyperledger/fabric-ca-client/users/$USER@$ORG/msp" --tls.certfiles "/etc/hyperledger/fabric-ca-server/ca-cert.pem"
        ;;
    esac
  }

  # Enroll: create TLS certs function
  fabric-ca-client-enroll-tls() {
    local ORG_DOMAIN="$1"
    local CA_CONTAINER="$2"
    local USER="$3"
    local USER_PW="$4"

    docker exec "$CA_CONTAINER" fabric-ca-client enroll -u "https://$USER:$USER_PW@localhost:7054" --caname "ca.$ORG_DOMAIN" -M "/etc/hyperledger/fabric-ca-client/peers/$USER/tls" --enrollment.profile tls --csr.hosts "$USER" --csr.hosts localhost --tls.certfiles "/etc/hyperledger/fabric-ca-server/ca-cert.pem"

    # We need access to the private key from outside the container
    #docker exec "$CA_CONTAINER" find "/etc/hyperledger/fabric-ca-client/peers/$USER/tls" -type f -perm 0600 -exec chmod 0644 {} +
    docker exec "$CA_CONTAINER" chown -R "$(id -u):$(id -g)" "/etc/hyperledger/fabric-ca-client/peers/$USER/tls"
  }

  # Create MSP config file
  createMspConfig() {
    local ORG="$1"
    local CACERT_FILE="$2"

    echo "NodeOUs:
    Enable: true
    ClientOUIdentifier:
      Certificate: cacerts/$CACERT_FILE
      OrganizationalUnitIdentifier: client
    PeerOUIdentifier:
      Certificate: cacerts/$CACERT_FILE
      OrganizationalUnitIdentifier: peer
    AdminOUIdentifier:
      Certificate: cacerts/$CACERT_FILE
      OrganizationalUnitIdentifier: admin
    OrdererOUIdentifier:
      Certificate: cacerts/$CACERT_FILE
      OrganizationalUnitIdentifier: orderer" > "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/msp/config.yaml"
  }

  # Enrolling the CA admin
  for ORG in "${ORGs[@]}"; do
    printItalics "Enrolling the CA admin for $ORG" "U1F512"
    fabric-ca-client-enroll "$ORG" "ca.$ORG" "${CA_ADMIN_NAMES[$ORG]}" "${CA_ADMIN_PASSWORDS[$ORG]}"
    createMspConfig "$ORG" "localhost-7054-ca-${ORG//./-}.pem"
  done

  # Since the CA serves as both the organization CA and TLS CA, copy the org's root cert that was generated by CA startup into the org level ca and tlsca directories
  for ORG in "${ORGs[@]}"; do
    # Copy the org's CA cert to the org's /msp/tlscacerts directory (for use in the channel MSP definition)
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/fabric-ca/organizations/$ORG/ca-cert.pem" "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/msp/tlscacerts/ca.crt"
  
    # Copy the org's CA cert to the org's /tlsca directory (for use by clients)
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/fabric-ca/organizations/$ORG/ca-cert.pem" "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/tlsca/tlsca.$ORG-cert.pem"
  
    # Copy the org's CA cert to the org's /ca directory (for use by clients)
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/fabric-ca/organizations/$ORG/ca-cert.pem" "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/ca/ca.$ORG-cert.pem"   
  done

  # Enrolling the peers (each org has the same number of peers)
  for ORG in "${ORGs[@]}"; do
    printItalics "Enrolling the peers for $ORG" "U1F512"
    for PEER in "peer0.$ORG" "peer1.$ORG"; do
      # Register peer
      fabric-ca-client-register "$ORG" "ca.$ORG" "peer" "$PEER" "peerpwsecret"
      # Generating the peer MSP
      fabric-ca-client-enroll-msp "$ORG" "ca.$ORG" "peer" "$PEER" "peerpwsecret"
      # Copy the org's MSP config file
      cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/msp/config.yaml" "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$PEER/msp/config.yaml"
      # Generate the peer TLS certs
      fabric-ca-client-enroll-tls "$ORG" "ca.$ORG" "$PEER" "peerpwsecret"
      # Copy the tls CA cert, server cert, server keystore to well known file names in the peer's tls directory that are referenced by peer startup config
      cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$PEER/tls/tlscacerts/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$PEER/tls/ca.crt"
      cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$PEER/tls/signcerts/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$PEER/tls/server.crt"
      cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$PEER/tls/keystore/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$PEER/tls/server.key"
    done
  done

  # Enrolling the orderers for the 'consortium' channel (each org has one orderer)
  printItalics "Enrolling the orderers for the 'consortium' channel" "U1F512"
  for ORG in "${ORGs[@]}"; do
    local ORDERER="orderer0.consortium.$ORG"
    # Register the org orderer
    fabric-ca-client-register "$ORG" "ca.$ORG" "orderer" "$ORDERER" "ordererpwsecret"
    # Generating the orderer MSP
    fabric-ca-client-enroll-msp "$ORG" "ca.$ORG" "peer" "$ORDERER" "ordererpwsecret"
    # Copy the org's MSP config file
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/msp/config.yaml" "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/msp/config.yaml"
    # Generate the orderer TLS certs
    fabric-ca-client-enroll-tls "$ORG" "ca.$ORG" "$ORDERER" "ordererpwsecret"
    # Copy the tls CA cert, server cert, server keystore to well known file names in the orderer's tls directory that are referenced by orderer startup config
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/tlscacerts/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/ca.crt"
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/signcerts/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/server.crt"
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/keystore/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/server.key"   
  done

  # Enrolling the orderers for the 'orgb' channel
  printItalics "Enrolling the orderers for the 'orgb' channel" "U1F512"
  local ORG="orgb.fabric.localhost"
  for ORDERER in "orderer0.orgb.$ORG" "orderer1.orgb.$ORG"; do
    # Register the org orderer
    fabric-ca-client-register "$ORG" "ca.$ORG" "orderer" "$ORDERER" "ordererpwsecret"
    # Generating the orderer MSP
    fabric-ca-client-enroll-msp "$ORG" "ca.$ORG" "peer" "$ORDERER" "ordererpwsecret"
    # Copy the org's MSP config file
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/msp/config.yaml" "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/msp/config.yaml"
    # Generate the orderer TLS certs
    fabric-ca-client-enroll-tls "$ORG" "ca.$ORG" "$ORDERER" "ordererpwsecret"
    # Copy the tls CA cert, server cert, server keystore to well known file names in the orderer's tls directory that are referenced by orderer startup config
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/tlscacerts/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/ca.crt"
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/signcerts/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/server.crt"
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/keystore/"* "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/peers/$ORDERER/tls/server.key"   
  done

  # Enrolling the org admin
  for ORG in "${ORGs[@]}"; do
    printItalics "Enrolling the org admin for $ORG" "U1F512"
    # Register the org admin
    fabric-ca-client-register "$ORG" "ca.$ORG" "admin" "orgadmin" "orgadminpw"
    # Generating the org admin MSP
    fabric-ca-client-enroll-msp "$ORG" "ca.$ORG" "user" "orgadmin" "orgadminpw"
    # Copy the org's MSP config file
    cp "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/msp/config.yaml" "$FABLO_NETWORK_ROOT/fabric-config/crypto-config/peerOrganizations/$ORG/users/orgadmin@$ORG/msp/config.yaml"
    # Rename private key
    docker exec "ca.$ORG" sh -c "mv /etc/hyperledger/fabric-ca-client/users/orgadmin@${ORG}/msp/keystore/* /etc/hyperledger/fabric-ca-client/users/orgadmin@${ORG}/msp/keystore/priv-key.pem"
  done

  # Fix permissions (account for file permissions on Linux because of Docker bind mounts).
  for ORG in "${ORGs[@]}"; do
    docker exec "ca.$ORG" chown -R "$(id -u):$(id -g)" "/etc/hyperledger"
  done

  printItalics "Setting up CA admin client application" "U1F512"
  docker exec ca-client.fabric.localhost sh -c "npm install && mkdir ./wallet && chown -R $(id -u):$(id -g) ./"
}

generateArtifacts() {
  printHeadline "Generating basic configs" "U1F913"

  # Use Fabric CA instead of cryptogen
  generateCryptoFabricCA

  printItalics "Generating genesis block for group consortium" "U1F3E0"
  genesisBlockCreate "$FABLO_NETWORK_ROOT/fabric-config" "$FABLO_NETWORK_ROOT/fabric-config/config" "ConsortiumGenesis"

  printItalics "Generating genesis block for group orgb" "U1F3E0"
  genesisBlockCreate "$FABLO_NETWORK_ROOT/fabric-config" "$FABLO_NETWORK_ROOT/fabric-config/config" "OrgbGenesis"

  # Create directory for chaincode packages to avoid permission errors on linux
  mkdir -p "$FABLO_NETWORK_ROOT/fabric-config/chaincode-packages"
}

startNetwork() {
  printHeadline "Starting network" "U1F680"
  (cd "$FABLO_NETWORK_ROOT"/fabric-docker && docker-compose -f compose.fabric-ca.yaml --project-name "${COMPOSE_PROJECT_NAME}-ca" up -d)
  (cd "$FABLO_NETWORK_ROOT"/fabric-docker && docker-compose up -d)
  sleep 6
}

generateChannelsArtifacts() {
  printHeadline "Generating config for 'consortium-chain'" "U1F913"
  createChannelTx "consortium-chain" "$FABLO_NETWORK_ROOT/fabric-config" "ConsortiumChain" "$FABLO_NETWORK_ROOT/fabric-config/config"
  printHeadline "Generating config for 'orgb-chain'" "U1F913"
  createChannelTx "orgb-chain" "$FABLO_NETWORK_ROOT/fabric-config" "OrgbChain" "$FABLO_NETWORK_ROOT/fabric-config/config"
}

installChannels() {
  printHeadline "Creating 'consortium-chain' on orgA/peer0" "U1F63B"
  docker exec -i cli.orga.fabric.localhost bash -c "source scripts/channel_fns.sh; createChannelAndJoinTls 'consortium-chain' 'MSPorgA' 'peer0.orga.fabric.localhost:7051' 'crypto/users/orgadmin@orga.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orga.fabric.localhost-cert.pem' 'orderer0.consortium.orga.fabric.localhost:7050';"
  printItalics "Joining 'consortium-chain' on  orgA/peer1" "U1F638"
  docker exec -i cli.orga.fabric.localhost bash -c "source scripts/channel_fns.sh; fetchChannelAndJoinTls 'consortium-chain' 'MSPorgA' 'peer1.orga.fabric.localhost:7051' 'crypto/users/orgadmin@orga.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orga.fabric.localhost-cert.pem' 'orderer0.consortium.orga.fabric.localhost:7050';"
  printItalics "Joining 'consortium-chain' on  orgB/peer0" "U1F638"
  docker exec -i cli.orgb.fabric.localhost bash -c "source scripts/channel_fns.sh; fetchChannelAndJoinTls 'consortium-chain' 'MSPorgB' 'peer0.orgb.fabric.localhost:7051' 'crypto/users/orgadmin@orgb.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem' 'orderer0.consortium.orgb.fabric.localhost:7050';"
  printItalics "Joining 'consortium-chain' on  orgB/peer1" "U1F638"
  docker exec -i cli.orgb.fabric.localhost bash -c "source scripts/channel_fns.sh; fetchChannelAndJoinTls 'consortium-chain' 'MSPorgB' 'peer1.orgb.fabric.localhost:7051' 'crypto/users/orgadmin@orgb.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem' 'orderer0.consortium.orgb.fabric.localhost:7050';"
  printItalics "Joining 'consortium-chain' on  orgC/peer0" "U1F638"
  docker exec -i cli.orgc.fabric.localhost bash -c "source scripts/channel_fns.sh; fetchChannelAndJoinTls 'consortium-chain' 'MSPorgC' 'peer0.orgc.fabric.localhost:7051' 'crypto/users/orgadmin@orgc.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem' 'orderer0.consortium.orgc.fabric.localhost:7050';"
  printItalics "Joining 'consortium-chain' on  orgC/peer1" "U1F638"
  docker exec -i cli.orgc.fabric.localhost bash -c "source scripts/channel_fns.sh; fetchChannelAndJoinTls 'consortium-chain' 'MSPorgC' 'peer1.orgc.fabric.localhost:7051' 'crypto/users/orgadmin@orgc.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem' 'orderer0.consortium.orgc.fabric.localhost:7050';"
  
  printHeadline "Creating 'orgb-chain' on orgB/peer0" "U1F63B"
  docker exec -i cli.orgb.fabric.localhost bash -c "source scripts/channel_fns.sh; createChannelAndJoinTls 'orgb-chain' 'MSPorgB' 'peer0.orgb.fabric.localhost:7051' 'crypto/users/orgadmin@orgb.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem' 'orderer0.orgb.orgb.fabric.localhost:7050';"
  printItalics "Joining 'orgb-chain' on  orgB/peer1" "U1F638"
  docker exec -i cli.orgb.fabric.localhost bash -c "source scripts/channel_fns.sh; fetchChannelAndJoinTls 'orgb-chain' 'MSPorgB' 'peer1.orgb.fabric.localhost:7051' 'crypto/users/orgadmin@orgb.fabric.localhost/msp' 'crypto/msp/tlscacerts/ca.crt' 'crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem' 'orderer0.orgb.orgb.fabric.localhost:7050';"
}

installChaincodes() {
  CHAINCODES_DIR="$(readlink -f ${CHAINCODES_DIR})"
  if [ -n "$(ls "$CHAINCODES_DIR/cc-ipfs")" ]; then
    local version="0.0.1"
    printHeadline "Packaging chaincode 'consortium-cc-ipfs'" "U1F60E"
    chaincodeBuild "consortium-cc-ipfs" "node" "$CHAINCODES_DIR/cc-ipfs" "$CHAINCODE_NODE_VERSION"
    chaincodePackage "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "node" printHeadline "Installing 'consortium-cc-ipfs' for orgA" "U1F60E"
    chaincodeInstall "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem"
    chaincodeInstall "cli.orga.fabric.localhost" "peer1.orga.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem"
    chaincodeApprove "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orga.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem" ""
    printHeadline "Installing 'consortium-cc-ipfs' for orgB" "U1F60E"
    chaincodeInstall "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
    chaincodeInstall "cli.orgb.fabric.localhost" "peer1.orgb.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
    chaincodeApprove "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orgb.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem" ""
    printHeadline "Installing 'consortium-cc-ipfs' for orgC" "U1F60E"
    chaincodeInstall "cli.orgc.fabric.localhost" "peer0.orgc.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem"
    chaincodeInstall "cli.orgc.fabric.localhost" "peer1.orgc.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem"
    chaincodeApprove "cli.orgc.fabric.localhost" "peer0.orgc.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orgc.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem" ""
    printItalics "Committing chaincode 'consortium-cc-ipfs' on channel 'consortium-chain' as 'orgA'" "U1F618"
    chaincodeCommit "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orga.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem" "peer0.orga.fabric.localhost:7051,peer0.orgb.fabric.localhost:7051,peer0.orgc.fabric.localhost:7051" "crypto-peer/peer0.orga.fabric.localhost/tls/ca.crt,crypto-peer/peer0.orgb.fabric.localhost/tls/ca.crt,crypto-peer/peer0.orgc.fabric.localhost/tls/ca.crt" ""
  else
    echo "Warning! Skipping chaincode 'consortium-cc-ipfs' installation. Chaincode directory is empty."
    echo "Looked in dir: '$CHAINCODES_DIR/cc-ipfs'"
  fi
  if [ -n "$(ls "$CHAINCODES_DIR/cc-ipfs")" ]; then
    local version="0.0.1"
    printHeadline "Packaging chaincode 'orgb-cc-ipfs'" "U1F60E"
    chaincodeBuild "orgb-cc-ipfs" "node" "$CHAINCODES_DIR/cc-ipfs" "$CHAINCODE_NODE_VERSION"
    chaincodePackage "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-cc-ipfs" "$version" "node" printHeadline "Installing 'orgb-cc-ipfs' for orgB" "U1F60E"
    chaincodeInstall "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
    chaincodeInstall "cli.orgb.fabric.localhost" "peer1.orgb.fabric.localhost:7051" "orgb-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
    chaincodeApprove "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-chain" "orgb-cc-ipfs" "$version" "orderer0.orgb.orgb.fabric.localhost:7050" "AND ('MSPorgB.member')" "false" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem" ""
    printItalics "Committing chaincode 'orgb-cc-ipfs' on channel 'orgb-chain' as 'orgB'" "U1F618"
    chaincodeCommit "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-chain" "orgb-cc-ipfs" "$version" "orderer0.orgb.orgb.fabric.localhost:7050" "AND ('MSPorgB.member')" "false" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem" "peer0.orgb.fabric.localhost:7051" "crypto-peer/peer0.orgb.fabric.localhost/tls/ca.crt" ""
  else
    echo "Warning! Skipping chaincode 'orgb-cc-ipfs' installation. Chaincode directory is empty."
    echo "Looked in dir: '$CHAINCODES_DIR/cc-ipfs'"
  fi
}

notifyOrgsAboutChannels() {
  printHeadline "Creating new channel config blocks" "U1F537"
  createNewChannelUpdateTx "consortium-chain" "MSPorgA" "ConsortiumChain" "$FABLO_NETWORK_ROOT/fabric-config" "$FABLO_NETWORK_ROOT/fabric-config/config"
  createNewChannelUpdateTx "consortium-chain" "MSPorgB" "ConsortiumChain" "$FABLO_NETWORK_ROOT/fabric-config" "$FABLO_NETWORK_ROOT/fabric-config/config"
  createNewChannelUpdateTx "consortium-chain" "MSPorgC" "ConsortiumChain" "$FABLO_NETWORK_ROOT/fabric-config" "$FABLO_NETWORK_ROOT/fabric-config/config"
  createNewChannelUpdateTx "orgb-chain" "MSPorgB" "OrgbChain" "$FABLO_NETWORK_ROOT/fabric-config" "$FABLO_NETWORK_ROOT/fabric-config/config"

  printHeadline "Notyfing orgs about channels" "U1F4E2"
  notifyOrgAboutNewChannelTls "consortium-chain" "MSPorgA" "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost" "orderer0.consortium.orga.fabric.localhost:7050" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem"
  notifyOrgAboutNewChannelTls "consortium-chain" "MSPorgB" "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost" "orderer0.consortium.orgb.fabric.localhost:7050" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
  notifyOrgAboutNewChannelTls "consortium-chain" "MSPorgC" "cli.orgc.fabric.localhost" "peer0.orgc.fabric.localhost" "orderer0.consortium.orgc.fabric.localhost:7050" "crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem"
  notifyOrgAboutNewChannelTls "orgb-chain" "MSPorgB" "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost" "orderer0.orgb.orgb.fabric.localhost:7050" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"

  printHeadline "Deleting new channel config blocks" "U1F52A"
  deleteNewChannelUpdateTx "consortium-chain" "MSPorgA" "cli.orga.fabric.localhost"
  deleteNewChannelUpdateTx "consortium-chain" "MSPorgB" "cli.orgb.fabric.localhost"
  deleteNewChannelUpdateTx "consortium-chain" "MSPorgC" "cli.orgc.fabric.localhost"
  deleteNewChannelUpdateTx "orgb-chain" "MSPorgB" "cli.orgb.fabric.localhost"
}

upgradeChaincode() {
  local chaincodeName="$1"
  if [ -z "$chaincodeName" ]; then
    echo "Error: chaincode name is not provided"
    exit 1
  fi

  local version="$2"
  if [ -z "$version" ]; then
    echo "Error: chaincode version is not provided"
    exit 1
  fi

  if [ "$chaincodeName" = "consortium-cc-ipfs" ]; then
    if [ -n "$(ls "$CHAINCODES_DIR/cc-ipfs")" ]; then
      printHeadline "Packaging chaincode 'consortium-cc-ipfs'" "U1F60E"
      chaincodeBuild "consortium-cc-ipfs" "node" "$CHAINCODES_DIR/cc-ipfs"
      chaincodePackage "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "node" printHeadline "Installing 'consortium-cc-ipfs' for orgA" "U1F60E"
      chaincodeInstall "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem"
      chaincodeInstall "cli.orga.fabric.localhost" "peer1.orga.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem"
      chaincodeApprove "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orga.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem" ""
      printHeadline "Installing 'consortium-cc-ipfs' for orgB" "U1F60E"
      chaincodeInstall "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
      chaincodeInstall "cli.orgb.fabric.localhost" "peer1.orgb.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
      chaincodeApprove "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orgb.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem" ""
      printHeadline "Installing 'consortium-cc-ipfs' for orgC" "U1F60E"
      chaincodeInstall "cli.orgc.fabric.localhost" "peer0.orgc.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem"
      chaincodeInstall "cli.orgc.fabric.localhost" "peer1.orgc.fabric.localhost:7051" "consortium-cc-ipfs" "$version" "crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem"
      chaincodeApprove "cli.orgc.fabric.localhost" "peer0.orgc.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orgc.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orgc.fabric.localhost-cert.pem" ""
      printItalics "Committing chaincode 'consortium-cc-ipfs' on channel 'consortium-chain' as 'orgA'" "U1F618"
      chaincodeCommit "cli.orga.fabric.localhost" "peer0.orga.fabric.localhost:7051" "consortium-chain" "consortium-cc-ipfs" "$version" "orderer0.consortium.orga.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orga.fabric.localhost-cert.pem" "peer0.orga.fabric.localhost:7051,peer0.orgb.fabric.localhost:7051,peer0.orgc.fabric.localhost:7051" "crypto-peer/peer0.orga.fabric.localhost/tls/ca.crt,crypto-peer/peer0.orgb.fabric.localhost/tls/ca.crt,crypto-peer/peer0.orgc.fabric.localhost/tls/ca.crt" ""

    else
      echo "Warning! Skipping chaincode 'consortium-cc-ipfs' upgrade. Chaincode directory is empty."
      echo "Looked in dir: '$CHAINCODES_DIR/cc-ipfs'"
    fi
  fi
  if [ "$chaincodeName" = "orgb-cc-ipfs" ]; then
    if [ -n "$(ls "$CHAINCODES_DIR/cc-ipfs")" ]; then
      printHeadline "Packaging chaincode 'orgb-cc-ipfs'" "U1F60E"
      chaincodeBuild "orgb-cc-ipfs" "node" "$CHAINCODES_DIR/cc-ipfs"
      chaincodePackage "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-cc-ipfs" "$version" "node" printHeadline "Installing 'orgb-cc-ipfs' for orgB" "U1F60E"
      chaincodeInstall "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
      chaincodeInstall "cli.orgb.fabric.localhost" "peer1.orgb.fabric.localhost:7051" "orgb-cc-ipfs" "$version" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem"
      chaincodeApprove "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-chain" "orgb-cc-ipfs" "$version" "orderer0.orgb.orgb.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem" ""
      printItalics "Committing chaincode 'orgb-cc-ipfs' on channel 'orgb-chain' as 'orgB'" "U1F618"
      chaincodeCommit "cli.orgb.fabric.localhost" "peer0.orgb.fabric.localhost:7051" "orgb-chain" "orgb-cc-ipfs" "$version" "orderer0.orgb.orgb.fabric.localhost:7050" "" "false" "crypto-orderer/tlsca.orgb.fabric.localhost-cert.pem" "peer0.orgb.fabric.localhost:7051" "crypto-peer/peer0.orgb.fabric.localhost/tls/ca.crt" ""

    else
      echo "Warning! Skipping chaincode 'orgb-cc-ipfs' upgrade. Chaincode directory is empty."
      echo "Looked in dir: '$CHAINCODES_DIR/cc-ipfs'"
    fi
  fi
}

stopNetwork() {
  printHeadline "Stopping network" "U1F68F"
  (cd "$FABLO_NETWORK_ROOT"/fabric-docker && docker-compose -f compose.fabric-ca.yaml --project-name "${COMPOSE_PROJECT_NAME}-ca" stop)
  (cd "$FABLO_NETWORK_ROOT"/fabric-docker && docker-compose stop)
  sleep 4
}

networkDown() {
  # Wallet no longers contains valid IDs (all crypto config will be removed further below)
  docker exec ca-client.fabric.localhost sh -c "rm -rf ./wallet" || echo "Failed to remove the CA client application's wallet directory!"

  printHeadline "Destroying network" "U1F916"
  (cd "$FABLO_NETWORK_ROOT"/fabric-docker && docker-compose -f compose.fabric-ca.yaml --project-name "${COMPOSE_PROJECT_NAME}-ca" down)
  (cd "$FABLO_NETWORK_ROOT"/fabric-docker && docker-compose down)

  printf "\nRemoving chaincode containers & images... \U1F5D1 \n"
  docker rm -f $(docker ps -a | grep dev-peer0.orga.fabric.localhost-consortium-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer0.orga.fabric.localhost-consortium-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rm -f $(docker ps -a | grep dev-peer1.orga.fabric.localhost-consortium-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer1.orga.fabric.localhost-consortium-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rm -f $(docker ps -a | grep dev-peer0.orgb.fabric.localhost-consortium-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer0.orgb.fabric.localhost-consortium-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rm -f $(docker ps -a | grep dev-peer1.orgb.fabric.localhost-consortium-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer1.orgb.fabric.localhost-consortium-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rm -f $(docker ps -a | grep dev-peer0.orgc.fabric.localhost-consortium-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer0.orgc.fabric.localhost-consortium-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rm -f $(docker ps -a | grep dev-peer1.orgc.fabric.localhost-consortium-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer1.orgc.fabric.localhost-consortium-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rm -f $(docker ps -a | grep dev-peer0.orgb.fabric.localhost-orgb-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer0.orgb.fabric.localhost-orgb-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rm -f $(docker ps -a | grep dev-peer1.orgb.fabric.localhost-orgb-cc-ipfs_0.0.1-* | awk '{print $1}') || echo "docker rm failed, Check if all fabric dockers properly was deleted"
  docker rmi $(docker images dev-peer1.orgb.fabric.localhost-orgb-cc-ipfs_0.0.1-* -q) || echo "docker rm failed, Check if all fabric dockers properly was deleted"

  printf "\nRemoving generated configs... \U1F5D1 \n"
  rm -rf "$FABLO_NETWORK_ROOT/fabric-config/config"
  rm -rf "$FABLO_NETWORK_ROOT/fabric-config/crypto-config"
  rm -rf "$FABLO_NETWORK_ROOT/fabric-config/chaincode-packages"

  printHeadline "Done! Network was purged" "U1F5D1"
}
