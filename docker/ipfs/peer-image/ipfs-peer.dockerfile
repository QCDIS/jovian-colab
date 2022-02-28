# IPFS Peer Container Image With Private Network Bootstrapping and mDNS toggle support

# Default image
ARG IPFS_VERSION="v0.11.0"
FROM "ipfs/go-ipfs:${IPFS_VERSION}"

# Overwrite IPFS's start script
COPY start_ipfs.sh /usr/local/bin/start_ipfs
RUN chmod 0755 /usr/local/bin/start_ipfs