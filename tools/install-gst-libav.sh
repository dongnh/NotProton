#!/bin/sh
# Give a runner the GStreamer decoders CrossOver leaves out, as a runner variant.
#
#   ./install-gst-libav.sh <gst-lib> [build]   assemble the tree and write its descriptor
#   ./install-gst-libav.sh --remove <build>    drop the descriptor and the tree
#
# CrossOver's GStreamer has no gst-libav, so Media Foundation cannot open WMV/VC-1 or WMA
# Pro. Games that play such videos (Resident Evil Village's intro, for one) crash or hang
# on them. <gst-lib> is any x86_64 lib folder holding gstreamer-1.0/libgstlibav.dylib and
# the ffmpeg libraries beside it, such as Whisky's:
#   ~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/lib
# Its GStreamer has to be the runner's minor series (1.24 for CrossOver 26).
set -eu

np_support="$HOME/Library/Application Support/notproton"
runners="$np_support/runners"
conf_dir="$np_support/variants"
trees="$HOME/.local/share/notproton/variants"

# decodebin2 stops reading once a stream's queue holds this much. Its 8 MB default
# deadlocks on ASF files that carry several seconds of video before the first audio
# packet: the app waits for audio, the demuxer waits for room in the video queue.
queue_bytes=268435456

usage() {
    echo "usage: $0 <gst-lib> [build]" >&2
    echo "       $0 --remove <build>" >&2
    exit 2
}

die() { echo "==> $*" >&2; exit 1; }
say() { echo "==> $*"; }

written_here() {
    head -n 1 "$1" 2>/dev/null | grep -q '^# Written by install-gst-libav\.sh'
}

# The newest base runner, skipping variant builds (crossover-<build>+<ids>@<hash>).
newest_build() {
    for d in "$runners"/crossover-*/; do
        b=$(basename "${d%/}")
        case "$b" in *+*) continue ;; esac
        [ -f "$d/CrossOver/lib64/libgstreamer-1.0.0.dylib" ] && echo "${b#crossover-}"
    done | sort -V | tail -1
}

# The @loader_path and @rpath libraries a Mach-O links, by file name.
local_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
        | grep -E '^@(loader_path|rpath)/' | sed 's|.*/||' | grep -vx "$(basename "$1")" || true
}

# The movl $0x800000 instructions in libgstplayback, as hex addresses. In 1.24 these are
# decodebin2's queue sizes and nothing else.
queue_sites() {
    otool -tV "$1" | awk '/movl[ \t]+\$0x800000,/ {print $1}'
}

remove_variant() {
    build=$1
    name="gst-libav-$build"
    conf="$conf_dir/$name.conf"
    gone=0
    if [ -f "$conf" ] && written_here "$conf"; then rm -f "$conf"; say "removed $conf"; gone=1
    elif [ -f "$conf" ]; then say "$conf was not written by this script, so it is left for you"; fi
    if [ -d "$trees/$name" ]; then rm -rf "${trees:?}/$name"; say "removed $trees/$name"; gone=1; fi
    [ "$gone" -eq 1 ] || die "nothing to remove for $build"
}

install_variant() {
    src=${1%/}
    build=${2:-$(newest_build)}
    [ -n "$build" ] || die "no runner with GStreamer in $runners"
    base="$runners/crossover-$build/CrossOver/lib64"
    [ -f "$base/libgstreamer-1.0.0.dylib" ] || die "crossover-$build has no GStreamer in lib64"

    plugin="$src/gstreamer-1.0/libgstlibav.dylib"
    [ -f "$plugin" ] || die "no gstreamer-1.0/libgstlibav.dylib in $src"
    lipo -archs "$plugin" | grep -qw x86_64 || die "$plugin has no x86_64 slice"

    playback="$base/gstreamer-1.0/libgstplayback.dylib"
    sites=$(queue_sites "$playback")
    [ -n "$sites" ] ||
        die "crossover-$build's libgstplayback has no 8 MB queue size; is it already patched?"
    [ "$(echo "$sites" | wc -l)" -le 6 ] ||
        die "crossover-$build's libgstplayback is not the decodebin this script knows"

    name="gst-libav-$build"
    tree="$trees/$name"
    rm -rf "$tree"
    mkdir -p "$tree/gstreamer-1.0"
    cp -p "$plugin" "$tree/gstreamer-1.0/"

    # Walk what the plugin links. The runner's own copy wins, except GLib: the plugin was
    # built against a newer one, and GLib only ever adds to its ABI.
    todo=$(local_deps "$plugin")
    seen=" "
    while [ -n "$todo" ]; do
        f=$(echo "$todo" | head -1)
        todo=$(echo "$todo" | tail -n +2)
        case "$seen" in *" $f "*) continue ;; esac
        seen="$seen$f "
        case "$f" in
            libglib-2.0.0.dylib|libgobject-2.0.0.dylib|libgmodule-2.0.0.dylib|libgio-2.0.0.dylib) ;;
            libintl.8.dylib) ;;
            *) [ -e "$base/$f" ] && continue ;;
        esac
        [ -f "$src/$f" ] || die "$f is linked but not in $src"
        cp -p "$src/$f" "$tree/$f"
        todo=$(printf '%s\n%s\n' "$todo" "$(local_deps "$src/$f")" | sed '/^$/d')
    done
    # gmodule and gio have to move with glib even when the plugin does not link them.
    for f in libgmodule-2.0.0.dylib libgio-2.0.0.dylib; do
        [ -f "$tree/$f" ] || { [ -f "$src/$f" ] && cp -p "$src/$f" "$tree/$f"; }
    done

    # Wine distributions ship their libraries read-only.
    chmod -R u+w "$tree"

    # The runner's libintl is GLib's proxy, which its own GStreamer libraries link by name.
    # The new GLib needs GNU gettext, so that one goes in under its own name, and only what
    # came from <gst-lib> is pointed at it.
    if [ -f "$tree/libintl.8.dylib" ]; then
        mv "$tree/libintl.8.dylib" "$tree/libintl-gnu.8.dylib"
        install_name_tool -id @rpath/libintl-gnu.8.dylib "$tree/libintl-gnu.8.dylib" 2>/dev/null
        find "$tree" -name '*.dylib' | while IFS= read -r lib; do
            old=$(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep '/libintl\.8\.dylib$' || true)
            [ -n "$old" ] || continue
            case "$lib" in */gstreamer-1.0/*) up=../ ;; *) up= ;; esac
            install_name_tool -change "$old" "@loader_path/${up}libintl-gnu.8.dylib" "$lib" 2>/dev/null
        done
    fi

    cp -p "$playback" "$tree/gstreamer-1.0/"
    chmod u+w "$tree/gstreamer-1.0/libgstplayback.dylib"
    for a in $sites; do
        # B8+r imm32, or 41 B8+r imm32 for r8-r15. __TEXT starts at file offset 0.
        perl -e '
            my ($p, $a, $v) = (shift, hex(shift), shift);
            open(my $f, "+<:raw", $p) or die "$p: $!";
            seek($f, $a, 0); read($f, my $op, 6);
            my $at = (ord($op) == 0x41) ? 2 : 1;
            substr($op, $at, 4) eq pack("V", 0x800000) or die sprintf("no imm at 0x%x\n", $a);
            seek($f, $a + $at, 0); print $f pack("V", $v); close($f);
        ' "$tree/gstreamer-1.0/libgstplayback.dylib" "$a" "$queue_bytes"
    done

    find "$tree" -name '*.dylib' -exec codesign -f -s - {} \; 2>/dev/null

    stored=$tree
    case "$tree" in "$HOME"/*) stored=${tree#"$HOME"/} ;; esac
    mkdir -p "$conf_dir"
    conf="$conf_dir/$name.conf"
    cat > "$conf" <<CONF
# Written by install-gst-libav.sh. gst-libav for Media Foundation, with GLib to match and
# decodebin's queues raised; pinned to the build whose libgstplayback it patched.
[$name]
label   = gst-libav
variant = GStreamer
src     = $stored
dst     = lib64
build   = $build
CONF
    say "$(find "$tree" -name '*.dylib' | wc -l | tr -d ' ') libraries in $tree"
    say "wrote $conf"
    say "add this to a game's launch options:"
    say "    NOTPROTON_RUNNER_VARIANT=$name %command%"
}

case "${1:-}" in
    "")        usage ;;
    --remove)  [ $# -eq 2 ] || usage; remove_variant "$2" ;;
    -*)        usage ;;
    *)         [ $# -le 2 ] || usage; install_variant "$1" "${2:-}" ;;
esac
