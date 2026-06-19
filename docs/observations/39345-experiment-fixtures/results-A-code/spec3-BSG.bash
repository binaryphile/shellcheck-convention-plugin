# setupTestEnv creates a per-test temp dir with mock `era` and `systemctl` shims on PATH.
#
# Allocates a temp dir via `tesht.MktempDir` (out-param nameref; cleanup auto-
# registered), exports ERA_STATE_DIR to that dir, makes the metrics subdir,
# prepends a mock/ dir to PATH, and writes two shim scripts. Reads no inputs.
setupTestEnv() {
  tesht.MktempDir TmpDir
  export ERA_STATE_DIR=$TmpDir
  mkdir -p $TmpDir/metrics/era-serve-soak
  mkdir -p $TmpDir/mock
  export PATH=$TmpDir/mock:$PATH

  cat >$TmpDir/mock/era <<'END'
#!/usr/bin/env bash
case ${1:-} in
  store)       read -r _; echo "stored mock-$$" ;;
  list)        printf 'a\nb\nc\n' ;;
  bulk-delete) echo 'deleted 0 memories' ;;
  *)           echo "mock-era: unknown $*" >&2; exit 1 ;;
esac
END
  chmod +x $TmpDir/mock/era

  cat >$TmpDir/mock/systemctl <<'END'
#!/usr/bin/env bash
[[ ${1:-} == --user ]] && shift
case ${1:-} in
  show) echo 'MainPID=0' ;;
  *) ;;
esac
END
  chmod +x $TmpDir/mock/systemctl
}
