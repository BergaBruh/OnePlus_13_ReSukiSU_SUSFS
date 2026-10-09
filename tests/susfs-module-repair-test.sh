#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

source = Path('scripts/susfs-module-repair.sh').read_text()
helper = '''#!/bin/sh
if [ "$MOCK_API" = unsupported ]; then echo v1.5.2; exit 0; fi
if [ "$MOCK_API" = rollback ] && [ "${0##*/}" = ksu_susfs ]; then exit 1; fi
case "$2" in
  version) echo v2.3.0 ;;
  enabled_features) echo CONFIG_KSU_SUSFS_SUS_PATH ;;
  *) exit 1 ;;
esac
'''
digest = hashlib.sha256(helper.encode()).hexdigest()
old_helper = '#!/bin/sh\necho v1.5.2\n'

def run_case(name, mode='--repair', existing=None, executable=True,
             api='good', download='good', success=True, repaired=False):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bin_dir = root / 'ksu/bin'
        bin_dir.mkdir(parents=True)
        module = root / 'modules/susfs4ksu'
        module.mkdir(parents=True)
        binary = bin_dir / 'ksu_susfs'
        marker = root / 'logs/susfs_active'
        marker.parent.mkdir()
        script = source.replace('/data/adb/ksu/bin', str(bin_dir))
        script = script.replace('/data/adb/modules/susfs4ksu', str(module))
        script = script.replace('/data/adb/ksu/susfs4ksu/logs/susfs_active', str(marker))
        script = script.replace('8a626ce3bae27a7bcaa2e7f5f7b91e786ecc57f8e57d19c7856719a89b54b6fa', digest)
        (root / 'repair.sh').write_text(script)
        (root / 'helper').write_text(helper)
        if existing is not None:
            binary.write_text(existing)
            binary.chmod(0o755 if executable else 0o644)
        commands = root / 'commands'
        commands.mkdir()
        mocks = {
            'id': '#!/bin/sh\necho 0\n',
            'uname': '#!/bin/sh\ncase "$1" in -m) echo aarch64 ;; *) echo 6.6.118-android15 ;; esac\n',
            'curl': '''#!/bin/sh
echo download >> "$MOCK_ROOT/events"
[ "$MOCK_DOWNLOAD" != fail ] || exit 22
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; target=$1; fi
  shift
done
if [ "$MOCK_DOWNLOAD" = corrupt ]; then echo corrupt > "$target"
else cp "$MOCK_ROOT/helper" "$target"; fi
''',
        }
        for command, content in mocks.items():
            path = commands / command
            path.write_text(content)
            path.chmod(0o755)
        env = dict(os.environ, PATH=f'{commands}:{os.environ["PATH"]}',
                   MOCK_ROOT=tmp, MOCK_DOWNLOAD=download, MOCK_API=api)
        result = subprocess.run(['sh', str(root / 'repair.sh'), mode],
                                env=env, text=True, capture_output=True)
        assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
        assert not marker.exists(), f'{name}: must not manufacture a support marker'
        assert not list(bin_dir.glob('.ksu_susfs.*')), f'{name}: temporary helper leaked'
        if repaired:
            assert binary.read_text() == helper, name
            assert binary.stat().st_mode & 0o777 == 0o755, name
            backups = list(bin_dir.glob('ksu_susfs.backup.*'))
            if existing is not None:
                assert len(backups) == 1 and backups[0].read_text() == existing, name
        elif existing is None:
            assert not binary.exists(), name
        else:
            assert binary.read_text() == existing, name
            assert binary.stat().st_mode & 0o777 == (0o755 if executable else 0o644), name
        if mode == '--diagnose' or existing == helper and executable:
            assert not (root / 'events').exists(), f'{name}: unnecessary download'
        print(f'PASS: {name}')

run_case('missing helper', repaired=True)
run_case('outdated helper', existing=old_helper, repaired=True)
run_case('nonexecutable helper', existing=helper, executable=False, repaired=True)
run_case('healthy helper with missing boot marker', existing=helper)
run_case('read-only diagnosis', mode='--diagnose', success=False)
run_case('bad checksum preserves helper', existing=old_helper, download='corrupt', success=False)
run_case('download failure preserves helper', existing=old_helper, download='fail', success=False)
run_case('unsupported kernel preserves helper', existing=old_helper, api='unsupported', success=False)
run_case('post-install failure restores helper', existing=old_helper, api='rollback', success=False)
run_case('post-install failure removes new helper', api='rollback', success=False)
PY
