FROM gcr.io/datadoghq/private-action-runner:v1.17.1
USER root

# Install kubectl via direct download - detect architecture
RUN ARCH=$(uname -m) && \
    case $ARCH in \
        x86_64) KUBECTL_ARCH="amd64" ;; \
        aarch64|arm64) KUBECTL_ARCH="arm64" ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -LO "https://dl.k8s.io/release/v1.29.0/bin/linux/${KUBECTL_ARCH}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

# Copy MCP tool scripts
COPY scripts/ /scripts/
RUN chmod -R +x /scripts/

USER dog
