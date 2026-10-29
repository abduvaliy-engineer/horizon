#!/usr/bin/env bash
# Build and play from the player's installed Minecraft files. Never downloads Minecraft.
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
chosen=${HORIZON_MINECRAFT_DIR:-}
server=${HORIZON_SERVER_JAR:-}
install=1
check=0
prepare_only=0
game_args=()
die() { printf 'Horizon: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: ./play-installed.sh [OPTIONS] [-- GAME_ARGUMENTS...]

Find an installed Minecraft release, build Horizon, import resources and sounds,
and play. Minecraft files are never downloaded or changed.

  --minecraft-dir PATH  Custom launcher/game folder (also HORIZON_MINECRAFT_DIR)
  --server-jar PATH     Existing matching server JAR (also HORIZON_SERVER_JAR)
  --check               Only check installed game files; no installs or launch
  --no-install          Report missing build tools instead of installing them
  --prepare-only        Build and prepare, without opening the game
  -h, --help            Show this help

Linux: apt, pacman, dnf and zypper are supported. Missing native dependencies use sudo;
Rust uses rustup, and a missing JDK is installed inside this checkout's .local/.
The first build downloads Rust crates. Later runs reuse Cargo's build cache.
EOF
}
while (($#)); do
    case "$1" in
        --minecraft-dir|--server-jar)
            (($# >= 2)) && [[ -n $2 ]] || die "$1 needs a path"
            if [[ $1 == --minecraft-dir ]]; then chosen=$2; else server=$2; fi
            shift 2 ;;
        --check) check=1; install=0; shift ;;
        --no-install) install=0; shift ;;
        --prepare-only) prepare_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; game_args=("$@"); break ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
[[ $(uname -s) == Linux ]] || die 'This source-build script currently supports Linux.'

native_dependencies() {
    ((install)) || die 'Missing build dependencies; rerun without --no-install to install them.'
    local elevate=()
    if ((EUID != 0)); then
        command -v sudo >/dev/null || die 'Install sudo or install the dependencies manually.'
        elevate=(sudo)
    fi
    if command -v pacman >/dev/null; then
        "${elevate[@]}" pacman -S --needed base-devel cmake pkgconf alsa-lib systemd-libs \
            libxkbcommon wayland vulkan-icd-loader git curl jq ca-certificates tar
    elif command -v apt-get >/dev/null; then
        "${elevate[@]}" apt-get update
        "${elevate[@]}" apt-get install build-essential cmake pkg-config libasound2-dev \
            libudev-dev libxkbcommon-dev libwayland-dev libvulkan1 git curl jq ca-certificates tar
    elif command -v dnf >/dev/null; then
        "${elevate[@]}" dnf install gcc gcc-c++ make cmake pkgconf-pkg-config alsa-lib-devel \
            systemd-devel libxkbcommon-devel wayland-devel vulkan-loader git curl jq ca-certificates tar
    elif command -v zypper >/dev/null; then
        "${elevate[@]}" zypper install gcc gcc-c++ make cmake pkg-config alsa-devel \
            libudev-devel libxkbcommon-devel wayland-devel libvulkan1 git curl jq ca-certificates tar
    else
        die 'Install a C/C++ toolchain, cmake, pkg-config, ALSA/udev/Wayland/xkbcommon headers, Vulkan, git, curl, jq and tar.'
    fi
}
if ! command -v jq >/dev/null; then
    ((check == 0)) || die 'Install jq to check the installed game files.'
    native_dependencies
fi
version=$(jq -er '.minecraft.version' "$project/research-lock.json")
java_major=$(jq -er '.minecraft.java_major' "$project/research-lock.json")
client_hash=$(jq -er '.minecraft.client_sha1' "$project/research-lock.json")
server_hash=$(jq -er '.minecraft.server_sha1' "$project/research-lock.json")
mapfile -t manifest_hashes < <(jq -r '.minecraft | .manifest_sha1, .accepted_manifest_sha1[]?' "$project/research-lock.json")
sha1() { sha1sum -- "$1" | cut -d ' ' -f 1; }
valid_manifest() {
    local hash allowed
    hash=$(sha1 "$1")
    for allowed in "${manifest_hashes[@]}"; do [[ $hash != "$allowed" ]] || return 0; done
    return 1
}

# Check conventional roots, including Flatpak and launchers with a meta/ subfolder.
# A chosen folder is authoritative: never silently use another install instead.
roots=()
if [[ -n $chosen ]]; then
    roots=("$chosen")
else
    data=${XDG_DATA_HOME:-$HOME/.local/share}
    config=${XDG_CONFIG_HOME:-$HOME/.config}
    roots=("$HOME/.minecraft" "$HOME/.var/app/com.mojang.Minecraft/.minecraft"
        "$data/PrismLauncher" "$data/multimc" "$data/MultiMC" "$data/ModrinthApp"
        "$data/com.modrinth.theseus" "$data/atlauncher" "$data/ATLauncher"
        "$data/gdlauncher_carbon" "$config/gdlauncher_next"
        "$HOME/Documents/curseforge/minecraft/Install"
        "$HOME/curseforge/minecraft/Install"
        "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher"
        "$HOME/.var/app/com.modrinth.ModrinthApp/data/ModrinthApp"
        "$HOME/.var/app/com.atlauncher.ATLauncher/data/atlauncher")
fi
bases=()
for root in "${roots[@]}"; do
    [[ -d $root ]] || continue
    root=$(cd -- "$root" && pwd)
    bases+=("$root" "$root/meta" "$root/cache")
    # Also accept an instance's .minecraft/ folder or an instances/ directory.
    ancestor=$root
    for ((depth=0; depth<4; depth++)); do
        [[ $(basename -- "$ancestor") != instances ]] || bases+=("$(dirname -- "$ancestor")")
        ancestor=$(dirname -- "$ancestor")
    done
done
base_found= client_found= manifest_found=
for base in "${bases[@]}"; do
    [[ -d $base/libraries && -d $base/assets ]] || continue
    client=
    while IFS= read -r -d '' candidate; do
        if [[ $(sha1 "$candidate") == "$client_hash" ]]; then client=$candidate; break; fi
    done < <(find "$base" -maxdepth 8 -type f \
        \( -name "*$version*.jar" -o -name client.jar \) -print0)
    [[ -n $client ]] || continue
    manifest=
    while IFS= read -r -d '' candidate; do
        if valid_manifest "$candidate"; then manifest=$candidate; break; fi
    done < <(find "$base" -maxdepth 8 -type f -name "*$version*.json" -print0)
    # A previously imported Mojang manifest also works with rewritten launcher metadata.
    cached="$project/.local/minecraft/$version/manifest.json"
    if [[ -z $manifest && -f $cached ]] && valid_manifest "$cached"; then manifest=$cached; fi
    [[ -n $manifest ]] || continue
    base_found=$base; client_found=$client; manifest_found=$manifest
    break
done
if [[ -z $base_found ]]; then
    printf 'Please install release %s from your client, launch it once, then rerun this script.\n' "$version" >&2
    printf 'A complete install needs the matching client JAR, original version JSON, libraries and assets.\n' >&2
    printf 'For a custom location, use --minecraft-dir PATH. Searched:\n' >&2
    printf '  %s\n' "${roots[@]}" >&2
    exit 1
fi
printf 'Found Minecraft %s in %s\n' "$version" "$base_found"

if [[ -n $server ]]; then
    [[ -f $server ]] && [[ $(sha1 "$server") == "$server_hash" ]] || die "Server JAR does not match release $version: $server"
    server=$(realpath -- "$server")
else
    for candidate in "$project/.local/server.jar" "$project/.local/minecraft/$version/jars/server.jar" \
        "$HOME/Downloads/server.jar" "$HOME/Downloads/minecraft_server.$version.jar" \
        "$base_found/versions/$version/server.jar" "$base_found/server.jar"; do
        if [[ -f $candidate ]] && [[ $(sha1 "$candidate") == "$server_hash" ]]; then server=$candidate; break; fi
    done
fi
[[ -n $server ]] || die "Also needed for first preparation: your existing Minecraft $version server JAR. Pass --server-jar PATH. Nothing was downloaded."
printf 'Found matching server JAR: %s\n' "$server"
((check == 0)) || exit 0

missing=0
for tool in cc c++ make cmake pkg-config git curl tar; do
    command -v "$tool" >/dev/null || missing=1
done
if ! command -v pkg-config >/dev/null || ! pkg-config --exists alsa libudev xkbcommon wayland-client; then missing=1; fi
((missing == 0)) || native_dependencies

export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
rust_ok() {
    command -v cargo >/dev/null && command -v rustc >/dev/null || return 1
    local current minimum
    current=$(rustc --version | cut -d ' ' -f 2)
    minimum=$(sed -n 's/^rust-version = "\([^"]*\)"/\1/p' "$project/crates/horizon-client/Cargo.toml")
    [[ $(printf '%s\n' "$minimum" "$current" | sort -V | head -n 1) == "$minimum" ]]
}
if ! rust_ok; then
    ((install)) || die 'Rust is missing or too old. Install the current stable Rust toolchain.'
    if ! command -v rustup >/dev/null; then
        installer=$(mktemp)
        curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$installer"
        sh "$installer" -y --profile minimal --default-toolchain stable --no-modify-path
        rm -f -- "$installer"
    else
        rustup toolchain install stable --profile minimal
    fi
    # Use stable for this invocation without changing the user's default toolchain.
    export RUSTUP_TOOLCHAIN=stable
    rust_ok || die 'The installed stable Rust toolchain is still too old for this checkout.'
fi

jdk_ok() { [[ -x $1/bin/javac ]] && [[ $("$1/bin/javac" -version 2>&1) == "javac $java_major"* ]]; }
jdk=
for candidate in "${JAVA_HOME:-}" "$project/.local/jdk$java_major" /usr/lib/jvm/*; do
    if [[ -n $candidate ]] && jdk_ok "$candidate"; then jdk=$candidate; break; fi
done
if [[ -z $jdk ]] && command -v javac >/dev/null; then
    candidate=$(dirname -- "$(dirname -- "$(realpath -- "$(command -v javac)")")")
    if jdk_ok "$candidate"; then jdk=$candidate; fi
fi
if [[ -z $jdk ]]; then
    ((install)) || die "JDK $java_major is required. Set JAVA_HOME or rerun without --no-install."
    case $(uname -m) in x86_64) arch=x64 ;; aarch64) arch=aarch64 ;; *) die 'Unsupported JDK architecture; set JAVA_HOME manually.' ;; esac
    stage=$(mktemp -d)
    trap 'rm -rf -- "$stage"' EXIT
    curl --proto '=https' --tlsv1.2 -fsSL \
        "https://api.adoptium.net/v3/assets/latest/$java_major/hotspot?architecture=$arch&image_type=jdk&os=linux" -o "$stage/jdk.json"
    url=$(jq -er '.[0].binary.package.link' "$stage/jdk.json")
    checksum=$(jq -er '.[0].binary.package.checksum' "$stage/jdk.json")
    curl --proto '=https' --tlsv1.2 -fL "$url" -o "$stage/jdk.tar.gz"
    [[ $(sha256sum -- "$stage/jdk.tar.gz" | cut -d ' ' -f 1) == "$checksum" ]] || die 'JDK download checksum mismatch.'
    mkdir "$stage/jdk"
    tar -xzf "$stage/jdk.tar.gz" --strip-components=1 -C "$stage/jdk"
    jdk_ok "$stage/jdk" || die "Downloaded JDK is not Java $java_major."
    jdk="$project/.local/jdk$java_major"
    [[ ! -e $jdk ]] || die "An unusable JDK already exists at $jdk; move it or set JAVA_HOME."
    mkdir -p "$project/.local"
    mv -- "$stage/jdk" "$jdk"
    rm -rf -- "$stage"
    trap - EXIT
fi
export JAVA_HOME="$jdk" PATH="$jdk/bin:$PATH"

# Normalize files into Horizon's private directory; never write into the launcher.
linked="$project/.local/installed-minecraft"
mkdir -p "$linked/versions/$version"
cp -- "$manifest_found" "$linked/versions/$version/$version.json"
ln -sfnT -- "$client_found" "$linked/versions/$version/$version.jar"
ln -sfnT -- "$base_found/libraries" "$linked/libraries"
ln -sfnT -- "$base_found/assets" "$linked/assets"
cd -- "$project"
cargo build --locked --release -p horizon-prepare -p horizon-client --bin horizon-prepare --bin horizon-client
target/release/horizon-prepare --prepare --root "$project" --minecraft-dir "$linked" --server-jar "$server"
target/release/horizon-prepare sounds --root "$project" --minecraft-dir "$linked"
((prepare_only == 0)) || exit 0
exec target/release/horizon-client --resources "$project/.local/horizon-client/$version" "${game_args[@]}"
