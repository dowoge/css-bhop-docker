#!/usr/bin/env bash
set -euo pipefail

SRCDS_DIR=/server
STEAMCMD=/opt/steamcmd/steamcmd.sh
CSTRIKE_DIR="$SRCDS_DIR/cstrike"

MM_VERSION=${MM_VERSION:-1.12}
SM_VERSION=${SM_VERSION:-1.12}
DISABLED_PLUGINS=${DISABLED_PLUGINS:-}

if [ "$(id -u)" = "0" ]; then
    PUID=${PUID:-1000}
    PGID=${PGID:-1000}
    if [ "$(id -g steam)" != "$PGID" ]; then
        groupmod -o -g "$PGID" steam
    fi
    if [ "$(id -u steam)" != "$PUID" ]; then
        usermod -o -u "$PUID" steam
    fi
    chown steam:steam "$SRCDS_DIR"
    chown -R steam:steam /opt/steamcmd
    exec gosu steam:steam "$0" "$@"
fi

cd "$SRCDS_DIR"

grep -q '^cpu MHz' /proc/cpuinfo || export CPU_MHZ=${CPU_MHZ:-2000}

update_game() {
    "$STEAMCMD" \
        +force_install_dir "$SRCDS_DIR" \
        +login anonymous \
        +app_update 232330 validate \
        +quit
}

echo "==> Installing/updating Counter-Strike: Source dedicated server (app 232330)"
if ! update_game; then
    echo "!! Update failed, clearing stale steamapps/ state and retrying"
    rm -rf "$SRCDS_DIR/steamapps"
    update_game
fi

mkdir -p /home/steam/.steam/sdk32
ln -sf /opt/steamcmd/linux32/steamclient.so /home/steam/.steam/sdk32/steamclient.so

mkdir -p "$CSTRIKE_DIR/addons"

install_metamod() {
    local marker="$CSTRIKE_DIR/addons/metamod/.installed-${MM_VERSION}"
    [ -f "$marker" ] && return
    echo "==> Installing MetaMod:Source $MM_VERSION"
    rm -rf "$CSTRIKE_DIR/addons/metamod" "$CSTRIKE_DIR/addons/metamod.vdf"
    local tarball
    tarball=$(curl -fsSL "https://mms.alliedmods.net/mmsdrop/$MM_VERSION/mmsource-latest-linux")
    curl -fsSL "https://mms.alliedmods.net/mmsdrop/$MM_VERSION/$tarball" | tar -xzf - -C "$CSTRIKE_DIR/"
    touch "$marker"
}

install_sourcemod() {
    local marker="$CSTRIKE_DIR/addons/sourcemod/.installed-${SM_VERSION}"
    [ -f "$marker" ] && return
    echo "==> Installing SourceMod $SM_VERSION"
    rm -rf "$CSTRIKE_DIR/addons/sourcemod"
    local tarball
    tarball=$(curl -fsSL "https://sm.alliedmods.net/smdrop/$SM_VERSION/sourcemod-latest-linux")
    curl -fsSL "https://sm.alliedmods.net/smdrop/$SM_VERSION/$tarball" | tar -xzf - -C "$CSTRIKE_DIR/"
    touch "$marker"
}

install_bhop_map() {
    local map_name="$1" map_url="$2"
    [ -f "$CSTRIKE_DIR/maps/${map_name}.bsp" ] && return 0
    echo "==> Downloading ${map_name} from ${map_url}"
    mkdir -p "$CSTRIKE_DIR/maps"
    local bz
    bz=$(mktemp)
    if ! curl -fsSL "$map_url" -o "$bz"; then
        echo "!! Failed to download ${map_name}"
        rm -f "$bz"
        return 1
    fi
    bunzip2 -c "$bz" > "$CSTRIKE_DIR/maps/${map_name}.bsp"
    rm -f "$bz"
}

SM_DIR="$CSTRIKE_DIR/addons/sourcemod"
MARKS="$SM_DIR/.installed"

want() {
    if [[ " ${DISABLED_PLUGINS//,/ } " == *" $1 "* ]]; then
        [ -f "$MARKS/$1" ] || return 1
        local f
        mkdir -p "$SM_DIR/plugins/disabled"
        while IFS= read -r f; do
            [ -f "$SM_DIR/plugins/$f" ] && mv "$SM_DIR/plugins/$f" "$SM_DIR/plugins/disabled/"
        done < "$MARKS/$1"
        rm -f "$MARKS/$1"
        echo "==> $1 disabled"
        return 1
    fi
    [ ! -f "$MARKS/$1" ]
}

mark_done() {
    local name="$1"
    shift
    mkdir -p "$MARKS"
    printf '%s\n' "$@" > "$MARKS/$name"
    echo "==> $name installed"
}

fetch() {
    local url="$1" dest="$2" f
    f=$(mktemp)
    if ! curl -fsSL "$url" -o "$f"; then
        rm -f "$f"
        return 1
    fi
    case "$url" in
        *.zip) unzip -qo "$f" -d "$dest" ;;
        *)     tar -xzf "$f" -C "$dest" --strip-components=1 ;;
    esac
    rm -f "$f"
}

compile() {
    local sp="$1" out
    if ! out=$("$SM_DIR/scripting/spcomp64" "$sp" \
            -i"$(dirname "$sp")/include" -i"$SM_DIR/scripting/include" \
            -o"$SM_DIR/plugins/$(basename "$sp" .sp).smx" 2>&1); then
        echo "$out"
        echo "!! Failed to compile $(basename "$sp")"
        return 1
    fi
}

latest_asset() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | grep -Eo "https://[^\"]+$2" | head -n1 || true
}

install_ext() {
    local name="$1" url="$2"
    want "$name" || return 0
    echo "==> Installing $name"
    local tmp src
    tmp=$(mktemp -d)
    if ! fetch "$url" "$tmp"; then
        echo "!! Failed to download $name from $url"
        rm -rf "$tmp"
        return 1
    fi
    src=$(find "$tmp" -maxdepth 3 -type d -name addons | head -n1)
    if [ -z "$src" ]; then
        echo "!! Could not locate addons/ in $name archive"
        rm -rf "$tmp"
        return 1
    fi
    cp -a "$src/." "$CSTRIKE_DIR/addons/"
    mark_done "$name" $(find "$src" -name '*.smx' -printf '%f\n')
    rm -rf "$tmp"
}

install_file() {
    local name="$1" url="$2" dest="$3"
    want "$name" || return 0
    echo "==> Installing $name"
    if ! curl -fsSL "$url" -o "$dest"; then
        echo "!! Failed to download $name from $url"
        return 1
    fi
    mark_done "$name" "$(basename "$dest")"
}

install_repo() {
    local lib=0
    [ "$1" = "--lib" ] && { lib=1; shift; }
    local name="$1" repo="$2"
    shift 2
    want "$name" || return 0
    echo "==> Installing $name (github.com/$repo)"
    local tmp d p sp ok=1 smx=()
    tmp=$(mktemp -d)
    if ! fetch "https://github.com/$repo/archive/HEAD.tar.gz" "$tmp"; then
        echo "!! Failed to download $repo"
        rm -rf "$tmp"
        return 1
    fi
    if [ "$lib" = "1" ]; then
        d=$(find "$tmp" -type d -path '*scripting/include' | head -n1)
        [ -n "$d" ] && cp -a "$d/." "$SM_DIR/scripting/include/"
    fi
    for p in "$@"; do
        for sp in $tmp/$p; do
            [ -n "${PATCH:-}" ] && sed -i "$PATCH" "$sp"
            compile "$sp" || ok=0
            smx+=("$(basename "$sp" .sp).smx")
        done
    done
    while IFS= read -r d; do
        mkdir -p "$SM_DIR/$(basename "$d")"
        cp -a "$d/." "$SM_DIR/$(basename "$d")/"
    done < <(find "$tmp" -type d \( -name gamedata -o -name translations \))
    [ -d "$tmp/addons/sourcemod/configs" ] && cp -an "$tmp/addons/sourcemod/configs/." "$SM_DIR/configs/"
    for d in materials sound models; do
        [ -d "$tmp/$d" ] && cp -a "$tmp/$d" "$CSTRIKE_DIR/"
    done
    rm -rf "$tmp"
    [ "$ok" = "1" ] && mark_done "$name" ${smx[@]+"${smx[@]}"}
}

install_sp() {
    local name="$1" url="$2"
    want "$name" || return 0
    echo "==> Installing $name"
    local tmp
    tmp=$(mktemp -d)
    if curl -fsSL "$url" -o "$tmp/$name.sp" && compile "$tmp/$name.sp"; then
        mark_done "$name" "$name.smx"
    fi
    rm -rf "$tmp"
}

install_tickrate_enabler() {
    local tr="${TICKRATE:-100}"
    [[ "$tr" =~ ^[0-9]+$ ]] || return 0
    [ "$tr" -gt 66 ] || return 0
    want tickrate-enabler || return 0
    echo "==> Installing TickrateEnabler (TICKRATE=$tr > 66)"
    local tmp
    tmp=$(mktemp -d)
    if ! fetch https://github.com/rumourA/TickrateEnabler/releases/latest/download/TickrateEnabler-all.zip "$tmp"; then
        echo "!! Failed to download TickrateEnabler"
        rm -rf "$tmp"
        return 1
    fi
    local so_path
    so_path=$(find "$tmp" -type f -name "TickrateEnabler.so" | head -n1)
    if [ -z "$so_path" ]; then
        echo "!! No 32-bit TickrateEnabler .so found in release ZIP"
        rm -rf "$tmp"
        return 1
    fi
    cp "$so_path" "$CSTRIKE_DIR/addons/TickrateEnabler.so"
    cat > "$CSTRIKE_DIR/addons/TickrateEnabler.vdf" <<'VDF'
"Plugin"
{
    "file" "addons/TickrateEnabler"
}
VDF
    rm -rf "$tmp"
    mark_done tickrate-enabler
}

install_plugins() {
    if [ ! -d "$SM_DIR" ]; then
        echo "!! SourceMod not installed, cannot install plugins"
        return 1
    fi
    local connect
    connect=$(curl -fsSL 'https://builds.limetech.io/?project=connect' \
        | grep -Eo 'files/connect-[^"]+-linux\.zip' | head -n1) || true

    install_ext  ripext      "$(latest_asset ErikMinekus/sm-ripext '-linux\.zip')"
    install_ext  steamworks  https://github.com/KyleSanderson/SteamWorks/releases/latest/download/package-lin.tgz
    install_ext  closestpos  https://github.com/rtldg/sm_closestpos/files/15044074/sm_closestpos-sm1.10-ubuntu-20.04-431883d.zip
    install_ext  floppy      "$(latest_asset srcwr/srcwrfloppy '\.zip')"
    install_ext  connect     "https://builds.limetech.io/$connect"
    install_file smbz2       https://github.com/davenonymous/SMbz2/raw/HEAD/bin/smbz2.ext.so "$SM_DIR/extensions/smbz2.ext.so"
    install_tickrate_enabler

    rm -f "$SM_DIR"/extensions/eventqueuefixfix.*

    install_repo --lib sm-json         clugg/sm-json
    install_repo --lib eventqueuefix   hermansimensen/eventqueue-fix     scripting/eventqueuefix.sp
    install_repo --lib bhoptimer       shavitush/bhoptimer               'addons/sourcemod/scripting/shavit-*.sp'
    install_repo       dynamicchannels Vauff/DynamicChannels             scripting/DynamicChannels.sp
    install_repo       bhop-get-stats  dowoge/bhop-get-stats             scripting/bhop-get-stats.sp scripting/jumpstats.sp
    install_repo       showbrushes     dowoge/showbrushes                addons/sourcemod/scripting/showbrushes.sp
    install_repo       wros            mariokeks/wros                    addons/sourcemod/scripting/wros.sp
    install_repo       strafetrainer   2x74/strafetrainer                scripting/strafetrainer.sp
    install_repo       rngfix          jason-e/rngfix                    plugin/scripting/rngfix.sp
    install_ext        momsurffix      "$(latest_asset GAMMACASE/MomSurfFix '\.zip')"
    install_repo       line            happydez/line                     addons/sourcemod/scripting/line.sp
    PATCH='/^native void Shavit_AlsoSaveReplayTo/d' \
    install_repo       myreplay        BoomShotKapow/shavit-myreplay     scripting/shavit-myreplay.sp
    install_repo       getmap          BoomShotKapow/GetMap              scripting/getmap.sp
    install_repo       mpbhops         rtldg/mpbhops_but_working         addons/sourcemod/scripting/mpbhops_but_working.sp
    install_repo       wrsj            rtldg/wrsj                        wrsj.sp
    install_repo       edge-helper     rtldg/edge-helper                 edge-helper.sp
    install_repo       smwhitelist     rtldg/smwhitelist                 addons/sourcemod/scripting/whitelist.sp
    install_repo       bash2           ddyfad/bash2                      scripting/shavit-bash2.sp
    install_repo       superlandfix    ddyfad/superlandfix               scripting/superlandfix.sp
    install_sp         observer-mode-switch-lag-fix https://raw.githubusercontent.com/PMArkive/random-shavit-bhoptimer-stuff/HEAD/observer-mode-switch-lag-fix.sp
    install_sp         client-side-cheats           https://raw.githubusercontent.com/PMArkive/random-shavit-bhoptimer-stuff/HEAD/client-side-cheats.sp
    install_file       offstyledb      https://github.com/offstyles/offstyle-plugins/releases/latest/download/offstyledb.smx "$SM_DIR/plugins/offstyledb.smx"
    install_file       gap             https://github.com/Nairdaa/gap/releases/download/v1.1/gap.smx "$SM_DIR/plugins/gap.smx"

    local wl="$CSTRIKE_DIR/cfg/sourcemod/plugin.whitelist.cfg"
    if [ -f "$SM_DIR/plugins/whitelist.smx" ] && [ ! -f "$wl" ]; then
        mkdir -p "$(dirname "$wl")"
        echo 'whitelist_enabled "0"' > "$wl"
    fi
}

write_server_cfg() {
    local cfg="$CSTRIKE_DIR/cfg/server.cfg"
    [ -f "$cfg" ] && return 0
    mkdir -p "$CSTRIKE_DIR/cfg"
    local tr="${TICKRATE:-100}"
    cat > "$cfg" <<EOF
sv_downloadurl "https://main.fastdl.me/"
sv_allowdownload 1

sv_accelerate 5

sv_minrate 100000
sv_maxrate 0
sv_minupdaterate ${tr}
sv_maxupdaterate ${tr}
sv_mincmdrate ${tr}
sv_maxcmdrate ${tr}

sv_maxvelocity 99999

sv_tags "hidden"

sv_voiceenable 1
sv_alltalk 1
EOF
    echo "==> Wrote default server.cfg at cstrike/cfg/server.cfg"
}

write_databases_cfg() {
    local cfg="$SM_DIR/configs/databases.cfg"
    [ -d "$SM_DIR/configs" ] || return 0
    cat > "$cfg" <<EOF
"Databases"
{
    "driver_default"    "sqlite"

    "default"
    {
        "driver"        "default"
        "database"      "sourcemod-local"
    }

    "storage-local"
    {
        "driver"        "sqlite"
        "database"      "sourcemod-local"
    }

    "shavit"
    {
        "driver"        "sqlite"
        "database"      "shavit"
    }
}
EOF
    echo "==> Wrote databases.cfg with shavit (SQLite) entry"
}

install_metamod
install_sourcemod
install_bhop_map bhop_furame "http://main.fastdl.me/maps/bhop_furame.bsp.bz2" || true
install_plugins || true
write_databases_cfg
write_server_cfg

SV_HOSTNAME=${SV_HOSTNAME:-"CS:S Bhop Server"}
MAP=${MAP:-bhop_furame}
MAXPLAYERS=${MAXPLAYERS:-16}

if [ ! -f "$CSTRIKE_DIR/maps/${MAP}.bsp" ]; then
    echo "!! Map '$MAP' not found at cstrike/maps/${MAP}.bsp"
    echo "   Falling back to de_dust2. Drop ${MAP}.bsp into ./server/cstrike/maps/ to use it."
    MAP=de_dust2
fi
PORT=${PORT:-27015}
TICKRATE=${TICKRATE:-100}
BIND_IP=${BIND_IP:-0.0.0.0}
SV_LAN=${SV_LAN:-1}
BOT_QUOTA=${BOT_QUOTA:-1}
RCON_PASSWORD=${RCON_PASSWORD:-}
SV_PASSWORD=${SV_PASSWORD:-}

cat > "$CSTRIKE_DIR/cfg/docker.cfg" <<EOF
hostname "${SV_HOSTNAME//\"/}"
rcon_password "${RCON_PASSWORD//\"/}"
sv_password "${SV_PASSWORD//\"/}"
EOF

echo "==> Launching srcds_run on $BIND_IP:$PORT, map $MAP"
exec "$SRCDS_DIR/srcds_run" \
    -game cstrike \
    -console \
    -usercon \
    -ip "$BIND_IP" \
    -port "$PORT" \
    -tickrate "$TICKRATE" \
    +map "$MAP" \
    +maxplayers "$MAXPLAYERS" \
    +sv_lan "$SV_LAN" \
    +bot_quota_mode normal \
    +bot_quota "$BOT_QUOTA" \
    +bot_join_after_player 0 \
    +exec docker.cfg \
    "$@"
