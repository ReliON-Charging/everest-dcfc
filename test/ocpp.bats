#!/usr/bin/env bats

# EVerest OCPP Client Integration Tests
# Tests connectivity with CitrineOS CSMS for OCPP 1.6, 2.0.1, and 2.1

load 'test_helper'

# =============================================================================
# OCPP 1.6 Tests
# =============================================================================

@test "OCPP 1.6: Stack starts successfully" {
    start_stack "1.6" "8092"
    
    # Wait for CitrineOS to be healthy
    run wait_for_healthy "citrine" 120
    [ "$status" -eq 0 ]
    
    # Wait for charger to be healthy  
    run wait_for_healthy "charger" 60
    [ "$status" -eq 0 ]
}

@test "OCPP 1.6: Node-RED is accessible" {
    run wait_for_url "http://localhost:1880/" 30
    [ "$status" -eq 0 ]
}

@test "OCPP 1.6: CitrineOS responds" {
    # CitrineOS returns 404 for root, but that means it's up
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/"
    [ "$output" = "404" ]
}

@test "OCPP 1.6: EVerest started successfully" {
    # Wait for EVerest to fully initialize
    sleep 15
    run logs_contain "charger" "EVerest up and running"
    [ "$status" -eq 0 ]
}

@test "OCPP 1.6: OCPP client connected to CSMS" {
    run logs_contain "charger" "OCPP client successfully connected"
    [ "$status" -eq 0 ]
}

@test "OCPP 1.6: Cleanup" {
    stop_stack
}

# =============================================================================
# OCPP 2.0.1 Tests
# =============================================================================

@test "OCPP 2.0.1: Stack starts successfully" {
    start_stack "2.0.1" "8081"
    
    # Wait for CitrineOS to be healthy
    run wait_for_healthy "citrine" 120
    [ "$status" -eq 0 ]
    
    # Wait for charger to be healthy  
    run wait_for_healthy "charger" 90
    [ "$status" -eq 0 ]
}

@test "OCPP 2.0.1: Node-RED is accessible" {
    run wait_for_url "http://localhost:1880/" 30
    [ "$status" -eq 0 ]
}

@test "OCPP 2.0.1: CitrineOS responds" {
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/"
    [ "$output" = "404" ]
}

@test "OCPP 2.0.1: EVerest started successfully" {
    sleep 20
    run logs_contain "charger" "EVerest up and running"
    [ "$status" -eq 0 ]
}

@test "OCPP 2.0.1: Device model database initialized" {
    run docker exec everest-charger-charger-1 test -f /var/lib/everest/ocpp201/device_model.db
    [ "$status" -eq 0 ]
}

@test "OCPP 2.0.1: OCPP client connected to CSMS" {
    # OCPP201 module logs connection success with version info
    run logs_contain "charger" "OCPP client successfully connected"
    [ "$status" -eq 0 ]
}

@test "OCPP 2.0.1: Cleanup" {
    stop_stack
}

# =============================================================================
# OCPP 2.1 Tests
# Uses same OCPP201 module as 2.0.1, but verifies 2.1 version selection works
# =============================================================================

@test "OCPP 2.1: Stack starts successfully" {
    start_stack "2.1" "8081"
    
    # Wait for CitrineOS to be healthy
    run wait_for_healthy "citrine" 120
    [ "$status" -eq 0 ]
    
    # Wait for charger to be healthy  
    run wait_for_healthy "charger" 90
    [ "$status" -eq 0 ]
}

@test "OCPP 2.1: Node-RED is accessible" {
    run wait_for_url "http://localhost:1880/" 30
    [ "$status" -eq 0 ]
}

@test "OCPP 2.1: CitrineOS responds" {
    run curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/"
    [ "$output" = "404" ]
}

@test "OCPP 2.1: EVerest started successfully" {
    sleep 20
    run logs_contain "charger" "EVerest up and running"
    [ "$status" -eq 0 ]
}

@test "OCPP 2.1: Device model database initialized" {
    run docker exec everest-charger-charger-1 test -f /var/lib/everest/ocpp201/device_model.db
    [ "$status" -eq 0 ]
}

@test "OCPP 2.1: OCPP201 module is used" {
    # Verify the OCPP201 module is being used (same as 2.0.1)
    run logs_contain "charger" "OCPP201"
    [ "$status" -eq 0 ]
}

@test "OCPP 2.1: OCPP client connected to CSMS" {
    # OCPP201 module logs connection success with version info
    run logs_contain "charger" "OCPP client successfully connected"
    [ "$status" -eq 0 ]
}

@test "OCPP 2.1: Cleanup" {
    stop_stack
}
