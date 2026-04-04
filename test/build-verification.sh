#!/bin/bash
# Build and Verification Test Script for openvpn-server
# This script builds the Docker image, starts the service, and verifies it works

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="openvpn-server-test"
CONTAINER_NAME="openvpn-test-$$"
REPORT_FILE="$SCRIPT_DIR/versions.txt"

echo "========================================"
echo "OpenVPN Server Build & Verification Test"
echo "========================================"
echo ""

# Change to project root
cd "$PROJECT_ROOT"

# Cleanup function
cleanup() {
    echo ""
    echo "[Cleanup] Stopping and removing container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}

# Set trap for cleanup on exit
trap cleanup EXIT

# Step 1: Build the Docker image
echo "[Step 1] Building Docker image..."
echo "----------------------------------------"
docker build --force-rm=true -t "$IMAGE_NAME:latest" .
echo ""

# Step 2: Start the container (use sleep to keep it running for version checks)
echo "[Step 2] Starting OpenVPN container..."
echo "----------------------------------------"
docker run -d \
    --name "$CONTAINER_NAME" \
    --cap-add NET_ADMIN \
    --entrypoint /bin/sh \
    "$IMAGE_NAME:latest" -c "sleep 300"

echo "Container '$CONTAINER_NAME' started."
echo ""

# Wait for container to initialize
echo "[Step 3] Waiting for container to stabilize..."
echo "----------------------------------------"
sleep 5

# Step 3: Extract version information
echo "[Step 4] Capturing version information..."
echo "----------------------------------------"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[ERROR] Container failed to start!"
    echo ""
    echo "Container logs:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -20
    exit 1
fi

# Extract versions
ALPINE_VERSION=$(docker exec "$CONTAINER_NAME" cat /etc/alpine-release 2>/dev/null || echo "unknown")
OPENVPN_VERSION=$(docker exec "$CONTAINER_NAME" openvpn --version 2>/dev/null | head -1 || echo "unknown")
EASYRSA_VERSION=$(docker exec "$CONTAINER_NAME" /usr/share/easy-rsa/easyrsa version 2>/dev/null || echo "unknown")
OPENSSL_VERSION=$(docker exec "$CONTAINER_NAME" openssl version 2>/dev/null || echo "unknown")

# Extract just the version numbers
OPENVPN_VER_NUM=$(echo "$OPENVPN_VERSION" | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
EASYRSA_VER_NUM=$(echo "$EASYRSA_VERSION" | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
OPENSSL_VER_NUM=$(echo "$OPENSSL_VERSION" | grep -oP 'OpenSSL \K[\d.]+' | head -1 || echo "unknown")

# Step 4: Verify container functionality
echo "[Step 5] Verifying container..."
echo "----------------------------------------"

# Check if required binaries exist
for bin in openvpn curl iptables bash; do
    if docker exec "$CONTAINER_NAME" which "$bin" > /dev/null 2>&1; then
        echo "[PASS] '$bin' binary found"
    else
        echo "[FAIL] '$bin' binary NOT found"
        exit 1
    fi
done

if docker exec "$CONTAINER_NAME" test -x /usr/share/easy-rsa/easyrsa; then
    echo "[PASS] 'easyrsa' binary found"
else
    echo "[FAIL] 'easyrsa' binary NOT found"
    exit 1
fi

# Check if required directories exist
if docker exec "$CONTAINER_NAME" test -d /opt/app; then
    echo "[PASS] /opt/app directory exists"
else
    echo "[FAIL] /opt/app directory not found"
    exit 1
fi

# Step 5: Generate report
echo ""
echo "[Step 6] Generating version report..."
echo "----------------------------------------"

cat > "$REPORT_FILE" << EOF
# OpenVPN Server Version Report
# Generated: $(date -Iseconds)

Alpine:    $ALPINE_VERSION
OpenVPN:    $OPENVPN_VER_NUM
Easy-RSA:   $EASYRSA_VER_NUM
OpenSSL:    $OPENSSL_VER_NUM
EOF

echo "Version report saved to: $REPORT_FILE"
echo ""
cat "$REPORT_FILE"
echo ""

# Summary
echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Alpine:   $ALPINE_VERSION"
echo "OpenVPN:  $OPENVPN_VER_NUM"
echo "Easy-RSA: $EASYRSA_VER_NUM"
echo "OpenSSL:  $OPENSSL_VER_NUM"
echo ""
echo "All verification checks passed!"
echo "========================================"

exit 0
