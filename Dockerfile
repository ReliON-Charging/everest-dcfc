# =============================================================================
# EVerest OCPP Client Docker Image (Debug Build)
# Supports: ARM64 (Apple Silicon, RPi) and AMD64
# OCPP Versions: 1.6, 2.0.1, 2.1 (configurable via environment variable)
# 
# This is a DEBUG container with full debug symbols for better crash diagnostics.
# Stack traces will include function names and line numbers.
# =============================================================================

# --- Build Stage ---
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    python3 \
    python3-pip \
    python3-venv \
    pkg-config \
    libboost-all-dev \
    libssl-dev \
    libsqlite3-dev \
    libcurl4-openssl-dev \
    libpcap-dev \
    libevent-dev \
    libnode-dev \
    nodejs \
    npm \
    maven \
    openjdk-17-jdk \
    rsync \
    curl \
    jq \
    libcap-dev \
    nlohmann-json3-dev \
    libpugixml-dev \
    libyaml-cpp-dev \
    libwebsocketpp-dev \
    libfmt-dev \
    libsystemd-dev \
    && rm -rf /var/lib/apt/lists/*

# Install EVerest Dependency Manager (edm)
RUN python3 -m pip install --break-system-packages git+https://github.com/EVerest/everest-dev-environment.git@main#subdirectory=dependency_manager

# Clone EVerest Core with specific version
WORKDIR /workspace
ARG EVEREST_VERSION=2025.10.0
RUN git clone --depth 1 --branch ${EVEREST_VERSION} https://github.com/EVerest/everest-core.git

# Apply YetiSimulator patch to support configurable max current for DC charging
# This allows max_current_A_import to be set via config instead of hardcoded 32A
COPY patches/yeti-simulator/ /workspace/everest-core/modules/Simulation/YetiSimulator/

# Apply EvseManager patch to enforce EVSE DC current limits
# This ensures the power supply respects CSMS charging profiles even if EV requests more
COPY patches/evse-manager/EvseManager.cpp /workspace/everest-core/modules/EVSE/EvseManager/EvseManager.cpp

# Build EVerest with debug symbols for better crash diagnostics
# Debug build: no optimization, full debug symbols, frame pointers preserved
# This gives us detailed stack traces with file names and line numbers
WORKDIR /workspace/everest-core
RUN mkdir -p build && cd build && \
    echo "Building with debug symbols enabled..." && \
    cmake .. \
        -DBUILD_TESTING=OFF \
        -DCMAKE_BUILD_TYPE=Debug \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DEVEREST_ENABLE_JS_SUPPORT=ON \
        -DEVEREST_ENABLE_RS_SUPPORT=OFF \
        -DFETCHCONTENT_QUIET=OFF \
        -DCMAKE_C_FLAGS="-fno-omit-frame-pointer -g3 -ggdb" \
        -DCMAKE_CXX_FLAGS="-fno-omit-frame-pointer -g3 -ggdb" \
    && make -j$(nproc) \
    && make install

# --- Runtime Stage ---
FROM ubuntu:24.04

LABEL org.opencontainers.image.source="https://github.com/EVerest/everest-core"
LABEL org.opencontainers.image.description="EVerest OCPP Client with Node-RED Dashboard (Debug Build)"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/lib"

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    supervisor \
    mosquitto \
    mosquitto-clients \
    jq \
    curl \
    ca-certificates \
    sqlite3 \
    # Python for PyEvJosev module
    python3 \
    python3-pip \
    # Boost runtime libraries
    libboost-program-options1.83.0 \
    libboost-log1.83.0 \
    libboost-system1.83.0 \
    libboost-thread1.83.0 \
    libboost-filesystem1.83.0 \
    libboost-chrono1.83.0 \
    libboost-regex1.83.0 \
    # Other runtime libs
    libssl3 \
    libsqlite3-0 \
    libcurl4 \
    libpcap0.8 \
    libevent-2.1-7 \
    libevent-pthreads-2.1-7 \
    libcap2 \
    libyaml-cpp0.8 \
    libfmt9 \
    libpugixml1v5 \
    # Java runtime for some modules
    openjdk-17-jre-headless \
    # Node.js for JS modules and Node-RED
    nodejs \
    npm \
    # Debug tools for crash analysis
    gdb \
    binutils \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for PyEvJosev (ISO 15118 EV simulation)
# From https://github.com/EVerest/ext-switchev-iso15118/requirements.txt
RUN pip3 install --break-system-packages \
    "environs>=9.5.0" \
    "pydantic==1.*" \
    "psutil>=5.9.1" \
    "cryptography>=3.4.6" \
    "aiofile>=3.7.4" \
    "py4j>=0.10.9.5" \
    "netifaces>=0.11.0" \
    "python-dateutil>=2.8.2"

# Install Node-RED and FlowFuse Dashboard 2.0
RUN npm install -g --unsafe-perm \
    node-red@3.1.0 \
    @flowfuse/node-red-dashboard

# Copy EVerest from builder
COPY --from=builder /usr/local /usr/local

# Create non-root user (use UID/GID 10000 to avoid conflicts with existing users)
RUN groupadd -g 10000 everest && \
    useradd -u 10000 -g everest -m -s /bin/bash everest

# Create required directories with correct ownership
RUN mkdir -p /etc/everest/templates \
    /etc/supervisor/conf.d \
    /var/lib/everest/ocpp201 \
    /var/log/supervisor \
    /tmp/everest-logs/ocpp \
    /home/everest/.node-red \
    /etc/mosquitto \
    /run/mosquitto && \
    chown -R everest:everest /etc/everest /var/lib/everest /var/log/supervisor \
        /tmp/everest-logs /home/everest/.node-red /etc/mosquitto /run/mosquitto

# Fix OCPP module permissions for non-root user
# OCPP 1.6: Create empty user_config.json (required by module)
# OCPP 2.0.1: Allow writing to module directory for database storage
RUN echo '{}' > /usr/local/share/everest/modules/OCPP/user_config.json && \
    chown -R everest:everest /usr/local/share/everest/modules/OCPP \
        /usr/local/share/everest/modules/OCPP201

# Copy configuration templates
COPY config-ocpp16.yaml /etc/everest/templates/config-ocpp16.yaml
COPY config-ocpp201.yaml /etc/everest/templates/config-ocpp201.yaml
COPY ocpp-config-16.json /etc/everest/templates/ocpp-config-16.json
COPY ocpp-config-201.json /etc/everest/templates/ocpp-config-201.json
COPY device_model.sql /etc/everest/templates/device_model.sql
RUN sqlite3 /etc/everest/templates/device_model.db < /etc/everest/templates/device_model.sql
COPY flows.json /etc/everest/templates/flows.json

# Copy supervisor configuration
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose ports
# 1880: Node-RED Dashboard and Editor
# 1883: MQTT (internal, exposed for debugging)
EXPOSE 1880 1883

# Environment variables with defaults
ENV OCPP_VERSION="1.6"
ENV OCPP_URL="ws://localhost:9000"
ENV OCPP_ID="CP1"

# Health check (check Node-RED admin endpoint)
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:1880/admin/ || exit 1

# Run as non-root user
USER everest

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
