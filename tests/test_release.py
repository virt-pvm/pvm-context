import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
import urllib.error
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pvm_release', str(ROOT / 'tools/pvm-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
export_spec = importlib.util.spec_from_file_location('oot_export', str(ROOT / 'tools/export-oot-source.py'))
source_export = importlib.util.module_from_spec(export_spec)
export_spec.loader.exec_module(source_export)
A, B, C = 'a' * 40, 'b' * 40, 'c' * 40


class ReleaseHistory(unittest.TestCase):
    def test_notes_distinguish_profile_revision_from_source_pin(self):
        plan = {'tag': 'v1', 'context_commit': C, 'previous_release': None,
                'sources': {'oot_66': {'branch': 'pvm-6.6-host-oot', 'commit': B,
                                       'changes': release.changes(None, None, B)}},
                'targets': [{'target': 'fixture/6.6', 'rpm': 'fixture.rpm', 'base_commit': A}]}
        text = release.notes(plan)
        self.assertIn('Profile/tooling commit: `' + B + '`', text)
        self.assertIn('source pin: `' + A + '`', text)

    def test_first_and_unchanged_do_not_query_history(self):
        api = mock.Mock()
        self.assertEqual(release.changes(api, None, A)['status'], 'first_release')
        self.assertEqual(release.changes(api, A, A)['status'], 'unchanged')
        api.get.assert_not_called()

    def test_compare_paginates_all_commits(self):
        api = mock.Mock()
        api.get.side_effect = [
            {'status': 'ahead', 'total_commits': 2,
             'commits': [{'sha': A, 'commit': {'message': 'first\n\nbody'}}]},
            {'status': 'ahead', 'total_commits': 2,
             'commits': [{'sha': B, 'commit': {'message': 'second'}}]}]
        status, commits = release.compare(api, A, B)
        self.assertEqual(status, 'ahead')
        self.assertEqual([c['subject'] for c in commits], ['first', 'second'])
        self.assertIn('page=2', api.get.call_args[0][0])

    def test_rewritten_history_records_both_sides(self):
        with mock.patch.object(release, 'compare', side_effect=[
                ('diverged', [{'sha': B, 'subject': 'new'}]),
                ('diverged', [{'sha': A, 'subject': 'old'}])]):
            result = release.changes(mock.Mock(), A, B)
        self.assertEqual(result['status'], 'rewritten')
        self.assertEqual(result['added'][0]['sha'], B)
        self.assertEqual(result['removed'][0]['sha'], A)

    def test_missing_old_commit_does_not_become_first_release(self):
        api = mock.Mock()
        api.get.side_effect = ValueError('old commit unavailable')
        with self.assertRaises(ValueError):
            release.changes(api, A, B)

    def test_previous_release_uses_publication_time_and_skips_drafts(self):
        def item(tag, date, draft=False, prerelease=False):
            return dict(tag_name=tag, published_at=date, draft=draft, prerelease=prerelease,
                        assets=[{'name': 'release-manifest.json', 'id': 1}])
        api = mock.Mock()
        api.get.side_effect = [
            [item('pvm-oot-old', '2026-01-01'), item('pvm-oot-new', '2026-02-01'),
             item('pvm-oot-draft', '2026-03-01', draft=True),
             item('pvm-oot-pre', '2026-04-01', prerelease=True)],
            json.dumps({'format': 1, 'tag': 'pvm-oot-new'}).encode()]
        self.assertEqual(release.previous_release(api, 'owner/repo')['tag'], 'pvm-oot-new')

    def test_previous_missing_manifest_fails(self):
        api = mock.Mock()
        api.get.return_value = [dict(tag_name='pvm-oot-old', published_at='2026-01-01',
                                    draft=False, prerelease=False, assets=[])]
        with self.assertRaises(ValueError):
            release.previous_release(api, 'owner/repo')

    def test_snapshot_freezes_each_branch_once(self):
        api = mock.Mock()
        api.get.side_effect = [{'sha': A}, {'sha': B}]
        with mock.patch.object(release, 'previous_release', return_value=None):
            with mock.patch.object(release, 'release_tag', return_value='pvm-oot-test-123-2'):
                result = release.snapshot(api, 'owner/repo', C, '123', '2')
        self.assertEqual(api.get.call_count, 2)
        self.assertEqual(result['sources']['oot_66']['commit'], A)
        self.assertEqual(result['sources']['oot_612']['commit'], B)
        self.assertTrue(result['tag'].endswith('-123-2'))
        self.assertEqual(result['context_commit'], C)

    def test_manual_tag_is_used(self):
        api = mock.Mock()
        api.get.side_effect = urllib.error.HTTPError('url', 404, 'missing', {}, None)
        self.assertEqual(release.release_tag(api, 'owner/repo', 'v0.1.0', '123', '1'), 'v0.1.0')

    def test_blank_tag_is_generated(self):
        api = mock.Mock()
        api.get.side_effect = urllib.error.HTTPError('url', 404, 'missing', {}, None)
        self.assertRegex(release.release_tag(api, 'owner/repo', '', '123', '2'),
                         r'^pvm-oot-[0-9]{8}-123-2$')

    def test_existing_tag_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'already exists'):
            release.release_tag(mock.Mock(), 'owner/repo', 'v1', '123', '1')

    def test_tag_lookup_failures_are_not_treated_as_absence(self):
        for status in (401, 403, 500):
            api = mock.Mock()
            api.get.side_effect = urllib.error.HTTPError('url', status, 'failure', {}, None)
            with self.assertRaises(urllib.error.HTTPError):
                release.release_tag(api, 'owner/repo', 'v1', '123', '1')

    def test_invalid_tags_are_rejected_before_network(self):
        api = mock.Mock()
        for tag in (' bad', 'bad tag', '-option', 'a..b', 'a.lock', 'a.', 'a/b', 'a\nb', 'a' * 129):
            with self.assertRaises(ValueError):
                release.release_tag(api, 'owner/repo', tag, '123', '1')
        api.get.assert_not_called()

    def test_manual_tag_release_is_a_history_baseline(self):
        api = mock.Mock()
        api.get.side_effect = [[dict(tag_name='v0.1.0', published_at='2026-01-01', draft=False,
                                    prerelease=False, assets=[{'name': 'release-manifest.json', 'id': 1}])],
                               json.dumps({'format': 1, 'tag': 'v0.1.0'}).encode()]
        self.assertEqual(release.previous_release(api, 'owner/repo')['tag'], 'v0.1.0')


class TargetInputs(unittest.TestCase):
    def test_input_checksums_bind_plan_and_exact_file_set(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan = {'context_commit': A}
            (root / 'context.bundle').write_bytes(b'fixture')
            release.write_json(root / 'inputs.json', {
                'plan': plan, 'targets': [{'target': 'fixture/6.6'}],
                'files': {'context.bundle': release.digest(root / 'context.bundle')}})
            self.assertEqual(release.verify_inputs(root, plan), [{'target': 'fixture/6.6'}])
            with self.assertRaises(ValueError):
                release.verify_inputs(root, {'context_commit': B})
            (root / 'context.bundle').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                release.verify_inputs(root, plan)

    def test_unlisted_input_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release.write_json(root / 'inputs.json', {'plan': {}, 'targets': [], 'files': {}})
            (root / 'unexpected.env').write_text('private')
            with self.assertRaises(ValueError):
                release.verify_inputs(root, {})

    def test_input_path_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release.write_json(root / 'inputs.json', {
                'plan': {}, 'targets': [], 'files': {'../escape': 'a' * 64}})
            with self.assertRaises(ValueError):
                release.verify_inputs(root, {})

    def test_validation_host_uses_prepackaged_sources_without_git_fetch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs, envs = root / 'inputs', root / 'envs'
            target = 'fixture/6.6'
            for parent in (inputs, envs):
                parent.mkdir()
            source = inputs / 'targets' / target
            source.mkdir(parents=True)
            (source / 'manifest.txt').write_text('base_commit=' + A + '\n')
            (source / 'config.sh').write_text('PVM_BASE_COMMIT=' + A + '\n')
            (envs / 'fixture-6.6.env').write_text('PVM_FACTORY_HOST=local\n')
            def copy_context(context):
                destination = context / 'targets' / target
                destination.mkdir(parents=True)
                (destination / 'manifest.txt').write_text('old')
            record = {'target': target, 'kernel': '6.6-test'}
            plan = {'context_commit': A, 'sources': {}}
            with mock.patch.object(release, 'git', return_value=(A + '\n').encode()):
                with mock.patch.object(release, 'copy_context', side_effect=copy_context):
                    with mock.patch.object(release, 'verify_inputs', return_value=[record]):
                        with mock.patch.object(release, 'fetch', side_effect=AssertionError('network fetch')):
                            with mock.patch.object(release.subprocess, 'check_call') as run:
                                with mock.patch.object(release, 'collect', return_value=record):
                                    with mock.patch.object(release, 'notes', return_value='notes'):
                                        release.build(plan, root / 'work', envs, inputs)
            self.assertEqual(run.call_count, 1)
            self.assertIn('scripts/pvm-ci', run.call_args[0][0][1])
            wrapper = (root / 'work/fixture-6.6.env').read_text()
            self.assertIn("PVM_OOT_REPO=''", wrapper)
            self.assertIn(str(inputs / 'bundles'), wrapper)

    def test_generated_pins_work_with_existing_source_exporter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / 'linux'
            repo.mkdir()
            subprocess.check_call(['git', 'init', '-q', str(repo)])
            def commit():
                subprocess.check_call(['git', '-C', str(repo), 'add', '.'])
                subprocess.check_call(['git', '-C', str(repo), '-c', 'user.name=Fixture',
                                       '-c', 'user.email=fixture@example.invalid',
                                       'commit', '-qm', 'fixture'])
                return release.git(repo, 'rev-parse', 'HEAD').decode().strip()
            (repo / 'arch/x86/kvm').mkdir(parents=True)
            (repo / 'arch/x86/kvm/source.c').write_text('/* fixture */\n')
            (repo / 'scripts').mkdir()
            (repo / 'scripts/fixture').write_text('fixture')
            (repo / 'tools').mkdir()
            (repo / 'tools/fixture').write_text('fixture')
            baseline = commit()
            source_fingerprint = source_export.tree_sha256(repo, ['arch/x86/kvm'])
            (repo / 'arch/x86/kvm/source.c').write_text('/* latest source fix */\n')
            change = commit()
            patch = release.git(repo, 'format-patch', '-1', '--stdout', '--no-signature', change)
            profile_path = 'tools/pvm-oot/profiles/fixture/profile.json'
            (repo / profile_path).parent.mkdir(parents=True)
            release.write_json(repo / profile_path, {
                'format': 1, 'source': {'commit': baseline, 'export_roots': ['arch/x86/kvm'],
                                       'export_tree_sha256': source_fingerprint},
                'patches': [{'file': 'keep.patch', 'sha256': hashlib.sha256(patch).hexdigest()}],
                'target': {'kernel_release': '6.6-test'}})
            (repo / profile_path).with_name('keep.patch').write_bytes(patch)
            (repo / profile_path).with_name('series').write_text('keep.patch\n')
            head = commit()
            context = root / 'context'
            target = context / 'targets/fixture/6.6'
            target.mkdir(parents=True)
            (target / 'manifest.txt').write_text('kernel_release=6.6-test\nbase_commit=' + C +
                                                '\nprofile=' + profile_path + '\n')
            (target / 'config.sh').write_text('PVM_BASE_COMMIT=' + C + '\n')
            release.update_target(context, repo, 'fixture/6.6', {'oot_66': {'commit': head}})
            archive = root / 'source.tar.gz'
            subprocess.check_call(['python3', str(ROOT / 'tools/export-oot-source.py'),
                                   'fixture/6.6', '--context', str(context), '--repo', str(repo),
                                   '--output', str(archive)], stdout=subprocess.DEVNULL)
            import tarfile
            with tarfile.open(str(archive)) as stream:
                meta = json.load(stream.extractfile('bundle.json'))
                self.assertEqual(meta['base_commit'], baseline)
                self.assertEqual(stream.extractfile('baseline/arch/x86/kvm/source.c').read(),
                                 b'/* fixture */\n')
                self.assertEqual(stream.extractfile('tool/' + profile_path).read(),
                                 (repo / profile_path).read_bytes())
                folder = str(Path('tool') / Path(profile_path).parent)
                self.assertEqual(stream.extractfile(folder + '/keep.patch').read(), patch)
                self.assertEqual(stream.extractfile(folder + '/series').read(), b'keep.patch\n')
            manifest = target / 'manifest.txt'
            original = manifest.read_text()
            for override in ('source_skip_patches=[]', 'source_export_tree_sha256=' + '0' * 64):
                manifest.write_text(original + override + '\n')
                result = subprocess.run(['python3', str(ROOT / 'tools/export-oot-source.py'),
                                         'fixture/6.6', '--context', str(context), '--repo', str(repo),
                                         '--output', str(root / 'invalid.tar.gz')],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'overrides are not supported', result.stderr)
            manifest.write_text(original.replace('source_export_commit=' + baseline,
                                                  'source_export_commit=' + head))
            result = subprocess.run(['python3', str(ROOT / 'tools/export-oot-source.py'),
                                     'fixture/6.6', '--context', str(context), '--repo', str(repo),
                                     '--output', str(root / 'invalid.tar.gz')],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'fingerprint does not match', result.stderr)

    def test_latest_profile_and_declared_baseline_are_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'targets/ubuntu/7.0.0-30'
            target.mkdir(parents=True)
            manifest = target / 'manifest.txt'
            manifest.write_text('kernel_release=7.0.0-30-generic\nbase_commit=' + C + '\n'
                                'profile=tools/pvm-oot/profiles/ubuntu/profile.json\n')
            (target / 'config.sh').write_text('PVM_BASE_COMMIT=' + C + '\n')
            profile = json.dumps({'format': 1, 'target': {'kernel_release': '7.0.0-30-generic'},
                                  'source': {'commit': A, 'export_roots': ['arch/x86/kvm'],
                                             'export_tree_sha256': 'd' * 64}}).encode()
            with mock.patch.object(release, 'git', return_value=profile) as git:
                with mock.patch.object(release, 'fetch') as fetch:
                    result = release.update_target(root, root, 'ubuntu/7.0.0-30',
                                                   {'oot_612': {'commit': B}})
            self.assertEqual(result['branch_commit'], B)
            self.assertEqual(result['base_commit'], A)
            self.assertEqual(result['source_fingerprint'], 'd' * 64)
            fetch.assert_called_once_with(root, A)
            self.assertEqual(git.call_args[0][2], B + ':tools/pvm-oot/profiles/ubuntu/profile.json')
            self.assertIn('profile_commit=' + B, manifest.read_text())
            self.assertEqual((target / 'config.sh').read_text(), 'PVM_BASE_COMMIT=' + A + '\n')
            before = manifest.read_bytes()
            with mock.patch.object(release, 'git', return_value=profile):
                with mock.patch.object(release, 'fetch', side_effect=ValueError('pin unavailable')):
                    with self.assertRaisesRegex(ValueError, 'pin unavailable'):
                        release.update_target(root, root, 'ubuntu/7.0.0-30', {'oot_612': {'commit': B}})
            self.assertEqual(manifest.read_bytes(), before)

    def test_checkout_identity_checked_before_creating_workspace(self):
        with mock.patch.object(release, 'git', return_value=(A + '\n').encode()):
            with self.assertRaises(ValueError):
                release.build({'context_commit': B}, Path('/not-created'), Path('/missing'))


class ReleaseAssets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / 'output'
        self.work = self.output / 'one-run'
        self.assets = self.root / 'assets'
        self.assets.mkdir()
        (self.work / 'rpm').mkdir(parents=True)
        (self.work / 'reboot-restore').mkdir()
        self.target = dict(target='ubuntu/6.8', kernel='6.8-test', base_commit=A,
                           profile_sha256='a' * 64)
        release.write_json(self.work / 'provenance.json', dict(
            self.target, full_test='PASS', runtime_sha256='b' * 64,
            image_recipe_sha256='c' * 64, source_bundle_sha256='d' * 64))
        self.result = self.work / 'reboot-restore/result.env'
        self.result.write_text('result=PASS\nkernel=6.8-test\ntemplate_id=template1\n'
                               'boot_before=one\nboot_after=two\n')
        self.rpm = self.work / 'rpm/pvm-kmod-6.8.test-1.0-1.x86_64.rpm'
        self.rpm.write_bytes(b'tested-rpm')
        self.rpm.with_name(self.rpm.name + '.sha256').write_text(
            release.digest(self.rpm) + '  ' + self.rpm.name + '\n')
        (self.work / 'private.env').write_text('SECRET=not-for-release')

    def test_only_tested_rpm_is_collected(self):
        result = release.collect(self.output, self.target, self.assets)
        self.assertEqual(result['reboot_restore'], 'PASS')
        self.assertEqual(result['rpm_sha256'], release.digest(self.rpm))
        name = 'ubuntu-pvm-kmod-6.8.test-1.0-1.x86_64.rpm'
        self.assertEqual(result['rpm'], name)
        self.assertEqual([p.name for p in self.assets.iterdir()], [name])
        self.assertNotIn('--', name)
        self.assertNotIn('oot', name)

    def test_distribution_prefix_keeps_assets_distinct(self):
        first = release.collect(self.output, self.target, self.assets)
        target = dict(self.target, target='other-linux/6.8')
        data = json.loads((self.work / 'provenance.json').read_text())
        data['target'] = target['target']
        release.write_json(self.work / 'provenance.json', data)
        second = release.collect(self.output, target, self.assets)
        self.assertNotEqual(first['rpm'], second['rpm'])
        self.assertEqual(second['rpm'], 'other-linux-' + self.rpm.name)
        self.assertEqual(len(list(self.assets.iterdir())), 2)

    def test_duplicate_asset_cannot_overwrite_tested_rpm(self):
        release.collect(self.output, self.target, self.assets)
        with self.assertRaisesRegex(ValueError, 'duplicate release RPM asset'):
            release.collect(self.output, self.target, self.assets)

    def test_missing_reboot_gate_is_rejected(self):
        self.result.unlink()
        with self.assertRaises(ValueError):
            release.collect(self.output, self.target, self.assets)

    def test_same_boot_is_rejected(self):
        self.result.write_text(self.result.read_text().replace('boot_after=two', 'boot_after=one'))
        with self.assertRaises(ValueError):
            release.collect(self.output, self.target, self.assets)

    def test_changed_rpm_is_rejected(self):
        self.rpm.write_bytes(b'not-tested-rpm')
        with self.assertRaises(ValueError):
            release.collect(self.output, self.target, self.assets)

    def test_old_run_cannot_be_mixed_in(self):
        (self.output / 'old-run').mkdir()
        release.write_json(self.output / 'old-run/provenance.json', {})
        with self.assertRaises(ValueError):
            release.collect(self.output, self.target, self.assets)

    def test_failed_qualification_is_rejected(self):
        data = json.loads((self.work / 'provenance.json').read_text())
        data['full_test'] = 'FAIL'
        release.write_json(self.work / 'provenance.json', data)
        with self.assertRaises(ValueError):
            release.collect(self.output, self.target, self.assets)


if __name__ == '__main__':
    unittest.main()
