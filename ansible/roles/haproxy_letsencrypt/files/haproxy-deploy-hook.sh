#!/bin/bash
# /etc/letsencrypt/renewal-hooks/deploy/haproxy.sh
# certbot renew runs every executable in this directory once per renewed
# certificate; certonly does not, so pass it there with --deploy-hook.

set -e

HAPROXY_CERT_DIR="/etc/haproxy/certs"
HAPROXY_SOCKET="/run/haproxy/admin.sock"
LOG_FILE="/var/log/certbot-haproxy.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

update_haproxy_cert() {
    local domain=$1
    local cert_path="$HAPROXY_CERT_DIR/$domain.pem"
    local le_cert="/etc/letsencrypt/live/$domain"
    
    # Combine certificates
    cat "$le_cert/fullchain.pem" "$le_cert/privkey.pem" > "$cert_path"
    chmod 600 "$cert_path"
    
    # HAProxy stopped (Method 2's pre-hook): it loads the new file when it starts
    if ! systemctl is-active --quiet haproxy; then
        log "HAProxy not running, $domain is loaded at start"
        return 0
    fi
    
    # Try runtime update first (HAProxy 2.4+)
    if [ -S "$HAPROXY_SOCKET" ]; then
        if echo "show ssl cert $cert_path" | socat stdio "$HAPROXY_SOCKET" 2>/dev/null | grep -q "$cert_path"; then
            # Certificate exists, update in-place: payload first, commit in a
            # separate session (HAProxy 3.2 and later ignore a commit sent after the payload)
            {
                echo "set ssl cert $cert_path <<"
                cat "$cert_path"
                echo ""
            } | socat stdio "$HAPROXY_SOCKET" 2>/dev/null
            
            if echo "commit ssl cert $cert_path" | socat stdio "$HAPROXY_SOCKET" 2>/dev/null | grep -q "Success"; then
                log "Updated certificate for $domain via runtime API"
                return 0
            fi
        fi
    fi
    
    # Fallback to reload
    systemctl reload haproxy
    log "Reloaded HAProxy for $domain"
}

# Process the renewed certificate (RENEWED_LINEAGE is /etc/letsencrypt/live/<name>;
# RENEWED_DOMAINS lists every name on it, which may not have a live directory of its own)
domain=$(basename "$RENEWED_LINEAGE")
log "Processing renewal for $domain"
update_haproxy_cert "$domain"
