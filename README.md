# EVerest DCFC

A multi-arch container that makes it easy to spin up a virtual DCFC for testing.

## Features

- **Multi-Architecture**: Supports ARM64 (Apple Silicon, Raspberry Pi) and AMD64
- **OCPP Support**: Configurable OCPP version (1.6, 2.0.1, 2.1) via environment variable
- **Charging Profiles**: Full support for smart charging profiles
- **Node-RED Dashboard**: Visual interface for simulation control and monitoring
- **Debug Build**: Full debug symbols for detailed crash stack traces

## Quick Start

### Build the Image

```bash
docker build -t everest-ocpp .
```

### Run the Container

Create a network w/ IPv6 enabled:
```
docker network create --ipv6 ip6net
```

Basic usage with OCPP 1.6:

```bash
docker run -d \
  --name everest \
  --network ip6net \
  -p 1880:1880 \
  -e OCPP_VERSION=1.6 \
  -e OCPP_URL=ws://your-csms-server:9000 \
  -e OCPP_ID=CP001 \
  everest-ocpp
```

Using OCPP 2.0.1:

```bash
docker run -d \
  --name everest \
  --network ip6net \
  -p 1880:1880 \
  -e OCPP_VERSION=2.0.1 \
  -e OCPP_URL=ws://your-csms-server:9000 \
  -e OCPP_ID=CP001 \
  everest-ocpp
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OCPP_VERSION` | `1.6` | OCPP version to use. Options: `1.6`, `2.0.1`, `2.1` |
| `OCPP_URL` | `ws://localhost:9000` | WebSocket URL of the CSMS (Central System) |
| `OCPP_ID` | `CP1` | Charge Point ID for OCPP registration |

## Accessing the Interfaces

Once the container is running:

- **Node-RED Dashboard**: http://localhost:1880/ui
- **Node-RED Editor**: http://localhost:1880

## Node-RED Dashboard Features

The included Node-RED dashboard provides:

- **Car Simulation Controls**: Plugin/Unplug simulated EV
- **Charging Controls**: Pause/Resume charging sessions
- **Current Slider**: Adjust max charging current
- **Monitoring**: Real-time power, voltage, temperature display
- **State Display**: Current charging state

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Docker Container                    │
│  ┌─────────────────────────────────────────────┐    │
│  │              Supervisord (PID 1)             │    │
│  └─────────────┬──────────┬──────────┬─────────┘    │
│                │          │          │              │
│  ┌─────────┐   │  ┌───────┴───────┐  │  ┌────────┐  │
│  │Mosquitto│◄──┤  │   EVerest     │  ├─►│Node-RED│  │
│  │  :1883  │   │  │   Manager     │  │  │ :1880  │  │
│  └─────────┘   │  └───────────────┘  │  └────────┘  │
│       ▲        │          │          │       │      │
│       │        │          ▼          │       │      │
│       │        │  ┌───────────────┐  │       │      │
│       └────────┴──│  OCPP Client  │──┴───────┘      │
│                   │  (1.6/2.0.1)  │                  │
│                   └───────┬───────┘                  │
└───────────────────────────┼─────────────────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │     CSMS      │
                    │  (External)   │
                    └───────────────┘
```

## File Structure

```
├── Dockerfile              # Multi-stage build for EVerest
├── entrypoint.sh           # Startup script with config injection
├── supervisord.conf        # Process manager configuration
├── config-ocpp16.yaml      # EVerest config for OCPP 1.6
├── config-ocpp201.yaml     # EVerest config for OCPP 2.0.1/2.1
├── ocpp-config-16.json     # OCPP 1.6 protocol configuration
├── ocpp-config-201.json    # OCPP 2.0.1 protocol configuration
├── flows.json              # Node-RED dashboard flows
└── README.md               # This file
```

## Charging Profile Support

This container includes full support for OCPP Smart Charging profiles:

- **OCPP 1.6**: `SetChargingProfile`, `ClearChargingProfile`, `GetCompositeSchedule`
- **OCPP 2.0.1**: Smart Charging feature profile with enhanced scheduling

The EnergyManager module processes charging profiles and adjusts the charging current accordingly.

## Debugging

This container is built with full debug symbols (`-g3 -ggdb`) for better crash diagnostics. When a crash occurs, stack traces will include:

- Function names
- Source file names
- Line numbers

### What Happens When a Crash Occurs

When a crash occurs (like the buffer overflow), the container will:

1. Print the error message to stdout/stderr (captured in docker logs)
2. Generate a core dump file at `/tmp/everest-logs/core.*` (if enabled)
3. The error will include memory addresses that can be resolved with debug symbols

### Analyzing Crashes

```bash
# View container logs for crash information
docker logs everest

# Copy crash logs out of the container
docker cp everest:/tmp/everest-logs/ ./crash-logs/

# If core dumps are available, analyze with gdb
docker exec -it everest gdb /usr/local/bin/manager /tmp/everest-logs/core.*
```

### GDB Commands for Crash Analysis

Once in gdb with a core dump:

```gdb
# Show the stack trace
bt

# Show full stack trace with local variables
bt full

# Show source code context (if available)
list

# Print variable values
print <variable_name>
```

## Troubleshooting

### View Logs

```bash
# All logs
docker logs everest

# Follow logs
docker logs -f everest

# Specific service logs (exec into container)
docker exec -it everest tail -f /var/log/supervisor/everest.log
docker exec -it everest tail -f /var/log/supervisor/nodered.log
docker exec -it everest tail -f /var/log/supervisor/mosquitto.log

# Check for core dumps after a crash
docker exec -it everest ls -la /tmp/everest-logs/
```

### Check Service Status

```bash
docker exec -it everest supervisorctl status
```

### MQTT Debugging

```bash
# Subscribe to all EVerest topics
docker exec -it everest mosquitto_sub -t 'everest/#' -v
```

## References

- [EVerest Documentation](https://everest.github.io/nightly/)
- [EVerest Core Repository](https://github.com/EVerest/everest-core)
- [EVerest Demo](https://github.com/EVerest/everest-demo)
- [OCPP Specification](https://www.openchargealliance.org/protocols/ocpp-201/)

## License

Apache 2.0 - See the EVerest project for full license details.
