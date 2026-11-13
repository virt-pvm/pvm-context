#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pipeline', str(ROOT / 'tools/pvm-pipeline.py'))
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


class Inputs(unittest.TestCase):
    def test_force_prepare_is_explicit_and_validated(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(pipeline.force_prepare_requested())
            os.environ['PVM_FORCE_PREPARE'] = '1'
            self.assertTrue(pipeline.force_prepare_requested())
            os.environ['PVM_FORCE_PREPARE'] = '0'
            self.assertFalse(pipeline.force_prepare_requested())
            os.environ['PVM_FORCE_PREPARE'] = 'yes'
            with self.assertRaises(ValueError):
                pipeline.force_prepare_requested()

    def test_target_image_inputs_do_not_change_family_defaults(self):
        profile = pipeline.image_profile('centos-stream-10/6.12.0-267')
        self.assertTrue(any('gcc-14.4.1-3.el10' in url for url in profile['kernel_rpms']))
        defaults = json.loads((ROOT / 'images/profiles.json').read_text())['centos-stream-10']
        self.assertNotIn('kernel_rpms', defaults)

    def test_opencloudos_toolchain_is_pinned_per_kernel(self):
        profile = pipeline.image_profile('opencloudos-9.4/6.6.119-52.9')
        self.assertEqual(profile['compiler_packages'], ['gcc-12.3.1.8-8.oc9', 'gcc-c++-12.3.1.8-8.oc9'])
        defaults = json.loads((ROOT / 'images/profiles.json').read_text())['opencloudos-9.4']
        self.assertEqual(defaults['packages'], [])

    def test_dns_helpers_are_optional(self):
        instance = pipeline.Pipeline.__new__(pipeline.Pipeline)
        instance.dns_helper_sha256 = {}
        instance.guest = Mock()
        instance.apply_dns_helpers()
        instance.guest.assert_not_called()

    def test_dns_helpers_refresh_cached_vm(self):
        instance = pipeline.Pipeline.__new__(pipeline.Pipeline)
        instance.dns_helper_sha256 = {'dns-host-route-up.sh': 'a' * 64}
        instance.guest = Mock()
        instance.apply_dns_helpers()
        self.assertIn('restart cube-sandbox-coredns.service cube-sandbox-dns.service', instance.guest.call_args[0][0])

    def test_kernel_cache_ignores_non_rpm_profiles(self):
        self.assertEqual(pipeline.cached_kernel_rpms({}, '7.0.0-30-generic', '/missing'), [])

    def test_kernel_cache_stages_only_declared_inputs(self):
        profile = {'kernel_rpms': ['https://packages.invalid/{version}/{release}/{arch}/kernel-{kernel}.rpm']}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'kernel-6.12.0-267.el10.x86_64.rpm'
            path.write_bytes(b'input')
            Path(str(path) + '.sha256').write_text(pipeline.sha(path) + '  ' + path.name)
            (Path(directory) / 'unrelated').write_bytes(b'not an input')
            self.assertEqual(pipeline.cached_kernel_rpms(profile, '6.12.0-267.el10.x86_64', directory), [path])
            path.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                pipeline.cached_kernel_rpms(profile, '6.12.0-267.el10.x86_64', directory)

    def test_guest_write_preserves_bytes_and_private_mode(self):
        instance = pipeline.Pipeline.__new__(pipeline.Pipeline)
        instance.guest = lambda command, **kwargs: subprocess.run(['bash', '-c', command], check=True, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config with spaces.json'
            path.write_bytes(b'old')
            path.chmod(0o644)
            instance.guest_write(path, b'new\x00data\n')
            self.assertEqual(path.read_bytes(), b'new\x00data\n')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_ubuntu_kernel_package_layouts(self):
        profiles = json.loads((ROOT / 'images/profiles.json').read_text())
        self.assertEqual(profiles['ubuntu-24.04']['kernel_support_packages'], ['linux-modules-extra-{kernel}'])
        self.assertEqual(profiles['ubuntu-26.04']['kernel_support_packages'], [])

    def test_gnu_checksum(self):
        digest = 'a' * 64
        self.assertEqual(pipeline.checksum_for(digest + ' *image.qcow2\n', 'image.qcow2'), digest)

    def test_bsd_checksum(self):
        digest = 'b' * 64
        self.assertEqual(pipeline.checksum_for('SHA256 (image.qcow2) = ' + digest, 'image.qcow2'), digest)

    def test_checksum_requires_exact_filename(self):
        with self.assertRaises(ValueError):
            pipeline.checksum_for('a' * 64 + ' other-image.qcow2', 'image.qcow2')

    def test_http_image_rejected(self):
        with self.assertRaises(ValueError):
            pipeline.download('http://example.invalid/image', Path('/nonexistent'))

    def archive(self, name, link=None, data=b'hello'):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        archive = root / 'bundle.tar'
        with tarfile.open(str(archive), 'w') as output:
            member = tarfile.TarInfo(name)
            if link is not None:
                member.type, member.linkname = tarfile.SYMTYPE, link
                output.addfile(member)
            else:
                member.size = len(data)
                output.addfile(member, io.BytesIO(data))
        dest = root / 'extract'
        dest.mkdir()
        return archive, dest

    def test_extract_normal_file(self):
        archive, dest = self.archive('baseline/file')
        pipeline.safe_extract(archive, dest)
        self.assertEqual((dest / 'baseline/file').read_bytes(), b'hello')

    def test_extract_parent_escape(self):
        archive, dest = self.archive('../escape')
        with self.assertRaises(ValueError):
            pipeline.safe_extract(archive, dest)

    def test_extract_absolute_escape(self):
        archive, dest = self.archive('/tmp/escape')
        with self.assertRaises(ValueError):
            pipeline.safe_extract(archive, dest)

    def test_extract_symlink_escape(self):
        archive, dest = self.archive('baseline/link', '../../escape')
        with self.assertRaises(ValueError):
            pipeline.safe_extract(archive, dest)

    def test_extract_internal_symlink(self):
        archive, dest = self.archive('baseline/link', 'file')
        pipeline.safe_extract(archive, dest)
        self.assertTrue((dest / 'baseline/link').is_symlink())

    def test_catalog_covers_every_target(self):
        profiles = json.loads((ROOT / 'images/profiles.json').read_text())
        for manifest in (ROOT / 'targets').glob('*/*/manifest.txt'):
            profile = profiles[manifest.parent.parent.name]
            self.assertTrue(profile['image_url'].startswith('https://'))
            self.assertIn('{kernel}', profile['headers_package'])
            self.assertIn('{kernel}', profile['kernel_package'])
            self.assertNotIn('password', profile)

    def test_staged_recipe_matches(self):
        instance = pipeline.Pipeline.__new__(pipeline.Pipeline)
        instance.guest = Mock(return_value=Mock(stdout=('a' * 64 + ' file\n').encode()))
        instance.check_staged_recipe({'provision_sha256': 'a' * 64, 'attach_sha256': 'a' * 64})
        self.assertEqual(instance.guest.call_count, 2)

    def test_staged_recipe_rejects_concurrent_changes(self):
        instance = pipeline.Pipeline.__new__(pipeline.Pipeline)
        instance.guest = Mock(return_value=Mock(stdout=('b' * 64 + ' file\n').encode()))
        with self.assertRaises(RuntimeError):
            instance.check_staged_recipe({'provision_sha256': 'a' * 64, 'attach_sha256': 'a' * 64})

    def test_missing_image_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'seed').touch()
            record = {'recipe_sha256': 'recipe', 'seed': str(root / 'seed'),
                      'root': str(root / 'missing')}
            self.assertFalse(pipeline.sealed_image_matches(record, 'recipe'))

    def test_mutated_image_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'seed').touch()
            disk = root / 'root'
            disk.write_bytes(b'original')
            record = {'recipe_sha256': 'recipe', 'seed': str(root / 'seed'), 'root': str(disk),
                      'shared': str(disk), 'root_sha256': pipeline.sha(disk), 'shared_sha256': pipeline.sha(disk)}
            disk.chmod(0o440)
            self.assertTrue(pipeline.sealed_image_matches(record, 'recipe'))
            disk.chmod(0o640)
            disk.write_bytes(b'changed')
            disk.chmod(0o440)
            self.assertFalse(pipeline.sealed_image_matches(record, 'recipe'))


class Delegation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'scripts').mkdir()
        self.wrapper = self.root / 'scripts/pvm-ci'
        shutil.copyfile(str(ROOT / 'scripts/pvm-ci'), str(self.wrapper))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for program in ('ssh', 'rsync'):
            path = self.bin / program
            path.write_text('#!/usr/bin/env bash\necho "$0" >> "$CALLS"\nprintf "%s\\n" "$*" >> "$CALLS.args"\nexit "${MOCK_' + program.upper() + '_STATUS:-0}"\n')
            path.chmod(0o755)
        self.config = self.root / 'private.env'
        self.config.write_text('PVM_FACTORY_HOST=example\nPVM_FACTORY_CONTEXT=/srv/context\nPVM_FACTORY_ENV=/srv/private/test.env\n')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], CALLS=str(self.root / 'calls'))

    def call(self, mode='run', target='test/1.0', extra=()):
        return subprocess.run(['bash', str(self.wrapper), mode, target, '--env', str(self.config)] + list(extra),
                              env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode

    def test_prepare_does_not_collect_private_factory_files(self):
        self.assertEqual(self.call('prepare'), 0)
        self.assertNotIn('rsync', (self.root / 'calls').read_text())

    def test_force_prepare_is_forwarded_to_remote_controller(self):
        self.assertEqual(self.call('prepare', extra=['--force']), 0)
        self.assertIn('--force', (self.root / 'calls.args').read_text())
        self.assertNotIn('rsync', (self.root / 'calls').read_text())

    def test_force_is_rejected_for_rpm_runs_and_unknown_flags(self):
        for mode, flag in (('run', '--force'), ('all', '--force'), ('prepare', '--unknown')):
            self.assertEqual(self.call(mode, extra=[flag]), 2)
        self.assertFalse((self.root / 'calls').exists())

    def test_run_collects_only_artifacts(self):
        self.assertEqual(self.call(), 0)
        self.assertIn('rsync', (self.root / 'calls').read_text())
        self.assertTrue((self.root / '.artifacts/pipeline/test-1.0').is_dir())

    def test_preserves_remote_failure(self):
        self.env['MOCK_SSH_STATUS'] = '17'
        self.assertEqual(self.call(), 17)

    def test_artifact_collection_failure_is_not_success(self):
        self.env['MOCK_RSYNC_STATUS'] = '23'
        self.assertEqual(self.call(), 1)

    def test_rejects_path_traversal_before_ssh(self):
        self.assertEqual(self.call(target='../../etc'), 2)
        self.assertFalse((self.root / 'calls').exists())


if __name__ == '__main__':
    unittest.main()
