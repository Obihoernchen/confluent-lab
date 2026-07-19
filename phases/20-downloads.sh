# shellcheck shell=bash disable=SC2034,SC2154
PHASE_DESC="download AlmaLinux images into the cache"

phase_check() {
    [ -f "$CACHEDIR/$(basename "$CLOUDIMG_URL")" ] && \
    [ -f "$CACHEDIR/$(basename "$DVDISO_URL")" ]
}

# Pick a close mirror from the geo-sorted mirrorlist: derive the mirror base
# from its BaseOS repo path and keep the first mirror that actually serves the
# ISO.  Only URLs still pointing at the default repo.almalinux.org are
# replaced; custom URLs from lab.conf are respected as-is.
detect_mirror() {
    [ -n "${MIRRORLIST_URL:-}" ] || return 0
    if [[ $DVDISO_URL != *repo.almalinux.org* && $CLOUDIMG_URL != *repo.almalinux.org* ]]; then
        return 0
    fi
    local entry base isourl imgurl
    for entry in $(curl -sfm 10 "$MIRRORLIST_URL" 2>/dev/null | head -n 8); do
        base=${entry%%BaseOS*}
        isourl='' imgurl=''
        if [[ $DVDISO_URL == *repo.almalinux.org* ]]; then
            isourl="${base}isos/x86_64/$(basename "$DVDISO_URL")"
            curl -sfIm 5 -o /dev/null "$isourl" 2>/dev/null || continue
        fi
        if [[ $CLOUDIMG_URL == *repo.almalinux.org* ]]; then
            imgurl="${base}cloud/x86_64/images/$(basename "$CLOUDIMG_URL")"
            curl -sfIm 5 -o /dev/null "$imgurl" 2>/dev/null || continue
        fi
        [ -n "$isourl" ] && DVDISO_URL=$isourl
        [ -n "$imgurl" ] && CLOUDIMG_URL=$imgurl
        ok "close mirror: ${base%/*/}"
        return 0
    done
    warn "no usable mirror found, downloading from repo.almalinux.org"
}

phase_run() {
    mkdir -p "$CACHEDIR"
    explain "Cached downloads" \
        "Two downloads land in $CACHEDIR:" \
        "- AlmaLinux 10 cloud image (~600 MB): becomes the confluent server VM" \
        "- AlmaLinux 10 DVD ISO (~11 GB): the OS source confluent will import" \
        "Interrupted downloads resume; ./destroy.sh --keep-cache preserves this cache." \
        "A close download mirror is picked from the geo-sorted AlmaLinux mirror list" \
        "(the same service dnf uses) [lab plumbing]:"
    detect_mirror

    fetch() {
        local url=$1 f
        f=$CACHEDIR/$(basename "$url")
        if [ -f "$f" ]; then
            skip "$(basename "$f")"
            return 0
        fi
        if [ -t 1 ]; then
            # curl's full progress meter: size, transfer rate, time remaining
            run_lab curl -fL -C - --retry 15 --retry-delay 5 \
                --retry-all-errors -o "$f.part" "$url"
        else
            run_lab curl -fL -sS -C - --retry 15 --retry-delay 5 \
                --retry-all-errors -o "$f.part" "$url"
        fi
        mv "$f.part" "$f"
    }

    fetch "$CLOUDIMG_URL"
    milestone "Next is the big one: the ~11 GB AlmaLinux DVD ISO"
    fetch "$DVDISO_URL"
}
