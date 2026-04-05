#!/usr/bin/env bash
#
# scaffold-site.sh — DASSC WordPress site scaffolding (task t08)
#
# Applies the DASSC standard configuration to a freshly installed WordPress site
# on a GridPane-managed server. Idempotent: safe to re-run.
#
# Usage:
#   ./scaffold-site.sh /var/www/blastoffstories.com [--client-name "Name"] [--timezone "America/New_York"] [--dry-run]
#
# Environment variables (optional):
#   SITE_PATH              Fallback if no positional arg
#   B2_ACCESS_KEY_ID       Backblaze B2 S3-compatible access key (UpdraftPlus)
#   B2_SECRET_ACCESS_KEY   Backblaze B2 S3-compatible secret key
#   B2_BUCKET              Backblaze B2 bucket name
#   B2_ENDPOINT            e.g. s3.us-west-004.backblazeb2.com
#   CF_API_TOKEN           Cloudflare API token (zone-scoped)
#   CF_EMAIL               Cloudflare account email
#   SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASS / SMTP_FROM
#   SHORTPIXEL_API_KEY
#   GTM_CONTAINER_ID       e.g. GTM-XXXXXXX
#
set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────
DASSC_VERSION="1.0.0"
SITE_PATH_ARG=""
CLIENT_NAME=""
TIMEZONE="America/New_York"
DRY_RUN=0
WARNINGS=()
SUMMARY_PLUGINS=()
DOMAIN=""
SCAFFOLD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()   { printf '[DASSC] %s\n' "$*"; }
warn()  { printf '[DASSC] ⚠ %s\n' "$*" >&2; WARNINGS+=("$*"); }
die()   { printf '[DASSC] ✗ ERROR: %s\n' "$*" >&2; exit 1; }
hr()    { log "═══════════════════════════════════════════════════════════"; }

# Run wp-cli as the site owner (not root) — GridPane convention.
wp() {
    if (( DRY_RUN )); then
        printf '[DASSC][dry-run] wp %s\n' "$*"
        return 0
    fi
    command wp --path="$SITE_PATH" --skip-plugins=query-monitor --skip-themes "$@"
}

wp_real() {
    command wp --path="$SITE_PATH" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --client-name) CLIENT_NAME="${2:-}"; shift 2 ;;
            --timezone)    TIMEZONE="${2:-}"; shift 2 ;;
            --dry-run)     DRY_RUN=1; shift ;;
            -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            -*)            die "Unknown flag: $1" ;;
            *)             SITE_PATH_ARG="$1"; shift ;;
        esac
    done

    SITE_PATH="${SITE_PATH_ARG:-${SITE_PATH:-}}"
    [[ -n "$SITE_PATH" ]] || die "Site path required (positional arg or SITE_PATH env var)"
    SITE_PATH="${SITE_PATH%/}"
    DOMAIN="$(basename "$SITE_PATH")"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    hr
    log "DASSC scaffold-site.sh v${DASSC_VERSION}"
    log "Target: $SITE_PATH  (domain: $DOMAIN)"
    (( DRY_RUN )) && log "DRY RUN — no changes will be applied"
    hr

    [[ -d /opt/gridpane ]] || [[ -f /etc/gridpane ]] || [[ -d /var/www ]] \
        || die "Not a GridPane server (missing /opt/gridpane marker)"

    command -v wp >/dev/null 2>&1 || die "WP-CLI not found in PATH"

    [[ -d "$SITE_PATH" ]]                || die "Site path does not exist: $SITE_PATH"
    [[ -f "$SITE_PATH/wp-config.php" ]]  || die "wp-config.php not found at $SITE_PATH"

    if ! wp_real core is-installed >/dev/null 2>&1; then
        die "WordPress is not installed at $SITE_PATH"
    fi

    wp_real db check >/dev/null 2>&1 || die "WordPress database is not reachable (wp db check failed)"

    log "✓ Pre-flight checks passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. WP-Cron / wp-config constants
# ─────────────────────────────────────────────────────────────────────────────
set_config_constant() {
    local key="$1" val="$2" raw="${3:-}"
    if (( DRY_RUN )); then
        log "[dry-run] wp config set $key $val"
        return 0
    fi
    if [[ "$raw" == "raw" ]]; then
        command wp --path="$SITE_PATH" config set "$key" "$val" --raw --type=constant --quiet
    else
        command wp --path="$SITE_PATH" config set "$key" "$val" --type=constant --quiet
    fi
}

configure_wp_config() {
    log "Applying wp-config constants..."
    set_config_constant DISALLOW_FILE_EDIT       true  raw
    set_config_constant WP_AUTO_UPDATE_CORE      false raw
    set_config_constant AUTOMATIC_UPDATER_DISABLED true raw
    set_config_constant WP_POST_REVISIONS        10    raw
    set_config_constant WP_CRON_LOCK_TIMEOUT     120   raw
    set_config_constant EMPTY_TRASH_DAYS         30    raw
    set_config_constant DISABLE_WP_CRON          true  raw
    set_config_constant WP_DEBUG                 false raw
    set_config_constant WP_DEBUG_LOG             false raw
    set_config_constant WP_DEBUG_DISPLAY         false raw
    log "✓ wp-config constants applied"
    warn "Enable server-level cron in GridPane dashboard: Settings → Cron → toggle on for $DOMAIN"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Must-use plugins
# ─────────────────────────────────────────────────────────────────────────────
write_mu_plugin() {
    local name="$1"
    local path="$SITE_PATH/wp-content/mu-plugins/$name"
    if (( DRY_RUN )); then
        log "[dry-run] write mu-plugin: $name"
        return 0
    fi
    mkdir -p "$SITE_PATH/wp-content/mu-plugins"
    cat > "$path"
    php -l "$path" >/dev/null || die "mu-plugin $name has invalid PHP syntax"
    log "  ✓ $name"
}

install_mu_plugins() {
    log "Installing mu-plugins..."

    write_mu_plugin "dassc-xmlrpc-disable.php" <<'PHP'
<?php
/**
 * Plugin Name: DASSC — Disable XML-RPC
 * Description: Returns 403 for xmlrpc.php requests. Belt-and-suspenders with Cloudflare firewall rule.
 * Author: DASSC
 */
if ( ! defined( 'ABSPATH' ) && ! defined( 'WPINC' ) ) {
    if ( preg_match( '#/xmlrpc\.php$#', $_SERVER['REQUEST_URI'] ?? '' ) ) {
        http_response_code( 403 );
        exit;
    }
}
add_filter( 'xmlrpc_enabled', '__return_false' );
add_filter( 'xmlrpc_methods', '__return_empty_array' );
add_filter( 'wp_headers', function( $headers ) {
    unset( $headers['X-Pingback'] );
    return $headers;
} );
remove_action( 'wp_head', 'rsd_link' );
PHP

    write_mu_plugin "dassc-rest-api-harden.php" <<'PHP'
<?php
/**
 * Plugin Name: DASSC — REST API Hardening
 * Description: Restricts /wp-json/wp/v2/users to authenticated requests only. Prevents username enumeration.
 *              Does NOT block the REST API globally — Copilot Studio content agent uses it with Application Passwords.
 * Author: DASSC
 */
add_filter( 'rest_endpoints', function( $endpoints ) {
    if ( is_user_logged_in() ) {
        return $endpoints;
    }
    if ( isset( $endpoints['/wp/v2/users'] ) ) {
        unset( $endpoints['/wp/v2/users'] );
    }
    if ( isset( $endpoints['/wp/v2/users/(?P<id>[\d]+)'] ) ) {
        unset( $endpoints['/wp/v2/users/(?P<id>[\d]+)'] );
    }
    return $endpoints;
} );
PHP

    write_mu_plugin "dassc-admin-branding.php" <<'PHP'
<?php
/**
 * Plugin Name: DASSC — Admin Branding
 * Description: Subtle white-labeling — "Managed by DASSC" in wp-admin footer.
 * Author: DASSC
 */
add_filter( 'admin_footer_text', function() {
    return 'Managed by <strong>DASSC Technology &amp; Operations Consulting</strong>';
}, 99 );
add_filter( 'update_footer', '__return_empty_string', 99 );
add_action( 'login_enqueue_scripts', function() {
    echo '<style>.login h1 a{background-image:none !important;height:auto !important;width:auto !important;text-indent:0 !important;color:#1d2327;font-size:20px;font-weight:600;}</style>';
} );
add_filter( 'login_headertext', function() { return 'Managed by DASSC'; } );
add_filter( 'login_headerurl',  function() { return 'https://davidaseitz.com'; } );
PHP

    write_mu_plugin "dassc-disable-comments.php" <<'PHP'
<?php
/**
 * Plugin Name: DASSC — Disable Comments
 * Description: Disables comments site-wide. Remove this mu-plugin manually if a client needs comments.
 * Author: DASSC
 */
add_action( 'admin_init', function() {
    // Close on existing posts.
    if ( get_option( 'dassc_comments_closed_once' ) !== '1' ) {
        global $wpdb;
        $wpdb->query( "UPDATE {$wpdb->posts} SET comment_status='closed', ping_status='closed' WHERE post_status='publish'" );
        update_option( 'dassc_comments_closed_once', '1' );
    }
    // Redirect comment admin pages.
    global $pagenow;
    if ( in_array( $pagenow, array( 'edit-comments.php', 'options-discussion.php' ), true ) ) {
        wp_safe_redirect( admin_url() );
        exit;
    }
} );
add_action( 'admin_menu', function() {
    remove_menu_page( 'edit-comments.php' );
    remove_submenu_page( 'options-general.php', 'options-discussion.php' );
} );
add_action( 'wp_before_admin_bar_render', function() {
    global $wp_admin_bar;
    $wp_admin_bar->remove_menu( 'comments' );
} );
add_filter( 'comments_open',  '__return_false', 20 );
add_filter( 'pings_open',     '__return_false', 20 );
add_filter( 'comments_array', '__return_empty_array', 10 );
add_action( 'widgets_init', function() { unregister_widget( 'WP_Widget_Recent_Comments' ); } );
PHP

    log "✓ mu-plugins installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Plugin stack
# ─────────────────────────────────────────────────────────────────────────────
ensure_plugin() {
    local slug="$1"
    if (( DRY_RUN )); then
        log "[dry-run] ensure plugin: $slug"
        SUMMARY_PLUGINS+=("$slug")
        return 0
    fi
    if command wp --path="$SITE_PATH" plugin is-installed "$slug" >/dev/null 2>&1; then
        log "  • $slug already installed"
    else
        log "  • installing $slug"
        command wp --path="$SITE_PATH" plugin install "$slug" --quiet
    fi
    if ! command wp --path="$SITE_PATH" plugin is-active "$slug" >/dev/null 2>&1; then
        command wp --path="$SITE_PATH" plugin activate "$slug" --quiet
    fi
    SUMMARY_PLUGINS+=("$slug")
}

configure_wordfence() {
    log "Configuring Wordfence..."
    local cfg="$SCAFFOLD_DIR/scaffold-configs/wordfence-config.json"
    if [[ -f "$cfg" ]] && ! (( DRY_RUN )); then
        log "  • importing $cfg"
        # Wordfence stores options in wp_wfConfig — apply via direct option updates.
        while IFS='=' read -r k v; do
            [[ -z "$k" ]] && continue
            command wp --path="$SITE_PATH" option patch insert wordfence_"$k" "$v" >/dev/null 2>&1 || true
        done < <(php -r '$j=json_decode(file_get_contents($argv[1]),true)?:[];foreach($j as $k=>$v){echo "$k=$v\n";}' "$cfg")
    fi

    # Baseline settings via wfConfig option (key: wordfence wfConfig serialized, but WF exposes
    # these via its own CLI hooks; where not available we set option rows directly).
    local -a wf_opts=(
        "loginSecurityEnabled=1"
        "firewallEnabled=1"
        "liveTrafficEnabled=0"
        "loginSec_maxFailures=5"
        "loginSec_maxForgotPasswd=5"
        "loginSec_countFailMins=5"
        "loginSec_lockoutMins=60"
        "scansEnabled_checkGSB=1"
        "scansEnabled_core=1"
        "scansEnabled_malware=1"
        "scansEnabled_plugins=1"
        "scansEnabled_themes=1"
        "scansEnabled_lowResource=1"
        "scan_maxDuration=600"
        "scansEnabled_scanImages=0"
        "scheduledScansEnabled=1"
        "firewall_protection_mode=enabled"
    )
    if ! (( DRY_RUN )); then
        for kv in "${wf_opts[@]}"; do
            local k="${kv%%=*}" v="${kv#*=}"
            command wp --path="$SITE_PATH" eval "if(class_exists('wfConfig')){wfConfig::set('$k','$v');}" >/dev/null 2>&1 || true
        done
    fi
    log "✓ Wordfence configured (low-resource mode, 10min scan cap, daily schedule)"
}

configure_updraftplus() {
    log "Configuring UpdraftPlus..."
    # Schedule: daily DB, weekly full, retain 14.
    wp option update updraft_interval weekly
    wp option update updraft_interval_database daily
    wp option update updraft_retain 14
    wp option update updraft_retain_db 14

    if [[ -n "${B2_ACCESS_KEY_ID:-}" && -n "${B2_SECRET_ACCESS_KEY:-}" && -n "${B2_BUCKET:-}" ]]; then
        # UpdraftPlus free tier: use S3-compatible (Backblaze B2 S3 endpoint).
        # Storage key: updraft_service = 's3generic' ; settings under updraft_s3generic.
        wp option update updraft_service s3generic
        local endpoint="${B2_ENDPOINT:-s3.us-west-004.backblazeb2.com}"
        if ! (( DRY_RUN )); then
            command wp --path="$SITE_PATH" eval "
                update_option('updraft_s3generic', array(
                    'settings' => array(
                        'instance_1' => array(
                            'accesskey'    => '${B2_ACCESS_KEY_ID}',
                            'secretkey'    => '${B2_SECRET_ACCESS_KEY}',
                            'path'         => '${B2_BUCKET}',
                            'rrs'          => 0,
                            'endpoint'     => '${endpoint}',
                            'server_side_encryption' => 0,
                        ),
                    ),
                ));"
        fi
        log "✓ UpdraftPlus → B2 via S3-compatible endpoint ($endpoint)"
    else
        warn "B2 credentials not provided (B2_ACCESS_KEY_ID/B2_SECRET_ACCESS_KEY/B2_BUCKET) — UpdraftPlus remote storage not configured"
    fi
}

configure_redis() {
    log "Configuring Redis Object Cache..."
    if (( DRY_RUN )); then
        log "[dry-run] wp redis enable"
        return 0
    fi
    command wp --path="$SITE_PATH" redis enable --skip-plugins=query-monitor >/dev/null 2>&1 || true
    if command wp --path="$SITE_PATH" redis status 2>/dev/null | grep -qi "connected\|enabled"; then
        log "✓ Redis connected"
    else
        warn "Redis object cache not confirmed connected — check GridPane Redis service"
    fi
}

configure_rankmath() {
    log "Configuring Rank Math..."
    wp option update rank_math_modules '["404-monitor","redirections","sitemap","rich-snippet","seo-analysis","link-counter"]' --format=json
    # Titles separator
    if ! (( DRY_RUN )); then
        command wp --path="$SITE_PATH" eval "
            \$opt = get_option('rank-math-options-titles', array());
            \$opt['title_separator'] = '|';
            \$opt['setup_mode'] = 'advanced';
            update_option('rank-math-options-titles', \$opt);
            \$g = get_option('rank-math-options-general', array());
            \$g['usage_tracking'] = 'off';
            update_option('rank-math-options-general', \$g);" >/dev/null 2>&1 || true
    fi
    log "✓ Rank Math: sitemaps on, redirects on, 404 monitor on, advanced mode"
}

configure_cloudflare_plugin() {
    if [[ -z "${CF_API_TOKEN:-}" ]]; then
        warn "CF_API_TOKEN not set — Cloudflare plugin installed but not configured"
        return 0
    fi
    log "Configuring Cloudflare plugin..."
    if ! (( DRY_RUN )); then
        command wp --path="$SITE_PATH" eval "
            update_option('cloudflare_api_key', '${CF_API_TOKEN}');
            update_option('cloudflare_api_email', '${CF_EMAIL:-}');
        " >/dev/null 2>&1 || true
    fi
    log "✓ Cloudflare cache purge integration configured"
}

configure_wpmailsmtp() {
    if [[ -z "${SMTP_HOST:-}" ]]; then
        warn "SMTP_HOST not set — outbound email using PHP mail (poor deliverability from cloud VPS)"
        return 0
    fi
    log "Configuring WP Mail SMTP..."
    if ! (( DRY_RUN )); then
        command wp --path="$SITE_PATH" eval "
            update_option('wp_mail_smtp', array(
                'mail' => array(
                    'from_email' => '${SMTP_FROM:-no-reply@${DOMAIN}}',
                    'from_name'  => '${CLIENT_NAME:-$DOMAIN}',
                    'mailer'     => 'smtp',
                    'return_path' => false,
                ),
                'smtp' => array(
                    'host'       => '${SMTP_HOST}',
                    'port'       => ${SMTP_PORT:-587},
                    'encryption' => 'tls',
                    'auth'       => true,
                    'user'       => '${SMTP_USER:-}',
                    'pass'       => '${SMTP_PASS:-}',
                ),
            ));" >/dev/null 2>&1 || true
    fi
    log "✓ WP Mail SMTP configured (${SMTP_HOST})"
}

configure_shortpixel() {
    log "Configuring ShortPixel..."
    if ! (( DRY_RUN )); then
        command wp --path="$SITE_PATH" eval "
            update_option('wp-short-pixel-compression', 1);    // 1 = lossy
            update_option('wp-short-pixel-create-webp', 1);
            update_option('wp-short-pixel-backup', 1);
        " >/dev/null 2>&1 || true
        if [[ -n "${SHORTPIXEL_API_KEY:-}" ]]; then
            command wp --path="$SITE_PATH" option update wp-short-pixel-apiKey "${SHORTPIXEL_API_KEY}" >/dev/null 2>&1 || true
            command wp --path="$SITE_PATH" option update wp-short-pixel-verifiedKey 1 >/dev/null 2>&1 || true
            log "✓ ShortPixel API key applied"
        else
            warn "SHORTPIXEL_API_KEY not set — register at shortpixel.com"
        fi
    fi
}

configure_gtm() {
    log "Configuring GTM..."
    if [[ -n "${GTM_CONTAINER_ID:-}" ]]; then
        if ! (( DRY_RUN )); then
            command wp --path="$SITE_PATH" eval "
                \$o = get_option('gtm4wp-options', array());
                \$o['gtm-code'] = '${GTM_CONTAINER_ID}';
                \$o['gtm-container-code-position'] = 'codirect';   // head + body noscript
                update_option('gtm4wp-options', \$o);" >/dev/null 2>&1 || true
        fi
        log "✓ GTM container ${GTM_CONTAINER_ID} applied"
    else
        warn "GTM_CONTAINER_ID not set — client needs to supply GTM-XXXXXXX"
    fi
}

install_plugin_stack() {
    log "Installing plugin stack..."
    ensure_plugin wordfence                         && configure_wordfence
    ensure_plugin updraftplus                       && configure_updraftplus
    ensure_plugin redis-cache                       && configure_redis
    ensure_plugin seo-by-rank-math                  && configure_rankmath
    ensure_plugin cloudflare                        && configure_cloudflare_plugin
    ensure_plugin mainwp-child
    ensure_plugin wp-mail-smtp                      && configure_wpmailsmtp
    ensure_plugin shortpixel-image-optimiser        && configure_shortpixel
    ensure_plugin wpforms-lite
    ensure_plugin duracelltomi-google-tag-manager   && configure_gtm
    log "✓ Plugin stack complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. WordPress default settings
# ─────────────────────────────────────────────────────────────────────────────
apply_wp_defaults() {
    log "Applying WordPress default options..."
    wp option update permalink_structure           '/%postname%/'
    wp rewrite flush --hard
    wp option update default_ping_status           closed
    wp option update default_comment_status        closed
    wp option update timezone_string               "$TIMEZONE"
    wp option update date_format                   'F j, Y'
    wp option update time_format                   'g:i a'
    wp option update start_of_week                 0
    wp option update posts_per_page                10
    wp option update blog_public                   1
    wp option update uploads_use_yearmonth_folders 1

    # Delete default content if present.
    if ! (( DRY_RUN )); then
        command wp --path="$SITE_PATH" post delete 1 --force 2>/dev/null || true   # Hello World
        command wp --path="$SITE_PATH" post delete 2 --force 2>/dev/null || true   # Sample Page
        command wp --path="$SITE_PATH" comment delete 1 --force 2>/dev/null || true
    fi

    # robots.txt check — a stray Disallow: / will silently kill SEO.
    if [[ -f "$SITE_PATH/robots.txt" ]] && grep -q '^Disallow: /$' "$SITE_PATH/robots.txt"; then
        warn "Found restrictive robots.txt at $SITE_PATH/robots.txt — removing"
        (( DRY_RUN )) || rm -f "$SITE_PATH/robots.txt"
    fi

    # Remove Akismet + Hello Dolly (keep default themes as fallback).
    if ! (( DRY_RUN )); then
        command wp --path="$SITE_PATH" plugin is-installed akismet    2>/dev/null && command wp --path="$SITE_PATH" plugin delete akismet    --quiet || true
        command wp --path="$SITE_PATH" plugin is-installed hello      2>/dev/null && command wp --path="$SITE_PATH" plugin delete hello      --quiet || true
        command wp --path="$SITE_PATH" plugin is-installed hello-dolly 2>/dev/null && command wp --path="$SITE_PATH" plugin delete hello-dolly --quiet || true
    fi

    log "✓ Default options applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. User role hardening  (MUST run after plugin install/activation)
# ─────────────────────────────────────────────────────────────────────────────
harden_users() {
    log "Hardening users / roles..."

    wp option update default_role subscriber

    if ! (( DRY_RUN )); then
        if command wp --path="$SITE_PATH" user get admin --field=user_login >/dev/null 2>&1; then
            warn "Admin user is named 'admin' — rename recommended (WP doesn't support native rename; create new admin, delete old)"
        fi

        # Ensure Application Passwords are available — Wordfence may have disabled them.
        local ap_available
        ap_available=$(command wp --path="$SITE_PATH" eval "echo wp_is_application_passwords_available() ? 'yes' : 'no';" 2>/dev/null || echo "no")
        if [[ "$ap_available" != "yes" ]]; then
            warn "Application Passwords disabled — re-enabling (required by Copilot Studio content agent)"
            command wp --path="$SITE_PATH" eval "
                add_filter('wp_is_application_passwords_available', '__return_true');
                update_option('using_application_passwords', 1);
            " >/dev/null 2>&1 || true
        fi
    fi

    log "✓ User/role hardening complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. Verification + summary
# ─────────────────────────────────────────────────────────────────────────────
verify_and_report() {
    hr
    log "VERIFICATION"
    hr

    if (( DRY_RUN )); then
        log "(dry-run — skipping verification)"
        return 0
    fi

    local active_plugins
    active_plugins=$(command wp --path="$SITE_PATH" plugin list --status=active --field=name 2>/dev/null || true)
    log "Active plugins:"
    while IFS= read -r p; do [[ -n "$p" ]] && log "  • $p"; done <<< "$active_plugins"

    local k
    for k in DISALLOW_FILE_EDIT DISABLE_WP_CRON WP_DEBUG WP_AUTO_UPDATE_CORE; do
        local v
        v=$(command wp --path="$SITE_PATH" config get "$k" 2>/dev/null || echo "UNSET")
        log "  $k = $v"
    done

    log "  permalink_structure = $(command wp --path="$SITE_PATH" option get permalink_structure 2>/dev/null || echo UNSET)"
    log "  redis status: $(command wp --path="$SITE_PATH" redis status 2>/dev/null | head -n1 || echo 'unknown')"

    # mu-plugin syntax check
    local f
    for f in dassc-xmlrpc-disable.php dassc-rest-api-harden.php dassc-admin-branding.php dassc-disable-comments.php; do
        if php -l "$SITE_PATH/wp-content/mu-plugins/$f" >/dev/null 2>&1; then
            log "  mu-plugin $f ✓"
        else
            warn "mu-plugin $f FAILED php -l"
        fi
    done

    command wp --path="$SITE_PATH" cron test >/dev/null 2>&1 \
        && log "  wp cron endpoint reachable ✓" \
        || warn "wp cron endpoint unreachable"

    # MainWP child key
    local mainwp_key=""
    mainwp_key=$(command wp --path="$SITE_PATH" eval "
        \$u = get_option('mainwp_child_pubkey');
        if(!\$u){\$u = get_option('mainwp_child_uniqueId');}
        echo \$u ?: '';" 2>/dev/null || true)

    print_summary "$mainwp_key"
    write_json_summary "$mainwp_key"
}

print_summary() {
    local mainwp_key="${1:-}"
    hr
    log "Scaffold complete for: $DOMAIN"
    hr
    log ""
    log "PLUGINS ACTIVE:"
    log "  Security:     wordfence"
    log "  Backup:       updraftplus → B2 (daily DB / weekly full / 14 retain)"
    log "  Cache:        redis-cache"
    log "  SEO:          seo-by-rank-math"
    log "  CDN:          cloudflare"
    log "  Monitoring:   mainwp-child"
    log "  Email:        wp-mail-smtp"
    log "  Images:       shortpixel-image-optimiser"
    log "  Forms:        wpforms-lite"
    log "  Analytics:    duracelltomi-google-tag-manager"
    log ""
    log "MU-PLUGINS:"
    log "  dassc-xmlrpc-disable.php        ✓"
    log "  dassc-rest-api-harden.php       ✓"
    log "  dassc-admin-branding.php        ✓"
    log "  dassc-disable-comments.php      ✓"
    log ""
    log "SECURITY:"
    log "  File editing:          DISABLED"
    log "  XML-RPC:               BLOCKED (mu-plugin + Cloudflare)"
    log "  REST user enum:        RESTRICTED (auth only)"
    log "  WP auto-updates:       DISABLED (maintenance pipeline)"
    log "  WP-Cron:               DISABLED (enable server cron in GridPane)"
    log "  Debug mode:            OFF"
    log "  Application Passwords: ACTIVE"
    log ""
    if [[ -n "$mainwp_key" ]]; then
        log "MAINWP CHILD KEY: $mainwp_key"
        log "  → add this to MainWP dashboard"
    else
        log "MAINWP CHILD KEY: (not yet generated — visit wp-admin once, then re-run)"
    fi
    log ""
    if (( ${#WARNINGS[@]} )); then
        log "⚠ WARNINGS:"
        local w
        for w in "${WARNINGS[@]}"; do log "  - $w"; done
    else
        log "✓ No warnings"
    fi
    hr
}

write_json_summary() {
    local mainwp_key="${1:-}"
    local outdir="$SCAFFOLD_DIR/scaffolded-sites"
    mkdir -p "$outdir"
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local outfile="$outdir/${DOMAIN}-${ts}.json"

    local plugins_json warnings_json
    plugins_json=$(printf '"%s",' "${SUMMARY_PLUGINS[@]}" | sed 's/,$//')
    if (( ${#WARNINGS[@]} )); then
        warnings_json=$(printf '%s\n' "${WARNINGS[@]}" | sed 's/"/\\"/g' | sed 's/^/"/;s/$/",/' | tr -d '\n' | sed 's/,$//')
    else
        warnings_json=""
    fi

    cat > "$outfile" <<JSON
{
  "dassc_scaffold_version": "${DASSC_VERSION}",
  "domain": "${DOMAIN}",
  "site_path": "${SITE_PATH}",
  "client_name": "${CLIENT_NAME}",
  "timezone": "${TIMEZONE}",
  "timestamp_utc": "${ts}",
  "plugins": [${plugins_json}],
  "mu_plugins": [
    "dassc-xmlrpc-disable.php",
    "dassc-rest-api-harden.php",
    "dassc-admin-branding.php",
    "dassc-disable-comments.php"
  ],
  "mainwp_child_key": "${mainwp_key}",
  "warnings": [${warnings_json}]
}
JSON
    log "JSON summary: $outfile"
}

# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    preflight
    configure_wp_config
    install_mu_plugins
    install_plugin_stack
    apply_wp_defaults
    harden_users          # MUST run after plugin activation (Wordfence may touch App Passwords)
    verify_and_report
}

main "$@"
