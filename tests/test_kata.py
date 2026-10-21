#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class KataCommands(unittest.TestCase):
    def test_kata_reports_missing_shared_commands(self):
        env = dict(os.environ, BUSYBOX_PATH='/missing/busybox', CTR_PATH='/missing/ctr')
        result = subprocess.run(['bash', str(ROOT / 'scripts/kata-pvm-oci-test.sh')],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'Kata test requires executable busybox and ctr', result.stderr)

    def test_kata_resolves_ctr_before_sudo_resets_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / 'spec.json'
            fixture.write_text(json.dumps({'process': {}, 'root': {}, 'linux': {'namespaces': []}}))
            config = root / 'kata.toml'
            config.write_text('[hypervisor.qemu]\n')
            commands = {
                'sudo': '#!/bin/sh\nPATH=/usr/bin:/bin\nexport PATH\nexec "$@"\n',
                'runc': '#!/bin/sh\ncp "$PVM_TEST_SPEC" config.json\n',
                'ctr': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$PVM_TEST_CTR_LOG"\n',
            }
            for name, content in commands.items():
                path = root / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + ':/usr/bin:/bin',
                       BUSYBOX_PATH='/bin/sh', CTR_PATH=str(root / 'ctr'),
                       KATA_CONFIG_SOURCE=str(config), KATA_CONFIGURE_QBOOT='0',
                       PVM_TEST_SPEC=str(fixture), PVM_TEST_CTR_LOG=str(root / 'ctr.log'))
            result = subprocess.run(['bash', str(ROOT / 'scripts/kata-pvm-oci-test.sh'),
                                     'run', 'pvm-unit-' + root.name], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertIn('run --rm --runtime', (root / 'ctr.log').read_text())


if __name__ == '__main__':
    unittest.main()
