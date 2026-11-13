#!/usr/bin/env python3
"""Freeze release inputs, qualify every target, and collect public assets."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LINUX = 'virt-pvm/linux'
BRANCHES = {'oot_66': 'pvm-6.6-host-oot', 'oot_612': 'pvm-6.12-host-oot'}
SHA = re.compile(r'[0-9a-f]{40}')


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlparse(newurl).scheme != 'https':
            raise ValueError('non-HTTPS release asset redirect')
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if urllib.parse.urlparse(req.full_url).netloc != urllib.parse.urlparse(newurl).netloc:
            redirected.remove_header('Authorization')
        return redirected


class GitHub:
    def __init__(self):
        self.opener = urllib.request.build_opener(SafeRedirect())

    def get(self, path, binary=False):
        headers = {'Accept': 'application/octet-stream' if binary else 'application/vnd.github+json',
                   'User-Agent': 'pvm-context-release'}
        if os.environ.get('GH_TOKEN'):
            headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
        req = urllib.request.Request('https://api.github.com/' + path, headers=headers)
        with self.opener.open(req, timeout=60) as response:
            data = response.read()
        return data if binary else json.loads(data)


def previous_release(api, repository):
    releases = []
    page = 1
    while True:
        batch = api.get('repos/' + repository + '/releases?per_page=100&page=' + str(page))
        releases.extend(r for r in batch if not r['draft'] and not r['prerelease']
                        and (r['tag_name'].startswith('pvm-oot-') or
                             any(a['name'] == 'release-manifest.json' for a in r['assets'])))
        if len(batch) < 100:
            break
        page += 1
    if not releases:
        return None
    release = max(releases, key=lambda r: r['published_at'])
    assets = [a for a in release['assets'] if a['name'] == 'release-manifest.json']
    if len(assets) != 1:
        raise ValueError('previous PVM release must have exactly one release-manifest.json')
    manifest = json.loads(api.get('repos/' + repository + '/releases/assets/' +
                                  str(assets[0]['id']), binary=True))
    if manifest['format'] != 1 or manifest['tag'] != release['tag_name']:
        raise ValueError('previous release manifest identity mismatch')
    return manifest


def compare(api, before, after):
    if not SHA.fullmatch(before) or not SHA.fullmatch(after):
        raise ValueError('invalid source commit')
    commits, page, status = [], 1, None
    while True:
        result = api.get('repos/' + LINUX + '/compare/' + before + '...' + after +
                         '?per_page=100&page=' + str(page))
        status = result['status']
        commits.extend({'sha': c['sha'], 'subject': c['commit']['message'].splitlines()[0]}
                       for c in result['commits'])
        if len(commits) >= result['total_commits']:
            break
        if not result['commits']:
            raise ValueError('incomplete GitHub comparison')
        page += 1
    return status, commits


def changes(api, before, after):
    if before is None:
        return {'status': 'first_release', 'added': [], 'removed': [], 'compare_url': None}
    if before == after:
        return {'status': 'unchanged', 'added': [], 'removed': [], 'compare_url': None}
    status, added = compare(api, before, after)
    removed = compare(api, after, before)[1] if status in ('diverged', 'behind') else []
    return {'status': 'rewritten' if status in ('diverged', 'behind') else status,
            'added': added, 'removed': removed,
            'compare_url': 'https://github.com/' + LINUX + '/compare/' + before + '...' + after}


def release_tag(api, repository, requested, run_id, attempt):
    tag = requested or ('pvm-oot-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d')
                        + '-' + run_id + '-' + attempt)
    # Flat asset-safe tag names; reject whitespace, Git ref special syntax and
    # shell options before passing the value to either the API or gh.
    if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', tag) or
            '..' in tag or tag.endswith(('.', '.lock'))):
        raise ValueError('invalid release tag: use letters, digits, dots, hyphens or underscores')
    try:
        api.get('repos/' + repository + '/git/ref/tags/' + urllib.parse.quote(tag, safe=''))
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        raise ValueError('release tag already exists; tags are never overwritten')
    return tag


def snapshot(api, repository, context_sha, run_id, attempt, requested_tag=''):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid repository')
    if not SHA.fullmatch(context_sha) or not run_id.isdigit() or not attempt.isdigit():
        raise ValueError('invalid workflow identity')
    tag = release_tag(api, repository, requested_tag, run_id, attempt)
    previous = previous_release(api, repository)
    sources = {}
    # Resolve both branch tips before comparison or any build; never resolve again.
    for key, branch in BRANCHES.items():
        sha = api.get('repos/' + LINUX + '/commits/' + branch)['sha']
        if not SHA.fullmatch(sha):
            raise ValueError('invalid GitHub commit identity')
        sources[key] = {'repository': LINUX, 'branch': branch, 'commit': sha}
    for key, source in sources.items():
        old = previous['sources'][key]['commit'] if previous else None
        source.update(previous_commit=old, changes=changes(api, old, source['commit']))
    return {'format': 1, 'tag': tag, 'context_commit': context_sha,
            'repository': repository, 'run_id': run_id, 'run_attempt': attempt,
            'previous_release': previous['tag'] if previous else None,
            'sources': sources}


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo)] + list(args))


def fetch(repo, sha):
    if not SHA.fullmatch(sha):
        raise ValueError('invalid source commit')
    try:
        git(repo, 'cat-file', '-e', sha + '^{commit}')
    except subprocess.CalledProcessError:
        git(repo, 'fetch', '--no-tags', '--depth=1', 'https://github.com/' + LINUX + '.git', sha)


def update_target(context, repo, target, sources):
    manifest_path = context / 'targets' / target / 'manifest.txt'
    values = dict(line.split('=', 1) for line in manifest_path.read_text().splitlines() if line)
    version = tuple(int(v) for v in values['kernel_release'].split('-', 1)[0].split('.')[:2])
    if version < (6, 6) or version > (7, 0):
        raise ValueError('unsupported OOT base range')
    key = 'oot_66' if version < (6, 12) else 'oot_612'
    commit = sources[key]['commit']
    profile_path = values['profile']
    if (not profile_path.startswith('tools/pvm-oot/profiles/') or
            '..' in Path(profile_path).parts):
        raise ValueError('invalid profile path')
    content = git(repo, 'show', commit + ':' + profile_path)
    profile = json.loads(content)
    if profile['format'] != 1 or profile['target']['kernel_release'] != values['kernel_release']:
        raise ValueError('latest branch profile does not match target kernel')
    # The branch tip selects profile/tooling; only the kernel-owned profile
    # selects the source baseline. An unavailable pin must fail, not fall back.
    baseline = profile['source']['commit']
    fetch(repo, baseline)
    values.update(base_commit=baseline, source_export_commit=baseline,
                  profile_commit=commit, profile_sha256=hashlib.sha256(content).hexdigest())
    manifest_path.write_text(''.join(k + '=' + v + '\n' for k, v in values.items()))
    config = manifest_path.with_name('config.sh')
    text, count = re.subn(r'^PVM_BASE_COMMIT=.*$', 'PVM_BASE_COMMIT=' + baseline,
                          config.read_text(), flags=re.MULTILINE)
    if count != 1:
        raise ValueError('expected one target base pin')
    config.write_text(text)
    return {'target': target, 'kernel': values['kernel_release'], 'source': key,
            'branch_commit': commit, 'base_commit': baseline,
            'source_fingerprint': profile['source']['export_tree_sha256'],
            'profile': profile_path, 'profile_sha256': values['profile_sha256']}


def collect(output, target, destination):
    provenances = list(output.glob('*/provenance.json'))
    if len(provenances) != 1:
        raise ValueError('expected exactly one current-run qualification')
    work = provenances[0].parent
    provenance = json.loads(provenances[0].read_text())
    if (provenance['target'] != target['target'] or provenance['full_test'] != 'PASS' or
            provenance['base_commit'] != target['base_commit'] or
            provenance['profile_sha256'] != target['profile_sha256']):
        raise ValueError('qualification pins do not match release')
    reboot = list(work.glob('reboot-restore/result.env'))
    if len(reboot) != 1:
        raise ValueError('missing reboot-restore evidence')
    result = dict(line.split('=', 1) for line in reboot[0].read_text().splitlines())
    if (result.get('result') != 'PASS' or result.get('kernel') != target['kernel'] or
            not result.get('template_id') or not result.get('boot_before') or
            not result.get('boot_after') or result['boot_before'] == result['boot_after']):
        raise ValueError('invalid persisted-template qualification')
    rpms = list(work.glob('rpm/*.rpm'))
    if len(rpms) != 1:
        raise ValueError('expected exactly one RPM per target')
    rpm = rpms[0]
    sha = digest(rpm)
    if rpm.with_name(rpm.name + '.sha256').read_text().split()[0] != sha:
        raise ValueError('RPM checksum mismatch')
    # The RPM name already carries its kernel; prefix only the distribution.
    name = target['target'].split('/', 1)[0] + '-' + rpm.name
    if (destination / name).exists():
        raise ValueError('duplicate release RPM asset: ' + name)
    shutil.copyfile(str(rpm), str(destination / name))
    return dict(target, rpm=name, rpm_sha256=sha, full_test='PASS', reboot_restore='PASS',
                source_bundle_sha256=provenance['source_bundle_sha256'],
                runtime_sha256=provenance['runtime_sha256'],
                image_recipe_sha256=provenance['image_recipe_sha256'])


def notes(manifest):
    lines = ['# ' + manifest['tag'], '', 'Context: `' + manifest['context_commit'] + '`',
             'Previous release: ' + (manifest['previous_release'] or 'none (first release)'), '']
    for key, source in sorted(manifest['sources'].items()):
        change = source['changes']
        lines.extend(['## ' + source['branch'], '', 'Profile/tooling commit: `' + source['commit'] + '`',
                      'Profile/tooling history: ' + change['status'], ''])
        if change['compare_url']:
            lines.append('[Compare](' + change['compare_url'] + ')')
        for label in ('added', 'removed'):
            lines.append('\n' + label.title() + ':')
            lines.extend('- `' + c['sha'][:12] + '` ' + c['subject'].replace('<', '&lt;').replace('>', '&gt;')
                         for c in change[label][:50])
            if len(change[label]) > 50:
                lines.append('- Remaining commits are listed in release-manifest.json.')
            if not change[label]:
                lines.append('- None')
        lines.append('')
    lines.extend(['## Packages', '', 'All targets passed full runtime and persisted-template tests.', ''])
    lines.extend('- ' + t['target'] + ': `' + t['rpm'] + '` (source pin: `' +
                 t['base_commit'] + '`)' for t in manifest['targets'])
    return '\n'.join(lines) + '\n'


def build(plan, workspace, env_dir):
    if git(ROOT, 'rev-parse', 'HEAD').decode().strip() != plan['context_commit']:
        raise ValueError('checkout does not match release context commit')
    # A fresh directory prevents picking up artifacts from old runs or attempts.
    workspace.mkdir(parents=True, exist_ok=False)
    context = workspace / 'context'
    tracked = git(ROOT, 'ls-files', '-z').decode().split('\0')
    for name in filter(None, tracked):
        dest = context / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(ROOT / name), str(dest))
    repo = workspace / 'linux.git'
    subprocess.check_call(['git', 'init', '--bare', str(repo)])
    for source in plan['sources'].values():
        fetch(repo, source['commit'])
    targets = sorted(str(p.parent.relative_to(context / 'targets'))
                     for p in (context / 'targets').glob('*/*/manifest.txt'))
    if not targets:
        raise ValueError('no release targets')
    prepared = [update_target(context, repo, target, plan['sources']) for target in targets]
    assets = workspace / 'assets'
    assets.mkdir()
    bundles = workspace / 'bundles'
    results = []
    for target in prepared:
        tag = target['target'].replace('/', '-')
        env = env_dir / (tag + '.env')
        if not env.is_file():
            raise ValueError('missing factory env for ' + target['target'])
        # Source env first, then override only release input paths. The release
        # runs on the registered validation host, not a delegated controller.
        wrapper = workspace / (tag + '.env')
        wrapper.write_text('source ' + shlex.quote(str(env.resolve())) + '\n'
                           '[[ ${PVM_FACTORY_HOST:-local} == local ]] || exit 2\n'
                           'PVM_OOT_REPO=' + shlex.quote(str(repo)) + '\n'
                           'PVM_SOURCE_BUNDLES=' + shlex.quote(str(bundles)) + '\n')
        wrapper.chmod(0o600)
        subprocess.check_call(['bash', str(context / 'scripts/pvm-ci'), 'run',
                               target['target'], '--env', str(wrapper)])
        results.append(collect(context / '.artifacts/pipeline' / tag, target, assets))
    manifest = dict(plan, targets=results)
    write_json(assets / 'release-manifest.json', manifest)
    (assets / 'release-notes.md').write_text(notes(manifest))
    (assets / 'SHA256SUMS').write_text(''.join(digest(p) + '  ' + p.name + '\n'
                                             for p in sorted(assets.iterdir()) if p.is_file()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command')
    freeze = sub.add_parser('snapshot')
    freeze.add_argument('--output', type=Path, required=True)
    run = sub.add_parser('build')
    run.add_argument('--plan', type=Path, required=True)
    run.add_argument('--workspace', type=Path, required=True)
    run.add_argument('--env-dir', type=Path, required=True)
    args = parser.parse_args()
    if not args.command:
        parser.error('a subcommand is required')
    if args.command == 'snapshot':
        result = snapshot(GitHub(), os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_SHA'],
                          os.environ['GITHUB_RUN_ID'], os.environ['GITHUB_RUN_ATTEMPT'],
                          os.environ.get('PVM_RELEASE_TAG', ''))
        write_json(args.output, result)
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('tag=' + result['tag'] + '\n')
    else:
        build(json.loads(args.plan.read_text()), args.workspace, args.env_dir)


if __name__ == '__main__':
    main()
