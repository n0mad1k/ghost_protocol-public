#!/bin/bash
# OPSEC Widget Launcher — positions and launches the Conky widget
# Usage: opsec-widget-launch.sh [position]
#
# Positions:
#   tl = top-left       tc = top-center       tr = top-right
#   bl = bottom-left    bc = bottom-center     br = bottom-right
#
# Default: tr (top-right)
# Uses the theme system — regenerates config from /etc/opsec/themes/

CONKY_DIR="$HOME/.config/conky"
CONF="$CONKY_DIR/conky-opsec-widget.conf"
POS="${1:-tr}"

# Map shorthand to conky alignment + gaps
case "$POS" in
    tl) ALIGN="top_left";     GAP_X=15;  GAP_Y=15 ;;
    tc) ALIGN="top_middle";   GAP_X=0;   GAP_Y=15 ;;
    tr) ALIGN="top_right";    GAP_X=15;  GAP_Y=60 ;;
    bl) ALIGN="bottom_left";  GAP_X=15;  GAP_Y=60 ;;
    bc) ALIGN="bottom_middle"; GAP_X=0;  GAP_Y=60 ;;
    br) ALIGN="bottom_right"; GAP_X=15;  GAP_Y=60 ;;
    *)
        echo "Usage: $(basename "$0") [tl|tc|tr|bl|bc|br]"
        echo ""
        echo "  tl = top-left       tc = top-center       tr = top-right"
        echo "  bl = bottom-left    bc = bottom-center     br = bottom-right"
        exit 1
        ;;
esac

# Kill existing widget and stale cache daemon
killall conky 2>/dev/null
pkill -f 'conky-opsec-cache\.sh' 2>/dev/null
rm -f /tmp/.opsec-cache/netinfo 2>/dev/null
sleep 0.3

# Load theme from opsec config
OPSEC_CONF="/etc/opsec/opsec.conf"
THEME="default"
[ -f "$OPSEC_CONF" ] && THEME=$(grep "^WIDGET_THEME=" "$OPSEC_CONF" 2>/dev/null | cut -d'"' -f2)
[ -z "$THEME" ] && THEME="default"

THEME_FILE="/etc/opsec/themes/${THEME}.theme"
if [ -f "$THEME_FILE" ]; then
    . "$THEME_FILE"
else
    echo "Theme '${THEME}' not found, using defaults"
    THEME_LABEL="Default"
    CONKY_BG="0d1117"
    CONKY_COLOR0="df2020"; CONKY_COLOR1="33ff33"; CONKY_COLOR2="3a8fd6"
    CONKY_COLOR3="0d1117"; CONKY_COLOR4="1f6feb"; CONKY_COLOR5="58a6ff"
    CONKY_COLOR6="79c0ff"; CONKY_COLOR7="c9d1d9"; CONKY_COLOR8="1f6feb"
    CONKY_COLOR9="484f58"
fi

# Generate config with theme colors and chosen position
mkdir -p "$CONKY_DIR"
cat > "$CONF" << EOF
-- OPSEC Status Widget — OPSEC Status Widget
-- Theme: ${THEME} (${THEME_LABEL:-Custom})
-- Position: ${ALIGN}

conky.config = {
    alignment = '${ALIGN}',
    gap_x = ${GAP_X},
    gap_y = ${GAP_Y},
    minimum_width = 400,
    minimum_height = 200,
    maximum_width = 420,

    own_window = true,
    own_window_type = 'normal',
    own_window_transparent = false,
    own_window_argb_visual = true,
    own_window_argb_value = 210,
    own_window_colour = '${CONKY_BG:-0d1117}',
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',

    xinerama_head = 0,

    double_buffer = true,
    draw_shades = true,
    default_shade_color = '000000',
    draw_outline = false,
    draw_borders = true,
    border_inner_margin = 12,
    border_outer_margin = 4,
    border_width = 1,
    border_colour = '${CONKY_COLOR4:-1f6feb}',
    stippled_borders = 0,

    use_xft = true,
    font = 'JetBrains Mono:size=10',
    override_utf8_locale = true,

    default_color = 'b0b0b0',
    color0 = '${CONKY_COLOR0:-df2020}',
    color1 = '${CONKY_COLOR1:-33ff33}',
    color2 = '${CONKY_COLOR2:-3a8fd6}',
    color3 = '${CONKY_COLOR3:-0d1117}',
    color4 = '${CONKY_COLOR4:-1f6feb}',
    color5 = '${CONKY_COLOR5:-58a6ff}',
    color6 = '${CONKY_COLOR6:-79c0ff}',
    color7 = '${CONKY_COLOR7:-c9d1d9}',
    color8 = '${CONKY_COLOR8:-1f6feb}',
    color9 = '${CONKY_COLOR9:-484f58}',

    update_interval = 3,
    total_run_times = 0,

    cpu_avg_samples = 2,
    no_buffers = true,
    text_buffer_size = 8192,
    short_units = true,
};

conky.text = [[
\${execpi 5 ~/.config/conky/conky-opsec-status.sh}
]];
EOF

# Launch
conky -c "$CONF" &
disown
echo "OPSEC widget launched: $ALIGN (theme: $THEME)"
