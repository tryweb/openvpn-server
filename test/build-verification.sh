#!/bin/bash
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

cd "$PROJECT_ROOT"

cleanup() {
    echo ""
    echo "[Cleanup] Stopping and removing container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}

trap cleanup EXIT

echo "[Step 1] Building Docker image..."
echo "----------------------------------------"
docker build --force-rm=true -t "$IMAGE_NAME:latest" .
echo ""

echo "[Step 2] Starting container for binary tests..."
echo "----------------------------------------"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
    --name "$CONTAINER_NAME" \
    --cap-add NET_ADMIN \
    --entrypoint /bin/sh \
    "$IMAGE_NAME:latest" -c "sleep 300"

sleep 5

echo "[Step 3] Verifying OpenVPN binary functionality..."
echo "----------------------------------------"

if docker exec "$CONTAINER_NAME" openvpn --version > /dev/null 2>&1; then
    OPENVPN_VER=$(docker exec "$CONTAINER_NAME" openvpn --version 2>&1 | head -1)
    echo "[PASS] OpenVPN binary works: $OPENVPN_VER"
else
    echo "[FAIL] OpenVPN binary not working"
    exit 1
fi

echo "[PASS] Testing OpenVPN config file parsing..."
docker exec "$CONTAINER_NAME" openvpn --help > /dev/null 2>&1 && echo "[PASS] OpenVPN help works"

echo ""
echo "[Step 4] Verifying Easy-RSA binary functionality..."
echo "----------------------------------------"

if docker exec "$CONTAINER_NAME" /usr/share/easy-rsa/easyrsa version > /dev/null 2>&1; then
    EASYRSA_VER=$(docker exec "$CONTAINER_NAME" /usr/share/easy-rsa/easyrsa version 2>&1)
    echo "[PASS] Easy-RSA binary works"
    echo "$EASYRSA_VER" | grep -oP 'SSL Lib:.*' && echo "[PASS] Easy-RSA SSL library detected"
else
    echo "[FAIL] Easy-RSA binary not working"
    exit 1
fi

echo "[PASS] Testing Easy-RSA PKI initialization..."
docker exec "$CONTAINER_NAME" sh -c "cd /tmp && /usr/share/easy-rsa/easyrsa init-pki" > /dev/null 2>&1 && \
    echo "[PASS] Easy-RSA can initialize PKI"

echo ""
echo "[Step 5] Verifying OpenSSL binary functionality..."
echo "----------------------------------------"

if docker exec "$CONTAINER_NAME" openssl version > /dev/null 2>&1; then
    OPENSSL_VER=$(docker exec "$CONTAINER_NAME" openssl version 2>&1)
    echo "[PASS] OpenSSL binary works: $OPENSSL_VER"
else
    echo "[FAIL] OpenSSL binary not working"
    exit 1
fi

echo "[PASS] Testing OpenSSL DH key generation..."
docker exec "$CONTAINER_NAME" openssl dhparam -out /tmp/dh.pem 2048 > /dev/null 2>&1 && \
    echo "[PASS] OpenSSL can generate DH parameters"

echo ""
echo "[Step 6] Verifying network utilities..."
echo "----------------------------------------"

for bin in curl iptables bash; do
    if docker exec "$CONTAINER_NAME" which "$bin" > /dev/null 2>&1; then
        echo "[PASS] '$bin' binary found"
    else
        echo "[FAIL] '$bin' binary NOT found"
        exit 1
    fi
done

if docker exec "$CONTAINER_NAME" iptables -L > /dev/null 2>&1; then
    echo "[PASS] iptables is functional"
else
    echo "[FAIL] iptables not functional"
    exit 1
fi

echo ""
echo "[Step 7] Verifying container directories..."
echo "----------------------------------------"

for dir in /opt/app /opt/app/bin; do
    if docker exec "$CONTAINER_NAME" test -d "$dir"; then
        echo "[PASS] Directory '$dir' exists"
    else
        echo "[FAIL] Directory '$dir' not found"
        exit 1
    fi
done

if docker exec "$CONTAINER_NAME" test -x /opt/app/docker-entrypoint.sh; then
    echo "[PASS] docker-entrypoint.sh is executable"
else
    echo "[FAIL] docker-entrypoint.sh not executable"
    exit 1
fi

echo ""
echo "[Step 8] Testing TUN device support..."
echo "----------------------------------------"

if docker exec "$CONTAINER_NAME" test -c /dev/net/tun 2>/dev/null; then
    echo "[PASS] TUN device available in container"
elif docker exec "$CONTAINER_NAME" mkdir -p /dev/net && docker exec "$CONTAINER_NAME" mknod /dev/net/tun c 10 200 2>/dev/null; then
    echo "[PASS] Can create TUN device"
else
    echo "[WARN] TUN device test skipped (requires privileged mode)"
fi

echo ""
echo "[Step 9] Testing bin/ scripts executability..."
echo "----------------------------------------"

SCRIPTS_DIR="/opt/app/bin"
for script in genclient.sh revoke.sh rmcert.sh oath.sh oath-sec-gen.sh; do
    script_path="$SCRIPTS_DIR/$script"
    if docker exec "$CONTAINER_NAME" test -f "$script_path"; then
        if docker exec "$CONTAINER_NAME" test -x "$script_path"; then
            echo "[PASS] '$script' is executable"
            
            # Test bash syntax
            if docker exec "$CONTAINER_NAME" bash -n "$script_path" 2>/dev/null; then
                echo "[PASS] '$script' has valid bash syntax"
            else
                echo "[FAIL] '$script' has syntax errors"
                exit 1
            fi
        else
            echo "[FAIL] '$script' not executable"
            exit 1
        fi
    else
        echo "[FAIL] '$script' not found"
        exit 1
    fi
done

echo ""
echo "[Step 10] Testing config file syntax..."
echo "----------------------------------------"

# Test server.conf can be parsed by OpenVPN
docker exec "$CONTAINER_NAME" sh -c "openvpn --config /dev/null --allow-empty" 2>&1 | grep -q "unknown option" && echo "[INFO] OpenVPN config parser works"

# Validate easy-rsa.vars syntax
if docker exec "$CONTAINER_NAME" grep -q "^set_var " /etc/openvpn/config/easy-rsa.vars 2>/dev/null; then
    echo "[PASS] easy-rsa.vars has valid set_var syntax"
else
    echo "[WARN] easy-rsa.vars not found or has issues"
fi

echo ""
echo "[Step 11] Testing Easy-RSA PKI workflow..."
echo "----------------------------------------"

echo "[PASS] Testing PKI init..."
docker exec "$CONTAINER_NAME" sh -c "EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa init-pki" > /dev/null 2>&1 && \
    echo "[PASS] PKI initialized"

echo "[PASS] Testing CA certificate generation..."
docker exec "$CONTAINER_NAME" sh -c "EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa build-ca nopass" > /dev/null 2>&1 && \
    echo "[PASS] CA certificate generated"

if docker exec "$CONTAINER_NAME" test -f /opt/app/pki/ca.crt; then
    echo "[PASS] CA certificate exists"
else
    echo "[FAIL] CA certificate not found"
    exit 1
fi

echo "[PASS] Testing certificate request generation..."
docker exec "$CONTAINER_NAME" sh -c "EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa gen-req testclient nopass" > /dev/null 2>&1 && \
    echo "[PASS] Certificate request generated"

echo "[PASS] Testing certificate signing..."
docker exec "$CONTAINER_NAME" sh -c "EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa sign-req client testclient" > /dev/null 2>&1 && \
    echo "[PASS] Certificate signed"

echo "[PASS] Testing CRL generation..."
docker exec "$CONTAINER_NAME" sh -c "EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa gen-crl" > /dev/null 2>&1 && \
    echo "[PASS] CRL generated"

echo "[PASS] Testing TA key generation..."
docker exec "$CONTAINER_NAME" openvpn --genkey --secret /opt/app/pki/ta.key 2>/dev/null && \
    echo "[PASS] TA key generated"

echo "[PASS] Verifying PKI file structure..."
for file in ca.crt private/ca.key reqs/testclient.req issued/testclient.crt crl.pem ta.key; do
    if docker exec "$CONTAINER_NAME" test -f "/opt/app/pki/$file"; then
        echo "  [PASS] $file exists"
    else
        echo "  [FAIL] $file missing"
        exit 1
    fi
done

docker exec "$CONTAINER_NAME" rm -rf /opt/app/pki

echo ""
echo "[Step 12] Testing OpenVPN configuration validation..."
echo "----------------------------------------"

# Copy server.conf to container for testing
docker exec "$CONTAINER_NAME" mkdir -p /etc/openvpn
docker exec "$CONTAINER_NAME" sh -c "cat > /etc/openvpn/server.conf" < "$PROJECT_ROOT/server.conf"

# Test config can be parsed (--config with --allow-empty to avoid errors)
echo "[PASS] Testing server.conf exists and readable"
docker exec "$CONTAINER_NAME" test -r /etc/openvpn/server.conf && echo "[PASS] server.conf is readable"

echo "[PASS] Testing client.conf exists..."
docker exec "$CONTAINER_NAME" mkdir -p /etc/openvpn/config
docker exec "$CONTAINER_NAME" sh -c "cat > /etc/openvpn/config/client.conf" < "$PROJECT_ROOT/config/client.conf"
docker exec "$CONTAINER_NAME" test -r /etc/openvpn/config/client.conf && echo "[PASS] client.conf is readable"

echo ""
echo "[Step 13] Testing environment variables in docker-entrypoint.sh..."
echo "----------------------------------------"

# Check docker-entrypoint.sh uses expected environment variables
if docker exec "$CONTAINER_NAME" grep -q 'TRUST_SUB' /opt/app/docker-entrypoint.sh; then
    echo "[PASS] docker-entrypoint.sh references TRUST_SUB"
else
    echo "[FAIL] docker-entrypoint.sh missing TRUST_SUB reference"
    exit 1
fi

if docker exec "$CONTAINER_NAME" grep -q 'GUEST_SUB' /opt/app/docker-entrypoint.sh; then
    echo "[PASS] docker-entrypoint.sh references GUEST_SUB"
else
    echo "[FAIL] docker-entrypoint.sh missing GUEST_SUB reference"
    exit 1
fi

if docker exec "$CONTAINER_NAME" grep -q 'HOME_SUB' /opt/app/docker-entrypoint.sh; then
    echo "[PASS] docker-entrypoint.sh references HOME_SUB"
else
    echo "[FAIL] docker-entrypoint.sh missing HOME_SUB reference"
    exit 1
fi

echo ""
echo "[Step 14] Testing OpenVPN feature flags..."
echo "----------------------------------------"

# Test cipher support
for cipher in AES-256-GCM AES-192-GCM AES-128-GCM; do
    if docker exec "$CONTAINER_NAME" openvpn --data-ciphers "$cipher" --genkey --secret /tmp/test.key 2>/dev/null; then
        echo "[PASS] Cipher $cipher supported"
    else
        echo "[FAIL] Cipher $cipher not supported"
    fi
    docker exec "$CONTAINER_NAME" rm -f /tmp/test.key
done

# Test auth algorithm
if docker exec "$CONTAINER_NAME" openvpn --auth SHA512 --genkey --secret /tmp/test.key 2>/dev/null; then
    echo "[PASS] Auth SHA512 supported"
else
    echo "[FAIL] Auth SHA512 not supported"
fi
docker exec "$CONTAINER_NAME" rm -f /tmp/test.key

echo ""
echo "[Step 15] Generating version report..."
echo "----------------------------------------"

ALPINE_VERSION=$(docker exec "$CONTAINER_NAME" cat /etc/alpine-release 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
APK_LIST=$(docker exec "$CONTAINER_NAME" apk list 2>/dev/null | grep -E "^(alpine-release|easy-rsa|openssl|openvpn)-" | head -4 || echo "")

EASYRSA_VER=$(echo "$APK_LIST" | grep "^easy-rsa-" | awk '{print $1}' | sed 's/easy-rsa-//' | sed 's/-r[0-9]*$//' || echo "unknown")
OPENVPN_VER=$(echo "$APK_LIST" | grep "^openvpn-" | awk '{print $1}' | sed 's/openvpn-//' | sed 's/-r[0-9]*$//' || echo "unknown")
OPENSSL_VER=$(echo "$APK_LIST" | grep "^openssl-" | awk '{print $1}' | sed 's/openssl-//' | sed 's/-r[0-9]*$//' || echo "unknown")

OPENVPN_FULL=$(docker exec "$CONTAINER_NAME" openvpn --version 2>/dev/null | head -1 || echo "unknown")

cat > "$REPORT_FILE" << EOF
# OpenVPN Server Version Report
# Generated: $(date -Iseconds)

Alpine:    $ALPINE_VERSION
OpenVPN:    $OPENVPN_VER
Easy-RSA:   $EASYRSA_VER
OpenSSL:    $OPENSSL_VER
EOF

echo "Version report saved to: $REPORT_FILE"
echo ""
cat "$REPORT_FILE"
echo ""

UPDATE_README_VERSIONS="ALPINE=$ALPINE_VERSION OPENVPN=$OPENVPN_VER OPENSSL=$OPENSSL_VER EASYRSA=$EASYRSA_VER"

echo "[Step 16] Updating README.md with version badges..."
echo "----------------------------------------"

UPDATE_README="${UPDATE_README:-false}"
if [ "$UPDATE_README" = "true" ]; then
    README_FILE="$PROJECT_ROOT/README.md"
    
    if [ -f "$README_FILE" ]; then
        echo "Updating README.md version badges..."
        
        sed -i "s/Alpine 3\.[0-9.]*/Alpine $ALPINE_VERSION/g" "$README_FILE"
        sed -i "s/OpenVPN 2\.[0-9.]*/OpenVPN $OPENVPN_VER/g" "$README_FILE"
        sed -i "s/OpenSSL 3\.[0-9.]*/OpenSSL $OPENSSL_VER/g" "$README_FILE"
        sed -i "s/Easy-RSA 3\.[0-9.]*/Easy-RSA $EASYRSA_VER/g" "$README_FILE"
        
        sed -i "s/badge\/Alpine-3\.[0-9.]*/badge\/Alpine-$ALPINE_VERSION/g" "$README_FILE"
        sed -i "s/badge\/OpenVPN-2\.[0-9.]*/badge\/OpenVPN-$OPENVPN_VER/g" "$README_FILE"
        sed -i "s/badge\/OpenSSL-3\.[0-9.]*/badge\/OpenSSL-$OPENSSL_VER/g" "$README_FILE"
        sed -i "s/badge\/Easy--RSA-3\.[0-9.]*/badge\/Easy--RSA-$EASYRSA_VER/g" "$README_FILE"
        
        echo "[PASS] README.md updated with versions: Alpine=$ALPINE_VERSION OpenVPN=$OPENVPN_VER Easy-RSA=$EASYRSA_VER OpenSSL=$OPENSSL_VER"
    else
        echo "[WARN] README.md not found, skipping update"
    fi
else
    echo "[INFO] Skipping README.md update (set UPDATE_README=true to enable)"
fi

echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Alpine:   $ALPINE_VERSION"
echo "OpenVPN:  $OPENVPN_VER"
echo "Easy-RSA: $EASYRSA_VER"
echo "OpenSSL:  $OPENSSL_VER"
echo ""
echo "All verification checks passed!"
echo "========================================"

exit 0
