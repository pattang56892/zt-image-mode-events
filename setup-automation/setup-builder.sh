#!/bin/bash
set -x

# Set up the infrastructure environemnt
# Packages are in instances.yaml, turn on libvirtd and set up nss support
systemctl enable --now libvirtd
sed -i 's/hosts:\s\+ files/& libvirt libvirt_guest/' /etc/nsswitch.conf

# Log into terms based registry and stage bootc and bib images
mkdir -p ~/.config/containers
cat <<EOF> ~/.config/containers/auth.json
{
    "auths": {
      "registry.redhat.io": {
        "auth": "${REGISTRY_PULL_TOKEN}"
      }
    }
  }
EOF

# Pull the needed images to minimize waiting during the lab
BOOTC_RHEL_VER=10.1
podman pull registry.redhat.io/rhel10/rhel-bootc:$BOOTC_RHEL_VER registry.redhat.io/rhel10/bootc-image-builder:$BOOTC_RHEL_VER
podman pull quay.io/fedora/fedora-bootc:latest

# Remove pull credentials
# rm ~/.config/containers/auth.json

# set up SSL for fully functioning registry
# Enable EPEL for RHEL 10
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf install -y certbot

# request certificates with retry logic
CERT_DIR="/etc/letsencrypt/live/registry-${GUID}.${DOMAIN}"
CERT_MAX_RETRIES=3
CERT_RETRY=0
while [ $CERT_RETRY -lt $CERT_MAX_RETRIES ]; do
    set +x
    certbot certonly --eab-kid "${ZEROSSL_EAB_KEY_ID}" --eab-hmac-key "${ZEROSSL_HMAC_KEY}" --server "https://acme.zerossl.com/v2/DV90" --standalone --preferred-challenges http -d registry-"${GUID}"."${DOMAIN}" --non-interactive --agree-tos -m trackbot@instruqt.com -v
    rm -f /var/log/letsencrypt/letsencrypt.log
    set -x

    if [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
        echo "SSL certificates obtained successfully" >> /tmp/progress.log
        break
    fi

    CERT_RETRY=$((CERT_RETRY + 1))
    echo "Certificate attempt $CERT_RETRY of $CERT_MAX_RETRIES failed, retrying in 15 seconds..." >> /tmp/progress.log
    sleep 15
done

if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
    echo "FATAL: Failed to obtain SSL certificates after $CERT_MAX_RETRIES attempts" >> /tmp/progress.log
    echo "FATAL: Registry cannot start without TLS certificates. Aborting setup." >> /tmp/progress.log
    exit 1
fi

# set up http based auth for registry
mkdir .auth
podman run --rm --entrypoint htpasswd quay.io/hummingbird/httpd:2 -Bbn core redhat > .auth/htpasswd
podman rmi quay.io/hummingbird/httpd:2

# run a local registry with authentication and the provided certs
podman run --privileged -d \
  --name registry \
  -p 443:5000 \
  -v `pwd`/.auth:/auth:Z  \
  -e "REGISTRY_AUTH=htpasswd" \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
  -v /etc/letsencrypt/live/registry-"${GUID}"."${DOMAIN}"/fullchain.pem:/certs/fullchain.pem \
  -v /etc/letsencrypt/live/registry-"${GUID}"."${DOMAIN}"/privkey.pem:/certs/privkey.pem \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/fullchain.pem \
  -e REGISTRY_HTTP_TLS_KEY=/certs/privkey.pem \
  quay.io/mmicene/registry:2

# Validate registry container is running
sleep 5
if ! podman ps --filter name=registry --format '{{.Names}}' | grep -q registry; then
    echo "FATAL: Registry container failed to start. Checking logs:" >> /tmp/progress.log
    podman logs registry >> /tmp/progress.log 2>&1
    exit 1
fi

# Validate registry is responding (401 = auth required = TLS and registry working)
REG_MAX_RETRIES=5
REG_RETRY=0
while [ $REG_RETRY -lt $REG_MAX_RETRIES ]; do
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://registry-${GUID}.${DOMAIN}/v2/ 2>/dev/null)
    if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "Registry is responding (HTTP $HTTP_CODE)" >> /tmp/progress.log
        break
    fi
    REG_RETRY=$((REG_RETRY + 1))
    echo "Registry not responding yet (HTTP $HTTP_CODE), retry $REG_RETRY of $REG_MAX_RETRIES..." >> /tmp/progress.log
    sleep 5
done

if [ $REG_RETRY -eq $REG_MAX_RETRIES ]; then
    echo "FATAL: Registry is not responding after $REG_MAX_RETRIES attempts. Aborting setup." >> /tmp/progress.log
    podman logs registry >> /tmp/progress.log 2>&1
    exit 1
fi

# Add name based resolution for internal IPs
echo "10.0.2.2 builder.${GUID}.${DOMAIN}" >> /etc/hosts
echo "10.0.2.2 registry-${GUID}.${DOMAIN}" >> /etc/hosts
cp /etc/hosts ~/etc/hosts

# Script that manages the VM SSH session tab
# Waits for the domain to start and networking before attempting to SSH to guest
cat <<'EOF'> /root/.wait_for_bootc_vm.sh
echo "Waiting for VM 'bootc-vm' to be running..."
VM_READY=false
VM_STATE=""
VM_NAME=bootc-vm
while true; do
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$VM_STATE" == "running" ]]; then
        VM_READY=true
        break
    fi
    sleep 10
done
echo "Waiting for SSH to be available..."
NODE_READY=false
while true; do
    if ping -c 1 -W 1 ${VM_NAME} &>/dev/null; then
        NODE_READY=true
        break
    fi
    sleep 5
done
ssh core@${VM_NAME}
EOF

chmod u+x /root/.wait_for_bootc_vm.sh

# Script that manages the VM SSH session tab
# Waits for the domain to start and networking before attempting to SSH to guest
cat <<'EOF'> /root/.wait_for_security_vm.sh
echo "Waiting for VM 'security-vm' to be running..."
VM_READY=false
VM_STATE=""
VM_NAME=security-vm
while true; do
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$VM_STATE" == "running" ]]; then
        VM_READY=true
        break
    fi
    sleep 10
done
echo "Waiting for SSH to be available..."
NODE_READY=false
while true; do
    if ping -c 1 -W 1 ${VM_NAME} &>/dev/null; then
        NODE_READY=true
        break
    fi
    sleep 5
done
ssh core@${VM_NAME}
EOF

chmod u+x /root/.wait_for_security_vm.sh

# Clone the git repo for the application to deploy
git clone --single-branch --branch bootc https://github.com/rhel-labs/python-hostinfo.git /root/bootc-version

# Clone the examples directory and move it to the working home directory
EXAMPLE=examples
TMPDIR=/tmp/lab
git clone --single-branch --branch ${GIT_BRANCH} --no-checkout --depth=1 --filter=tree:0 ${GIT_REPO} $TMPDIR
git -C $TMPDIR sparse-checkout set --no-cone /${EXAMPLE}
git -C $TMPDIR checkout
if [ -d $TMPDIR/${EXAMPLE} ]; then 
    podman login -u core -p redhat registry-${GUID}.${DOMAIN} --authfile=$TMPDIR/$EXAMPLE/auth.json
    cp -r $TMPDIR/${EXAMPLE} /root/${EXAMPLE}
    mv $TMPDIR/${EXAMPLE} ${EXAMPLE}
fi
rm -rf $TMPDIR

mkdir ~/scratch

echo "export GUID=${GUID}" >> /etc/profile.d/lab.sh
echo "export DOMAIN=${DOMAIN}" >> /etc/profile.d/lab.sh
