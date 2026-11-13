#!/usr/bin/env python3
"""Immutable image preparation and disposable full qualification runs."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
import tarfile
import time
import uuid
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
DNS_HELPERS = ('coredns-start.sh', 'coredns-postcheck.sh', 'dns-host-route-up.sh')


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def run(argv, **kwargs):
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def pins(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines()
                if line and not line.startswith('#'))


def checksum_for(text, filename):
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 2 and re.fullmatch(r'[a-fA-F0-9]{64}', fields[0]):
            if fields[1].lstrip('*') == filename:
                return fields[0].lower()
        match = re.fullmatch(r'SHA256\s*\((.+)\)\s*=\s*([a-fA-F0-9]{64})', line.strip())
        if match and match.group(1) == filename:
            return match.group(2).lower()
    raise ValueError('official checksum not found for ' + filename)


def download(url, dest):
    if urlparse(url).scheme != 'https':
        raise ValueError('official image inputs must use HTTPS')
    part = Path(str(dest) + '.part')
    run(['curl', '--noproxy', '*', '-fL', '--retry', '3', '--connect-timeout', '15',
         '--max-time', os.environ.get('PVM_DOWNLOAD_TIMEOUT', '7200'), '-o', part, url])
    part.replace(dest)


def safe_extract(archive, dest):
    # Git sources can contain relative symlinks, but never escaping links.
    with tarfile.open(str(archive)) as source:
        members = source.getmembers()
        symlinks = {m.name.rstrip('/') for m in members if m.issym()}
        for member in members:
            if (member.name.startswith('/') or '..' in Path(member.name).parts
                    or not (member.isfile() or member.isdir() or member.issym())):
                raise ValueError('unsafe source bundle member: ' + member.name)
            if member.issym():
                resolved = (dest / member.name).parent.joinpath(member.linkname).resolve()
                if dest.resolve() not in resolved.parents:
                    raise ValueError('escaping source symlink: ' + member.name)
        for member in members:
            parent = (dest / member.name).parent
            while parent != dest:
                if str(parent.relative_to(dest)) in symlinks:
                    raise ValueError('archive writes through a symlink')
                parent = parent.parent
        source.extractall(str(dest))


def force_prepare_requested():
    value = os.environ.get('PVM_FORCE_PREPARE', '0')
    if value not in ('0', '1'):
        raise ValueError('PVM_FORCE_PREPARE must be 0 or 1')
    return value == '1'


def sealed_image_matches(record, identity):
    if record.get('recipe_sha256') != identity or not Path(record['seed']).is_file():
        return False
    for name in ('root', 'shared'):
        disk = Path(record[name])
        if not disk.is_file() or disk.stat().st_mode & 0o222 or sha(disk) != record[name + '_sha256']:
            return False
    return True


def cached_kernel_rpms(profile, kernel, directory):
    if not directory or not profile.get('kernel_rpms'):
        return []
    version, suffix = kernel.split('-', 1)
    release, arch = suffix.rsplit('.', 1)
    files = []
    for template in profile['kernel_rpms']:
        url = template.format(kernel=kernel, version=version, release=release, arch=arch)
        path = Path(directory) / Path(urlparse(url).path).name
        expected = Path(str(path) + '.sha256').read_text().split()[0]
        if not re.fullmatch('[a-f0-9]{64}', expected) or sha(path) != expected:
            raise ValueError('cached native kernel RPM checksum mismatch: ' + path.name)
        files.append(path)
    return files


def image_profile(target, root=ROOT):
    profile = json.loads((root / 'images/profiles.json').read_text())[target.split('/')[0]]
    override = root / 'targets' / target / 'image.json'
    if override.is_file():
        profile.update(json.loads(override.read_text()))
    return profile


class Pipeline:
    def __init__(self, target):
        if not re.fullmatch(r'[a-z0-9.-]+/[a-zA-Z0-9._-]+', target):
            raise ValueError('invalid target')
        self.target = target
        self.pin = pins(ROOT / 'targets' / target / 'manifest.txt')
        self.kernel = self.pin['kernel_release']
        self.profile = image_profile(target)
        self.profile['compiler'] = os.environ.get('PVM_CC', self.profile['compiler'])
        self.base = Path(os.environ['PVM_FACTORY_ROOT']).resolve()
        if len(self.base.parts) < 3 or str(self.base) in ('/var/lib', '/usr/local', '/home', '/root'):
            raise ValueError('PVM_FACTORY_ROOT must be a dedicated, non-system directory')
        self.base.mkdir(parents=True, exist_ok=True)
        os.chmod(str(self.base), 0o700)
        self.key = self.base / 'keys' / 'factory'
        self.key.parent.mkdir(parents=True, exist_ok=True)
        with (self.key.parent / '.lock').open('a') as key_lock:
            fcntl.flock(key_lock, fcntl.LOCK_EX)
            if not self.key.exists():
                run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', self.key])
        self.tag = target.replace('/', '-')
        self.images = self.base / 'images' / self.tag
        self.images.mkdir(parents=True, exist_ok=True)
        self.pointer = self.images / 'current.json'
        self.lock = (self.images / '.lock').open('a')
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.active = False
        self.kernel_rpm_files = []
        self.dns_helper_sha256 = {}
        self.qemu = os.environ.get('PVM_QEMU_BIN', 'qemu-system-x86_64')
        self.cpus = int(os.environ.get('PVM_VM_CPUS', '8'))
        if self.cpus < 2:
            raise ValueError('at least two guest CPUs are required')
        self.jobs = min(int(os.environ.get('PVM_JOBS', str(self.cpus // 2))), self.cpus // 2)
        if self.jobs < 1:
            raise ValueError('invalid build concurrency')

    def bundle(self):
        directory = Path(os.environ['PVM_SOURCE_BUNDLES'])
        archive = directory / (self.tag + '.tar.gz')
        repository = os.environ.get('PVM_OOT_REPO')
        if repository:
            run(['python3', ROOT / 'tools/export-oot-source.py', self.target,
                 '--repo', repository, '--output', archive])
        sidecar = Path(str(archive) + '.sha256')
        expected = sidecar.read_text().split()[0]
        if not re.fullmatch('[a-f0-9]{64}', expected) or sha(archive) != expected:
            raise ValueError('source bundle checksum mismatch')
        dest = self.base / 'sources' / expected
        if not dest.exists():
            temporary = dest.with_name(expected + '-' + uuid.uuid4().hex)
            temporary.mkdir(parents=True)
            safe_extract(archive, temporary)
            meta = json.loads((temporary / 'bundle.json').read_text())
            if (meta['target'] != self.target or meta['base_commit'] != self.pin['base_commit']
                    or meta['profile_sha256'] != self.pin['profile_sha256']):
                raise ValueError('source bundle target pins mismatch')
            profile = temporary / 'tool' / self.pin['profile']
            if sha(profile) != self.pin['profile_sha256']:
                raise ValueError('source bundle profile checksum mismatch')
            temporary.rename(dest)
        self.bundle_path, self.bundle_sha = archive, expected
        self.bundle_dir = dest
        self.oot_profile = json.loads((dest / 'tool' / self.pin['profile']).read_text())

    def workspace(self, kind):
        self.work = self.base / kind / self.tag / (time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + uuid.uuid4().hex[:8])
        self.work.mkdir(parents=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', int(os.environ.get('PVM_FACTORY_PORT', '0'))))
            self.port = sock.getsockname()[1]
        self.env = os.environ.copy()
        self.env.update({
            'PVM_SSH_HOST': 'local', 'PVM_VM_PORT': str(self.port),
            'PVM_VM_USER': self.profile['user'], 'PVM_VM_KEY': str(self.key),
            'PVM_VM_KNOWN_HOSTS': str(self.work / 'known_hosts'),
            'PVM_VM_NAME': 'pvm-factory-' + uuid.uuid4().hex[:12],
            'PVM_VM_ROOT_DISK': str(self.work / 'root.qcow2'),
            'PVM_VM_SHARED_DISK': str(self.work / 'shared.qcow2'),
            'PVM_VM_SEED_ISO': '', 'PVM_VM_CPUS': str(self.cpus),
            'PVM_VM_MEMORY': os.environ.get('PVM_VM_MEMORY', '16G'),
            'PVM_VM_PIDFILE': str(self.work / 'qemu.pid'),
            'PVM_VM_SERIAL_LOG': str(self.work / 'serial.log'),
            'PVM_QEMU_BIN': self.qemu, 'PVM_VM_USE_SUDO': '0',
            'PVM_JOBS': str(self.jobs), 'PVM_VM_READY_TIMEOUT': '600',
        })
        self.env.pop('PVM_VM_PASSWORD', None)

    def guest(self, command, **kwargs):
        argv = ['ssh', '-T', '-F', '/dev/null', '-i', self.key, '-o', 'BatchMode=yes',
                '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=accept-new',
                '-o', 'UserKnownHostsFile=' + str(self.work / 'known_hosts'),
                '-p', str(self.port), self.profile['user'] + '@127.0.0.1',
                'sudo -n bash -lc ' + shlex.quote(command)]
        return run(argv, **kwargs)

    def start(self):
        run(['bash', ROOT / 'scripts/vm/ensure-qemu.sh'], env=self.env)
        self.active = True
        self.wait('true')

    def guest_write(self, destination, content, mode=0o600):
        program = '''import os, shutil, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, int(sys.argv[2], 8))
os.fchmod(fd, int(sys.argv[2], 8))
with os.fdopen(fd, 'wb') as output:
    shutil.copyfileobj(sys.stdin.buffer, output)
'''
        command = 'python3 -c ' + shlex.quote(program) + ' ' + shlex.quote(str(destination)) + ' ' + format(mode, 'o')
        self.guest(command, input=content)

    def wait(self, command, timeout=600):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                self.guest(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
            except subprocess.CalledProcessError:
                time.sleep(3)
        raise RuntimeError('VM readiness timeout; inspect ' + str(self.work / 'serial.log'))

    def stop(self):
        if not self.active:
            return
        try:
            self.guest('systemctl poweroff --no-block', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            pass  # SSH can close before returning the poweroff exit status.
        deadline = time.monotonic() + 300
        pidfile = self.work / 'qemu.pid'
        while time.monotonic() < deadline:
            if not pidfile.exists():
                self.active = False
                return
            # QEMU removes its pidfile only after closing the disk images.
            time.sleep(2)
        raise RuntimeError('VM did not shut down; working disks retained')

    def overlay(self, name, backing):
        run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', backing, self.work / name])

    def stage(self):
        self.guest('rm -rf /var/lib/pvm-factory/source; install -d /var/lib/pvm-factory/context /var/lib/pvm-factory/source')
        files = ['scripts', 'lib', 'targets', 'images']
        with (self.work / 'controller.tar').open('wb') as output:
            run(['tar', '-C', ROOT, '-cf', '-', *files], stdout=output)
        with (self.work / 'controller.tar').open('rb') as source:
            self.guest('tar -C /var/lib/pvm-factory/context -xf -', stdin=source)
        with (self.work / 'controller.tar').open('rb') as source:
            self.guest('if mountpoint -q /build; then install -d /build/pvm/context; tar -C /build/pvm/context -xf -; else cat >/dev/null; fi', stdin=source)
        with self.bundle_path.open('rb') as source:
            self.guest('tar -C /var/lib/pvm-factory/source -xzf -', stdin=source)
        if self.kernel_rpm_files:
            with (self.work / 'kernel-rpms.tar').open('wb') as output:
                run(['tar', '-C', self.kernel_rpm_files[0].parent, '-cf', '-',
                     *[p.name for p in self.kernel_rpm_files]], stdout=output)
            with (self.work / 'kernel-rpms.tar').open('rb') as source:
                self.guest('install -d /var/lib/pvm-factory/kernel-rpms; tar -C /var/lib/pvm-factory/kernel-rpms -xf -', stdin=source)
        hook = os.environ.get('PVM_DNS_SCRIPTS_DIR')
        if hook:
            names = DNS_HELPERS
            for name in names:
                if not (Path(hook) / name).is_file():
                    raise ValueError('missing local DNS helper: ' + name)
            self.dns_helper_sha256 = {name: sha(Path(hook) / name) for name in names}
            with (self.work / 'dns.tar').open('wb') as output:
                run(['tar', '-C', hook, '-cf', '-', *names], stdout=output)
            with (self.work / 'dns.tar').open('rb') as source:
                self.guest('install -d /var/lib/pvm-factory/dns; tar -C /var/lib/pvm-factory/dns -xf -', stdin=source)
            for name, expected in self.dns_helper_sha256.items():
                result = self.guest('sha256sum /var/lib/pvm-factory/dns/' + name, stdout=subprocess.PIPE)
                if result.stdout.split()[0].decode() != expected:
                    raise ValueError('local DNS helper changed during staging: ' + name)
        prepare_hook = os.environ.get('PVM_GUEST_PREPARE_HOOK')
        if prepare_hook:
            self.guest_write('/var/lib/pvm-factory/prepare-hook.sh', Path(prepare_hook).read_bytes(), 0o700)

    def guest_config(self):
        config = dict(self.profile)
        if self.kernel_rpm_files:
            config['kernel_rpms'] = ['/var/lib/pvm-factory/kernel-rpms/' + p.name for p in self.kernel_rpm_files]
        config.update({'kernel': self.kernel, 'jobs': self.jobs,
                       'compiler_version': self.oot_profile['target']['compiler_version'],
                       'profile': self.pin['profile'], 'profile_sha256': self.pin['profile_sha256']})
        for name in ('PVM_EXTRA_PACKAGES', 'PVM_APT_SNAPSHOT', 'PVM_KERNEL_DEB_VERSION', 'PVM_APT_MIRROR'):
            config[name] = os.environ.get(name, '')
        content = json.dumps(config).encode()
        self.guest_write('/var/lib/pvm-factory/config.json', content)

    def apply_dns_helpers(self):
        if not self.dns_helper_sha256:
            return
        self.guest('install -m0755 /var/lib/pvm-factory/dns/*.sh /build/pvm-shared/runtime/cubesandbox/scripts/systemd/; systemctl restart cube-sandbox-coredns.service cube-sandbox-dns.service')

    def check_staged_recipe(self, recipe):
        if getattr(self, 'dns_helper_sha256', {}) != recipe.get('dns_helpers', {}):
            raise RuntimeError('local DNS helpers changed during image preparation')
        for key, path in (('provision_sha256', 'scripts/vm/provision-image.sh'),
                          ('attach_sha256', 'scripts/attach-shared-runtime.sh')):
            result = self.guest('sha256sum /var/lib/pvm-factory/context/' + path, stdout=subprocess.PIPE)
            if result.stdout.split()[0].decode() != recipe[key]:
                raise RuntimeError('controller inputs changed during image preparation; retry from a stable checkout')

    def prepare(self):
        force = force_prepare_requested()
        self.bundle()
        self.kernel_rpm_files = cached_kernel_rpms(self.profile, self.kernel, os.environ.get('PVM_KERNEL_RPM_CACHE_DIR'))
        assets = self.base / 'assets'
        assets.mkdir(exist_ok=True)
        url = os.environ.get('PVM_IMAGE_URL', self.profile['image_url'])
        expected = os.environ.get('PVM_IMAGE_SHA256', self.profile.get('image_sha256', ''))
        if not expected:
            sums = assets / ('checksums-' + uuid.uuid4().hex)
            download(os.environ.get('PVM_IMAGE_CHECKSUMS_URL', self.profile['checksums_url']), sums)
            expected = checksum_for(sums.read_text(), Path(urlparse(url).path).name)
        if not re.fullmatch('[a-f0-9]{64}', expected):
            raise ValueError('invalid official image checksum')
        image = assets / (expected + '.qcow2')
        if not image.exists():
            cached = os.environ.get('PVM_IMAGE_FILE')
            if cached:
                run(['cp', '--reflink=auto', cached, image])
            else:
                download(url, image)
        if sha(image) != expected:
            raise ValueError('official image checksum mismatch')
        runtime = Path(os.environ['PVM_RUNTIME_BASE']).resolve()
        runtime_sha = os.environ['PVM_RUNTIME_SHA256']
        if sha(runtime) != runtime_sha:
            raise ValueError('shared runtime checksum mismatch')
        if runtime.stat().st_mode & 0o222:
            raise ValueError('shared runtime base must be read-only')
        recipe = {'format': 1, 'target': self.target, 'kernel': self.kernel,
                  'official_image_sha256': expected, 'runtime_sha256': runtime_sha,
                  'profile_sha256': self.pin['profile_sha256'],
                  'catalog': self.profile, 'key_sha256': sha(str(self.key) + '.pub'),
                  'provision_sha256': sha(ROOT / 'scripts/vm/provision-image.sh'),
                  'attach_sha256': sha(ROOT / 'scripts/attach-shared-runtime.sh')}
        recipe['kernel_rpm_sha256'] = {p.name: sha(p) for p in self.kernel_rpm_files}
        for name in ('PVM_EXTRA_PACKAGES', 'PVM_APT_SNAPSHOT', 'PVM_KERNEL_DEB_VERSION', 'PVM_APT_MIRROR'):
            recipe[name] = os.environ.get(name, '')
        hook = os.environ.get('PVM_DNS_SCRIPTS_DIR')
        recipe['dns_helpers'] = {name: sha(Path(hook) / name) for name in DNS_HELPERS} if hook else {}
        prepare_hook = os.environ.get('PVM_GUEST_PREPARE_HOOK')
        recipe['prepare_hook_sha256'] = sha(prepare_hook) if prepare_hook else None
        identity = hashlib.sha256(json.dumps(recipe, sort_keys=True).encode()).hexdigest()
        if not force and self.pointer.exists() and sealed_image_matches(json.loads(self.pointer.read_text()), identity):
            print('PVM_IMAGE_REUSED=1 target=' + self.target)
            return
        self.workspace('preparing')
        run(['qemu-img', 'convert', '-O', 'qcow2', image, self.work / 'root.qcow2'])
        run(['qemu-img', 'resize', self.work / 'root.qcow2', os.environ.get('PVM_ROOT_SIZE', '48G')])
        self.overlay('shared.qcow2', runtime)
        user_data = {'users': [{'name': self.profile['user'], 'shell': '/bin/bash',
                               'sudo': 'ALL=(ALL) NOPASSWD:ALL', 'lock_passwd': True,
                               'ssh_authorized_keys': [(Path(str(self.key) + '.pub')).read_text().strip()]}],
                     'disable_root': True, 'ssh_pwauth': False,
                     'growpart': {'mode': 'auto', 'devices': ['/'], 'ignore_growroot_disabled': True},
                     'resize_rootfs': True}
        (self.work / 'user-data').write_text('#cloud-config\n' + json.dumps(user_data))
        (self.work / 'meta-data').write_text(json.dumps({'instance-id': self.env['PVM_VM_NAME'], 'local-hostname': 'pvm-builder'}))
        seed = self.work / 'seed.iso'
        run(['genisoimage', '-quiet', '-output', seed, '-volid', 'cidata', '-joliet', '-rock',
             self.work / 'user-data', self.work / 'meta-data'])
        self.env['PVM_VM_SEED_ISO'] = str(seed)
        self.start()
        self.wait('cloud-init status --wait', timeout=900)
        self.stage()
        self.check_staged_recipe(recipe)
        self.guest_config()
        with (self.work / 'provision.log').open('wb') as log:
            self.guest('bash /var/lib/pvm-factory/context/scripts/vm/provision-image.sh', stdout=log, stderr=subprocess.STDOUT)
        self.stop()
        self.start()
        self.wait('test "$(uname -r)" = ' + shlex.quote(self.kernel) + ' && mountpoint -q /build')
        with (self.work / 'verify.log').open('wb') as log:
            self.guest('bash /var/lib/pvm-factory/context/scripts/vm/provision-image.sh --verify', stdout=log, stderr=subprocess.STDOUT)
        self.stop()
        for name in ('root.qcow2', 'shared.qcow2'):
            run(['qemu-img', 'check', self.work / name])
            os.chmod(str(self.work / name), 0o440)
        record = dict(recipe, recipe_sha256=identity, runtime=str(runtime), root=str(self.work / 'root.qcow2'),
                      shared=str(self.work / 'shared.qcow2'), seed=str(seed),
                      root_sha256=sha(self.work / 'root.qcow2'), shared_sha256=sha(self.work / 'shared.qcow2'))
        (self.work / 'image.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
        temporary = self.pointer.with_suffix('.part')
        temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
        temporary.replace(self.pointer)
        print('PVM_IMAGE_READY=1 target=' + self.target)

    def test(self):
        self.bundle()
        record = json.loads(self.pointer.read_text())
        if record['target'] != self.target or record['kernel'] != self.kernel:
            raise ValueError('prepared image target mismatch')
        info = json.loads(subprocess.check_output(['qemu-img', 'info', '--output=json', record['shared']]).decode())
        runtime = info.get('full-backing-filename', info.get('backing-filename'))
        if not runtime or sha(runtime) != record['runtime_sha256']:
            raise ValueError('shared runtime backing disk was modified')
        for name in ('root', 'shared'):
            if sha(record[name]) != record[name + '_sha256']:
                raise ValueError('prepared image was modified: ' + name)
        self.workspace('runs')
        self.overlay('root.qcow2', record['root'])
        self.overlay('shared.qcow2', record['shared'])
        self.env['PVM_VM_SEED_ISO'] = record['seed']
        self.start()
        self.wait('test "$(uname -r)" = ' + shlex.quote(self.kernel) + ' && mountpoint -q /build')
        self.stage()
        self.apply_dns_helpers()
        self.guest_config()
        with (self.work / 'source-prepare.log').open('wb') as log:
            self.guest('bash /var/lib/pvm-factory/context/scripts/vm/provision-image.sh --source', stdout=log, stderr=subprocess.STDOUT)
        output = ROOT / '.artifacts/pipeline' / self.tag / self.work.name
        output.mkdir(parents=True)
        self.env.update({
            'PVM_SOURCE_DIR': '/var/lib/pvm-factory/prepared',
            'PVM_ARTIFACT_DIR': '/var/lib/pvm-factory/rpms',
            'PVM_OUTPUT_DIR': str(output / 'rpm'), 'PVM_REBOOT_OUTPUT_DIR': str(output / 'reboot-restore'),
            'PVM_RESOLVE_BTFIDS': '/usr/local/libexec/pvm/resolve_btfids',
            'PVM_CC': self.profile['compiler'], 'PVM_PREPARE_COMMAND': 'true',
            'PVM_POST_TEST_COMMAND': 'FIRECRACKER=/opt/kata/bin/firecracker PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=45 /var/lib/pvm-factory/context/scripts/firecracker-pvm-test.sh /var/lib/pvm-factory/context/scripts/firecracker-pvm.json',
            'PVM_KATA_CONFIG_DIR': '/etc/kata-containers/pvm',
            'PVM_CUBE_ENV_FILE': '/build/pvm-shared/runtime/cubesandbox/.one-click.env',
            'PVM_CUBE_ROOT': '/build/pvm-shared',
        })
        local = self.work / 'run.env'
        local.write_text(''.join(name + '=' + shlex.quote(value) + '\n'
                                 for name, value in sorted(self.env.items()) if name.startswith('PVM_')
                                 and name not in ('PVM_FACTORY_HOST', 'PVM_FACTORY_ENV', 'PVM_FACTORY_CONTEXT')))
        os.chmod(str(local), 0o600)
        # Source freshness is verified before every build, including image reuse.
        run(['bash', ROOT / 'scripts/pvm-test', self.target, '--env', local, '--reboot-restore'])
        self.stop()
        (output / 'provenance.json').write_text(json.dumps({
            'format': 1, 'target': self.target, 'image_recipe_sha256': record['recipe_sha256'],
            'source_bundle_sha256': self.bundle_sha, 'profile_sha256': self.pin['profile_sha256'],
            'base_commit': self.pin['base_commit'], 'full_test': 'PASS',
            'dns_helpers_sha256': self.dns_helper_sha256,
        }, indent=2, sort_keys=True) + '\n')
        # Logs and artifacts survive; disposable state disks are opt-in to retain.
        if os.environ.get('PVM_KEEP_DISKS', '0') != '1':
            for name in ('root.qcow2', 'shared.qcow2'):
                (self.work / name).unlink()
        print('PVM_PIPELINE=PASS target=' + self.target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'run', 'all'])
    parser.add_argument('target')
    args = parser.parse_args()
    pipeline = Pipeline(args.target)
    try:
        if args.mode == 'prepare' or (args.mode == 'all' and not pipeline.pointer.exists()):
            pipeline.prepare()
        if args.mode in ('run', 'all'):
            pipeline.test()
    finally:
        if pipeline.active:
            try:
                pipeline.stop()
            except Exception as error:
                print('shutdown failed; retained VM and disks: ' + str(error), file=sys.stderr)


if __name__ == '__main__':
    main()
