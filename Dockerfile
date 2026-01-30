# =============================================================================
# SPAIK n8n Enterprise Evaluation Build
# Full source build with all enterprise features enabled
# =============================================================================

ARG NODE_VERSION=22.22.0

# =============================================================================
# Stage 1: Builder - Install dependencies and build from source
# =============================================================================
FROM node:${NODE_VERSION}-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    python3 \
    py3-pip \
    make \
    g++ \
    git \
    openssh

# Enable corepack for pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

WORKDIR /build

# Set environment variables for build
# DOCKER_BUILD=true skips lefthook install in prepare script
# CI=true is also recognized by the prepare script
ENV DOCKER_BUILD=true
ENV CI=true

# Copy all necessary files for pnpm install
# Order matters: package files first, then patches, scripts, packages
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json .npmrc ./
COPY patches/ ./patches/
COPY scripts/ ./scripts/

# Copy all packages
COPY packages/ ./packages/

# Install all dependencies
# DOCKER_BUILD=true ensures prepare script skips lefthook
RUN pnpm install --frozen-lockfile

# Generate grammar files for codemirror-lang-html (gitignored, must be generated)
RUN pnpm --filter=@n8n/codemirror-lang-html run grammar:build

# Build the application
RUN pnpm build

# Copy trim script and run it (optional - for smaller production builds)
COPY .github/scripts/ ./.github/scripts/
RUN if [ -f .github/scripts/trim-fe-packageJson.js ]; then \
        node .github/scripts/trim-fe-packageJson.js || true; \
    fi

# Create pruned production deployment
# Remove unused patches from package.json before deploy (these patches are for dev deps only)
RUN node -e "const p=require('./package.json'); \
    if(p.pnpm?.patchedDependencies) { \
      delete p.pnpm.patchedDependencies['element-plus@2.4.3']; \
      delete p.pnpm.patchedDependencies['z-vue-scan']; \
      delete p.pnpm.patchedDependencies['v-code-diff']; \
    } \
    require('fs').writeFileSync('./package.json', JSON.stringify(p, null, 2));" && \
    NODE_ENV=production pnpm --filter=n8n --prod --legacy deploy --no-optional ./compiled

# =============================================================================
# Stage 2: Production - Runtime image with Python support
# =============================================================================
FROM node:${NODE_VERSION}-alpine AS production

# Install runtime dependencies including Python 3 for task runners
# Also include build tools temporarily for sqlite3 native rebuild
RUN apk add --no-cache \
    git \
    openssh \
    openssl \
    graphicsmagick \
    tini \
    tzdata \
    ca-certificates \
    libc6-compat \
    python3 \
    py3-pip \
    make \
    g++ && \
    # Install full-icu for internationalization
    npm install -g full-icu@1.5.0 && \
    # Cleanup
    rm -rf /tmp/* /root/.npm /root/.cache

# Set environment variables
ENV NODE_ENV=production
ENV NODE_ICU_DATA=/usr/local/lib/node_modules/full-icu
ENV SHELL=/bin/sh

# SPAIK Enterprise Evaluation Mode - enables all enterprise features
ENV N8N_ENTERPRISE_EVALUATION=true

# n8n configuration defaults
ENV N8N_PORT=5678
ENV N8N_HOST=0.0.0.0
ENV N8N_PROTOCOL=https
ENV N8N_SECURE_COOKIE=true

# Database defaults
ENV DB_TYPE=sqlite
ENV DB_SQLITE_VACUUM_ON_STARTUP=true

# Task runner configuration
ENV N8N_RUNNERS_MODE=internal

# Debug/logging for security testing
ENV N8N_LOG_LEVEL=info

WORKDIR /app

# Copy compiled application from builder
COPY --from=builder /build/compiled /app

# Setup user and permissions first (handle case where they might exist)
RUN (addgroup -g 1000 n8n || true) && \
    (adduser -u 1000 -G n8n -s /bin/sh -D n8n || true) && \
    mkdir -p /app/data

# Try sqlite3 rebuild (may fail if prebuilt works)
RUN cd /app && npm rebuild sqlite3 || true

# Create symlink and set ownership
# Debug: show what's in /app
RUN ls -la /app && ls -la /app/bin 2>/dev/null || echo "No bin dir" && \
    (test -f /app/bin/n8n && ln -sf /app/bin/n8n /usr/local/bin/n8n) || \
    echo "n8n binary not at expected location, checking alternatives..." && \
    find /app -name "n8n" -type f 2>/dev/null | head -5 && \
    chown -R n8n:n8n /app

# Entrypoint script
COPY <<'ENTRYPOINT' /docker-entrypoint.sh
#!/bin/sh
set -e

# Handle Railway's PORT environment variable
if [ -n "$PORT" ]; then
    export N8N_PORT=$PORT
fi

# Create data directory if needed
mkdir -p /app/data

# Generate encryption key if not exists and not provided
if [ ! -f /app/data/encryption.key ] && [ -z "$N8N_ENCRYPTION_KEY" ]; then
    head -c 32 /dev/urandom | base64 > /app/data/encryption.key
    export N8N_ENCRYPTION_KEY=$(cat /app/data/encryption.key)
    echo "Generated new encryption key"
fi

# Trust custom certificates if provided
if [ -d /opt/custom-certificates ]; then
    echo "Trusting custom certificates from /opt/custom-certificates."
    export NODE_OPTIONS="--use-openssl-ca $NODE_OPTIONS"
    export SSL_CERT_DIR=/opt/custom-certificates
    c_rehash /opt/custom-certificates
fi

echo "============================================="
echo "  SPAIK n8n Enterprise Evaluation Instance"
echo "============================================="
echo "  Port: ${N8N_PORT:-5678}"
echo "  Host: ${N8N_HOST:-0.0.0.0}"
echo "  DB Type: ${DB_TYPE:-sqlite}"
echo "  Enterprise Mode: ${N8N_ENTERPRISE_EVALUATION:-false}"
echo "============================================="

if [ "$#" -gt 0 ]; then
    exec n8n "$@"
else
    exec n8n
fi
ENTRYPOINT
RUN chmod +x /docker-entrypoint.sh

# Expose default n8n port
EXPOSE 5678

# Switch to non-root user
USER n8n

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${N8N_PORT:-5678}/healthz || exit 1

# Use tini as init process
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

# Labels
LABEL org.opencontainers.image.title="n8n-spaik-enterprise" \
      org.opencontainers.image.description="n8n Enterprise Evaluation - SPAIK Security Testing" \
      org.opencontainers.image.source="https://github.com/n8n-io/n8n"
