# BATS Test Helper Functions

# Project root directory
export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Default timeout for waiting
export WAIT_TIMEOUT=120

# Compose file for testing
export COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.test.yml"

# Wait for a service to be healthy
wait_for_healthy() {
    local service=$1
    local timeout=${2:-$WAIT_TIMEOUT}
    local count=0
    
    echo "# Waiting for $service to be healthy (timeout: ${timeout}s)" >&3
    
    while [ $count -lt $timeout ]; do
        local status=$(docker compose -f "$COMPOSE_FILE" ps "$service" --format "{{.Status}}" 2>/dev/null || echo "")
        
        if echo "$status" | grep -qi "healthy"; then
            echo "# $service is healthy after ${count}s" >&3
            return 0
        fi
        
        sleep 1
        ((count++))
    done
    
    echo "# Timeout waiting for $service to be healthy" >&3
    return 1
}

# Wait for a URL to respond
wait_for_url() {
    local url=$1
    local timeout=${2:-60}
    local count=0
    
    echo "# Waiting for $url (timeout: ${timeout}s)" >&3
    
    while [ $count -lt $timeout ]; do
        if curl -sf "$url" > /dev/null 2>&1; then
            echo "# $url is available after ${count}s" >&3
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    echo "# Timeout waiting for $url" >&3
    return 1
}

# Check container logs for a pattern
logs_contain() {
    local service=$1
    local pattern=$2
    
    # First try docker exec to get internal log files
    if [ "$service" = "charger" ]; then
        docker exec everest-charger-charger-1 cat /var/log/supervisor/everest.err 2>/dev/null | grep -q "$pattern" && return 0
    fi
    
    # Fall back to docker compose logs
    docker compose -f "$COMPOSE_FILE" logs "$service" 2>&1 | grep -q "$pattern"
}

# Get charger logs
get_charger_logs() {
    docker compose -f "$COMPOSE_FILE" logs charger 2>&1
}

# Register charger in CitrineOS (required for OCPP 2.0.1/2.1)
# With Security Profile 0, we only need to register the station in the database
register_charger_201() {
    local station_id=${1:-cp001}
    
    echo "# Registering charger $station_id in CitrineOS" >&3
    
    # Wait for CitrineOS API to be available
    local count=0
    while [ $count -lt 60 ]; do
        if curl -sf "http://localhost:8080/" > /dev/null 2>&1 || \
           curl -sf -o /dev/null -w "%{http_code}" "http://localhost:8080/" 2>/dev/null | grep -q "404"; then
            break
        fi
        sleep 1
        ((count++))
    done
    
    # Register charger via database - required for CitrineOS to accept connections
    docker exec everest-charger-ocpp-db-1 psql -U citrine -d citrine -c \
        "INSERT INTO \"ChargingStations\" (id, \"isOnline\", \"createdAt\", \"updatedAt\", \"tenantId\") 
         VALUES ('$station_id', false, NOW(), NOW(), 1) ON CONFLICT (id) DO NOTHING;" 2>/dev/null
    
    echo "# Charger $station_id registered" >&3
}

# Start the test stack
start_stack() {
    local ocpp_version=${1:-2.0.1}
    local ocpp_port=${2:-8082}
    
    export OCPP_VERSION="$ocpp_version"
    export OCPP_PORT="$ocpp_port"
    
    echo "# Starting stack with OCPP $ocpp_version on port $ocpp_port" >&3
    docker compose -f "$COMPOSE_FILE" up -d --build
    
    # Give containers time to start
    sleep 10
    
    # For OCPP 2.0.1/2.1, register charger in CitrineOS
    if [ "$ocpp_version" = "2.0.1" ] || [ "$ocpp_version" = "201" ] || [ "$ocpp_version" = "2.1" ] || [ "$ocpp_version" = "21" ]; then
        # Wait for CitrineOS to be healthy first
        wait_for_healthy "citrine" 120
        register_charger_201 "cp001"
    fi
}

# Stop and clean up the test stack
stop_stack() {
    echo "# Stopping stack" >&3
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
}

# Setup function called before each test file
setup_file() {
    # Ensure clean state
    stop_stack 2>/dev/null || true
}

# Teardown function called after each test file
teardown_file() {
    # Save logs on failure
    if [ -n "$BATS_TEST_FAILED" ]; then
        echo "# Test failed, saving logs..." >&3
        docker compose -f "$COMPOSE_FILE" logs > "${PROJECT_ROOT}/test-logs-$(date +%s).txt" 2>&1 || true
    fi
    
    stop_stack 2>/dev/null || true
}
