#!/usr/bin/env bash

IFS=$'\n'
set -o noglob

setupTestEnv() {
    local tmpdir
    tesht.MktempDir tmpdir

    export ERA_STATE_DIR=$tmpdir

    mkdir -p $tmpdir/metrics/era-serve-soak
    mkdir -p $tmpdir/mock

    PATH=$tmpdir/mock:$PATH
    export PATH

    cat > $tmpdir/mock/era <<'EOF'
#!/usr/bin/env bash
case "$1" in
    store)
        read -r _line
        echo "stored mock-$$"
        ;;
    list)
        printf '%s\n' a b c
        ;;
    bulk-delete)
        echo "deleted 0 memories"
        ;;
    *)
        echo "mock-era: unknown $*" >&2
        exit 1
        ;;
esac
EOF

    cat > $tmpdir/mock/systemctl <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--user" ]]; then
    shift
fi
case "$1" in
    show)
        echo "MainPID=0"
        ;;
    *)
        exit 0
        ;;
esac
EOF

    chmod +x $tmpdir/mock/era $tmpdir/mock/systemctl
}
