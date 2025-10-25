# Custom Stirling PDF image with RAR support
# Based on official frooodle/s-pdf:1.5.0-fat

FROM frooodle/s-pdf:1.5.0-fat

# Install unrar for CBR to PDF conversion support
USER root
RUN apk add --no-cache unrar

# Switch back to non-root user
USER stirlingpdfuser

# Metadata
LABEL org.opencontainers.image.title="Stirling PDF with RAR support"
LABEL org.opencontainers.image.description="Custom build of Stirling PDF including unrar for CBR conversion"
LABEL org.opencontainers.image.source="https://github.com/AKhozya/homelab"
