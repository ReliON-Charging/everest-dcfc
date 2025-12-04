#!/bin/bash
set -e

echo "=== EVerest Container Startup ==="

# --- Configuration Variables ---
OCPP_VERSION="${OCPP_VERSION:-1.6}"
OCPP_URL="${OCPP_URL:-ws://localhost:9000}"
OCPP_ID="${OCPP_ID:-CP1}"
OCPP_AUTH_PASSWORD="${OCPP_AUTH_PASSWORD:-DEADBEEFDEADBEEF}"

echo "OCPP Version: $OCPP_VERSION"
echo "OCPP URL: $OCPP_URL"
echo "OCPP ID: $OCPP_ID"

# --- Directory Setup ---
mkdir -p /etc/everest
mkdir -p /var/lib/everest/ocpp201
mkdir -p /var/log/supervisor
mkdir -p /tmp/everest-logs/ocpp
mkdir -p /home/everest/.node-red

# Verify persistent store directory is writable (used by PersistentStore module for reservation storage)
if [ ! -w /var/lib/everest ]; then
    echo "Warning: /var/lib/everest is not writable - reservations will not persist"
fi

# Initialize persistent store with empty reservations if database doesn't exist
PERSISTENT_DB="/var/lib/everest/persistent_store.db"
if [ ! -f "$PERSISTENT_DB" ]; then
    echo "Initializing persistent store database..."
    sqlite3 "$PERSISTENT_DB" <<SQLEOF
CREATE TABLE IF NOT EXISTS KVS (KEY TEXT UNIQUE, VALUE TEXT, TYPE TEXT);
INSERT OR REPLACE INTO KVS (KEY, VALUE, TYPE) VALUES ('reservation_auth', '[]', 'Array');
SQLEOF
    echo "  - Created $PERSISTENT_DB with empty reservations"
fi

# --- Select Configuration Based on OCPP Version ---
echo "Selecting configuration for OCPP $OCPP_VERSION..."

case "$OCPP_VERSION" in
    "1.6"|"16"|"OCPP1.6"|"ocpp1.6")
        echo "Using OCPP 1.6 configuration"
        CONFIG_TEMPLATE="/etc/everest/templates/config-ocpp16.yaml"
        OCPP_JSON_TEMPLATE="/etc/everest/templates/ocpp-config-16.json"
        ;;
    "2.0.1"|"201"|"OCPP2.0.1"|"ocpp2.0.1")
        echo "Using OCPP 2.0.1 configuration"
        CONFIG_TEMPLATE="/etc/everest/templates/config-ocpp201.yaml"
        OCPP_JSON_TEMPLATE="/etc/everest/templates/ocpp-config-201.json"
        USE_DEVICE_MODEL=true
        # OCPP20 = OCPP 2.0.1 only (no 2.1 fallback)
        OCPP_WS_VERSION="OCPP20"
        # Only advertise ocpp2.0.1 protocol (no 2.1)
        SUPPORTED_OCPP_VERSIONS="ocpp2.0.1"
        ;;
    "2.1"|"21"|"OCPP2.1"|"ocpp2.1")
        echo "Using OCPP 2.1 configuration"
        CONFIG_TEMPLATE="/etc/everest/templates/config-ocpp201.yaml"
        OCPP_JSON_TEMPLATE="/etc/everest/templates/ocpp-config-201.json"
        USE_DEVICE_MODEL=true
        # OCPP21 = OCPP 2.1 (may fall back to 2.0.1)
        OCPP_WS_VERSION="OCPP21"
        # Advertise both protocols with 2.1 preferred
        SUPPORTED_OCPP_VERSIONS="ocpp2.1,ocpp2.0.1"
        ;;
    *)
        echo "ERROR: Unknown OCPP version '$OCPP_VERSION'"
        echo "Supported versions: 1.6, 2.0.1, 2.1"
        exit 1
        ;;
esac

# --- Generate Active Configuration ---
echo "Generating EVerest configuration..."

# Copy base config
cp "$CONFIG_TEMPLATE" /etc/everest/config.yaml

# Process OCPP JSON config with jq
# Replace placeholders with actual values
jq --arg url "$OCPP_URL" --arg id "$OCPP_ID" '
    # Handle OCPP 1.6 format
    if .Internal then
        .Internal.ChargePointId = $id |
        .Internal.CentralSystemURI = ($url + "/" + $id)
    else
        .
    end |
    # Handle OCPP 2.0.1 format
    if .InternalCtrlr then
        .InternalCtrlr.ChargePointId = $id |
        .InternalCtrlr.NetworkConnectionProfiles[0].connectionData.ocppCsmsUrl = $url |
        .SecurityCtrlr.Identity = $id
    else
        .
    end
' "$OCPP_JSON_TEMPLATE" > /etc/everest/ocpp-config.json

echo "Configuration files generated:"
echo "  - /etc/everest/config.yaml"
echo "  - /etc/everest/ocpp-config.json"

# --- Setup OCPP 2.0.1 Device Model ---
if [ "${USE_DEVICE_MODEL:-false}" = "true" ]; then
    echo "Setting up OCPP 2.0.1 device model configuration..."
    
    DEVICE_MODEL_DB="/var/lib/everest/ocpp201/device_model.db"
    DEFAULT_CONFIG_DIR="/usr/local/share/everest/modules/OCPP201/component_config"
    CONFIG_DIR="/var/lib/everest/ocpp201/component_config"
    INTERNAL_DB="/usr/local/share/everest/modules/OCPP201/everest_device_model_storage.db"
    
    # Remove any old databases to force fresh initialization from updated configs
    rm -f "$DEVICE_MODEL_DB"
    rm -f "$INTERNAL_DB"
    
    # Create config directories and copy defaults
    mkdir -p "$CONFIG_DIR/standardized"
    mkdir -p "$CONFIG_DIR/custom"
    cp -r "$DEFAULT_CONFIG_DIR/standardized/"* "$CONFIG_DIR/standardized/" 2>/dev/null || true
    cp -r "$DEFAULT_CONFIG_DIR/custom/"* "$CONFIG_DIR/custom/" 2>/dev/null || true
    
    # Note: EVSE and Connector component configs are created automatically by the OCPP201 module
    # based on the connected evse_managers. Do NOT add custom configs that duplicate those variables
    # as it causes "Component variable source already exists" warnings and potential issues.
    
    # Update NetworkConnectionProfiles - replace the CSMS URL
    # Note: Security profile 0 (no auth) for consistency with OCPP 1.6
    # Note: Don't append OCPP_ID to URL - libocpp appends the ChargePointId automatically
    # Build the NetworkConnectionProfiles as proper JSON (jq will handle escaping)
    # OCPP_WS_VERSION is set based on OCPP_VERSION: OCPP20 for 2.0.1, OCPP21 for 2.1
    echo "  Using OCPP WebSocket version: $OCPP_WS_VERSION"
    NETWORK_JSON=$(cat <<EOF
[{"configurationSlot": 1, "connectionData": {"messageTimeout": 30, "ocppCsmsUrl": "${OCPP_URL}", "ocppInterface": "Wired0", "ocppTransport": "JSON", "ocppVersion": "${OCPP_WS_VERSION}", "securityProfile": 0}}]
EOF
)
    
    # Use jq to update InternalCtrlr.json in BOTH locations:
    # - Set ChargePointId to OCPP_ID
    # - Update NetworkConnectionProfiles with the CSMS URL
    # - Enable AllowSecurityLevelZeroConnections for security profile 0
    # - Set SupportedOcppVersions to control which protocols are advertised
    # 
    # We must update both the runtime config AND the default config because
    # the OCPP201 module's "composed device model" reads from multiple sources
    echo "  Supported OCPP versions: $SUPPORTED_OCPP_VERSIONS"
    for CONFIG_FILE in "$CONFIG_DIR/standardized/InternalCtrlr.json" "$DEFAULT_CONFIG_DIR/standardized/InternalCtrlr.json"; do
        if [ -f "$CONFIG_FILE" ]; then
            jq --arg profiles "$NETWORK_JSON" --arg cpid "$OCPP_ID" --arg versions "$SUPPORTED_OCPP_VERSIONS" '
              .properties.ChargePointId.attributes[0].value = $cpid |
              .properties.NetworkConnectionProfiles.attributes[0].value = $profiles |
              .properties.AllowSecurityLevelZeroConnections.default = true |
              .properties.AllowSecurityLevelZeroConnections.attributes[0].value = true |
              .properties.SupportedOcppVersions.attributes[0].value = $versions |
              .properties.SupportedOcppVersions.default = $versions
            ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
              && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
    done
    
    # Fix NetworkConfigurationPriority type bug in libocpp default config (integer 1 -> string "1")
    for COMM_CONFIG in "$CONFIG_DIR/standardized/OCPPCommCtrlr.json" "$DEFAULT_CONFIG_DIR/standardized/OCPPCommCtrlr.json"; do
        if [ -f "$COMM_CONFIG" ]; then
            jq '
              .properties.NetworkConfigurationPriority.attributes[0].value = "1"
            ' "$COMM_CONFIG" > "${COMM_CONFIG}.tmp" \
              && mv "${COMM_CONFIG}.tmp" "$COMM_CONFIG"
        fi
    done
    
    # Update SecurityCtrlr for Security Profile 0 (no authentication)
    # Also update both the runtime config AND the default config
    for SEC_CONFIG in "$CONFIG_DIR/standardized/SecurityCtrlr.json" "$DEFAULT_CONFIG_DIR/standardized/SecurityCtrlr.json"; do
        if [ -f "$SEC_CONFIG" ]; then
            # Set SecurityProfile to 0, SecurityCtrlrIdentity to OCPP_ID, and update BasicAuthPassword
            jq --arg password "$OCPP_AUTH_PASSWORD" --arg cpid "$OCPP_ID" '
              .properties.SecurityProfile.attributes[0].value = 0 |
              .properties.SecurityProfile.default = 0 |
              .properties.SecurityCtrlrIdentity.attributes[0].value = $cpid |
              .properties.BasicAuthPassword.attributes[0].value = $password |
              .properties.BasicAuthPassword.default = $password
            ' "$SEC_CONFIG" > "${SEC_CONFIG}.tmp" \
              && mv "${SEC_CONFIG}.tmp" "$SEC_CONFIG"
        fi
    done
    
    echo "Device model configuration created:"
    echo "  ChargePointId: $OCPP_ID"
    echo "  CSMS URL: $OCPP_URL/$OCPP_ID"
    echo "  Component configs: $CONFIG_DIR"
fi

# --- Setup Node-RED ---
echo "Setting up Node-RED..."

# Copy flows if not already present
if [ ! -f /home/everest/.node-red/flows.json ]; then
    cp /etc/everest/templates/flows.json /home/everest/.node-red/flows.json
fi

# Create Node-RED settings file
cat > /home/everest/.node-red/settings.js << 'EOF'
module.exports = {
    flowFile: 'flows.json',
    userDir: '/home/everest/.node-red',
    httpAdminRoot: '/admin',
    httpNodeRoot: '/',
    uiHost: '0.0.0.0',
    uiPort: 1880,
    debugMaxLength: 1000,
    functionGlobalContext: {},
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        }
    },
    editorTheme: {
        projects: {
            enabled: false
        }
    }
};
EOF

# --- Setup Mosquitto ---
echo "Setting up Mosquitto..."

mkdir -p /etc/mosquitto
cat > /etc/mosquitto/mosquitto.conf << 'EOF'
listener 1883
allow_anonymous true
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information
EOF

# --- Display Startup Info ---
echo ""
echo "=== Configuration Summary ==="
echo "OCPP Version: $OCPP_VERSION"
echo "OCPP URL: $OCPP_URL"
echo "OCPP ID: $OCPP_ID"
echo ""
echo "Services:"
echo "  - Mosquitto (MQTT): localhost:1883"
echo "  - Node-RED Dashboard: http://localhost:1880/dashboard"
echo "  - Node-RED Editor: http://localhost:1880/admin"
echo ""
echo "=== Starting Supervisord ==="

# --- Start Supervisor ---
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
