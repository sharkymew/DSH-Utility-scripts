"""Run deletion regressions in disposable directories without changing HOME."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


class CleanupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='utility-cleanup-')
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'user'
        self.cfg = self.root / 'config' / 'dsh-installer'
        self.data = self.root / 'data' / 'dsh-installer'
        self.bin = self.root / 'bin'
        self.dsh = self.root / 'custom-home'
        self.source = self.root / 'source'
        self.cache = self.root / 'npm-cache'
        for p in (self.home, self.cfg, self.data, self.bin, self.dsh, self.cache):
            p.mkdir(parents=True)
        (self.dsh / '.dsh-installer-home').touch()
        (self.dsh / 'sessions').mkdir()
        (self.cfg / 'config').write_text('MODE=npx\nDSH_HOME_DIR=' + str(self.dsh) + '\n')
        self.prolog = 'source ' + shlex.quote(str(REPO / 'install.sh')) + '\n'
        variables = {'HOME_DIR': self.home, 'CFG_DIR': self.cfg, 'DATA_DIR': self.data,
                     'BIN_DIR': self.bin, 'CONFIG_FILE': self.cfg / 'config',
                     'PID_FILE': self.cfg / 'web.pid', 'LOG_FILE': self.cfg / 'web.log',
                     'RUN_SCRIPT': self.cfg / 'run-web.sh', 'LAUNCHER': self.bin / 'dsh-web',
                     'CLI_LINK': self.bin / 'dsh-installer', 'NODE_DIR': self.data / 'node',
                     'DSH_HOME_DIR': self.dsh, 'INSTALL_DIR': self.source}
        self.prolog += ''.join(k + '=' + shlex.quote(str(v)) + '\n' for k, v in variables.items())
        self.prolog += 'DSH_HOME_OVERRIDE=""\ncmd_stop() { return 2; }\nnpx_cache_dir() { printf "%s" ' + shlex.quote(str(self.cache)) + '; }\n'

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, script, expected=0):
        env = os.environ.copy()
        env.pop('DSH_HOME', None)
        try:
            result = subprocess.run([os.environ.get('DSH_TEST_BASH', 'bash'), '-c', self.prolog + script], env=env,
                                    text=True, capture_output=True, timeout=15)
        except UnicodeDecodeError as error:
            raise AssertionError('Shell emitted invalid UTF-8: ' + repr(error.object)) from error
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def cache_entry(self, name, package='@deepseek-ai/dsh'):
        p = self.cache / '_npx' / name / 'node_modules' / '@deepseek-ai' / 'dsh'
        p.mkdir(parents=True)
        (p / 'package.json').write_text(json.dumps({'name': package}))
        return p.parents[2]

    def source_repo(self):
        self.source.mkdir()
        def git(*args):
            subprocess.run(['git', '-C', str(self.source), *args], check=True, capture_output=True)
        git('init')
        (self.source / 'package.json').write_text('{"name": "@deepseek-ai/dsh-root"}\n')
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'initial')
        git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        (self.source / '.git' / 'dsh-installer-owned').touch()
        self.set_mode('source')
        return git

    def set_mode(self, mode):
        (self.cfg / 'config').write_text('MODE=' + mode + '\nDSH_HOME_DIR=' + str(self.dsh) + '\n')

    def hidden_local_work(self, kind):
        git = self.source_repo()
        base = subprocess.run(['git', '-C', str(self.source), 'rev-parse', 'HEAD'],
                              check=True, capture_output=True, text=True).stdout.strip()
        if kind == 'branch':
            git('checkout', '-b', 'unpublished-feature')
            (self.source / 'user.txt').write_text('unpublished work')
            git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'feature')
            git('checkout', '--detach', base)
        else:
            (self.source / 'package.json').write_text('{"name": "@deepseek-ai/dsh-root", "privateWork": true}\n')
            git('stash', 'push', '-m', 'unpublished work')
        return git

    def assert_hidden_work_preserved(self, kind, mode):
        self.hidden_local_work(kind)
        self.set_mode(mode)
        self.run_script('cmd_uninstall -y', 1)
        self.assertTrue(self.source.exists(), 'Deleted unpublished ' + kind)
        self.assertTrue((self.cfg / 'config').exists(), 'Lost retry configuration')

    def test_dry_run_preserves_every_file(self):
        entry = self.cache_entry('owned')
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        output = self.run_script('cmd_uninstall --purge --dry-run').stdout
        self.assertIn(str(self.dsh), output)
        self.assertIn(str(entry), output)
        self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*')))

    def test_purge_custom_home_and_all_owned_resources(self):
        entry = self.cache_entry('owned')
        other = self.cache / '_npx' / 'unrelated'
        other.mkdir()
        (self.bin / 'dsh-web').write_text('# Generated by dsh-installer 1.2.0\n')
        (self.bin / 'dsh-installer').symlink_to(REPO / 'install.sh')
        node = self.data / 'node'
        (node / 'bin').mkdir(parents=True)
        (node / '.installed-by-dsh-installer').touch()
        for name in ('node', 'npm', 'npx', 'corepack'):
            # Already broken links must also disappear.
            (self.bin / name).symlink_to(node / 'bin' / name)
        pnpm = self.data / 'pnpm'
        pnpm.mkdir()
        (pnpm / '.installed-by-dsh-installer').touch()
        self.run_script('cmd_uninstall --purge -y')
        for p in (self.dsh, entry, node, pnpm, self.cfg):
            self.assertFalse(p.exists(), str(p))
        self.assertFalse(any(self.bin.iterdir()))
        self.assertTrue(other.exists())

    def test_default_uninstall_preserves_data_and_unowned_files(self):
        (self.cfg / 'notes.txt').write_text('keep')
        (self.bin / 'dsh-web').write_text('user program')
        (self.bin / 'npm').symlink_to('/unrelated/npm')
        self.run_script('cmd_uninstall -y')
        self.assertTrue(self.dsh.exists())
        self.assertTrue((self.cfg / 'notes.txt').exists())
        self.assertTrue((self.bin / 'dsh-web').exists())
        self.assertTrue((self.bin / 'npm').is_symlink())

    def test_source_mode_also_clears_npx_cache(self):
        self.source_repo()
        entry = self.cache_entry('owned')
        self.run_script('MODE=source; cmd_uninstall --purge -y')
        self.assertFalse(self.source.exists())
        self.assertFalse(entry.exists())

    def test_dirty_source_preserved_even_with_yes(self):
        self.source_repo()
        (self.source / 'user.txt').write_text('work')
        self.run_script('MODE=source; cmd_uninstall -y', 1)
        self.assertTrue((self.source / 'user.txt').exists())
        self.assertTrue((self.cfg / 'config').exists())

    def test_unpushed_commit_preserved_even_with_yes(self):
        git = self.source_repo()
        (self.source / 'user.txt').write_text('work')
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'local')
        self.run_script('MODE=source; cmd_uninstall -y', 1)
        self.assertTrue(self.source.exists())

    def test_other_local_branch_preserved_in_source_mode(self):
        self.assert_hidden_work_preserved('branch', 'source')

    def test_other_local_branch_preserved_after_switch_to_npx(self):
        self.assert_hidden_work_preserved('branch', 'npx')

    def test_stash_preserved_in_source_mode(self):
        self.assert_hidden_work_preserved('stash', 'source')

    def test_stash_preserved_after_switch_to_npx(self):
        self.assert_hidden_work_preserved('stash', 'npx')

    def test_external_source_with_other_local_branch_is_rejected(self):
        git = self.hidden_local_work('branch')
        git('remote', 'add', 'origin', 'https://github.com/deepseek-ai/deepseek-harness.git')
        self.run_script('safe_external_source_repo "$INSTALL_DIR"', 1)
        self.assertTrue(self.source.exists())

    def test_external_source_with_stash_is_rejected(self):
        git = self.hidden_local_work('stash')
        git('remote', 'add', 'origin', 'https://github.com/deepseek-ai/deepseek-harness.git')
        self.run_script('safe_external_source_repo "$INSTALL_DIR"', 1)
        self.assertTrue(self.source.exists())

    def test_stop_failure_aborts_before_deletion(self):
        self.run_script('cmd_stop() { return 1; }; cmd_uninstall --purge -y', 1)
        self.assertTrue(self.dsh.exists())
        self.assertTrue((self.cfg / 'config').exists())

    def test_unsafe_home_checked_before_any_deletion(self):
        self.run_script('DSH_HOME_OVERRIDE="$HOME_DIR"; DSH_HOME_DIR="$HOME_DIR"; cmd_uninstall --purge -y', 1)
        self.assertTrue((self.cfg / 'config').exists())

    def test_symlink_parent_rejected(self):
        target = self.root / 'outside'
        target.mkdir()
        (target / '.dsh').mkdir()
        link = self.root / 'alias'
        link.symlink_to(target, target_is_directory=True)
        self.run_script('DSH_HOME_OVERRIDE=' + shlex.quote(str(link / '.dsh')) + '; DSH_HOME_DIR="$DSH_HOME_OVERRIDE"; cmd_uninstall --purge -y', 1)
        self.assertTrue((target / '.dsh').exists())

    def test_unrelated_npx_entry_not_deleted(self):
        entry = self.cache_entry('pretender', 'unrelated')
        self.run_script('cmd_uninstall -y')
        self.assertTrue(entry.exists())

    def test_removes_only_exact_installer_shell_path_block(self):
        self.run_script('printf "# custom\\n# dsh-installer PATH\\nexport PATH=%s:\\$PATH\\n# keep\\n" "$(shell_quote "$BIN_DIR")" > "$HOME_DIR/.bashrc"; cmd_uninstall -y')
        self.assertEqual((self.home / '.bashrc').read_text(), '# custom\n# keep\n')

    def test_saved_home_loaded_and_exported_in_launchers(self):
        self.run_script('DSH_HOME_DIR=/not-the-saved-home; load_config; write_run_script; write_launcher')
        self.assertIn(str(self.dsh), (self.cfg / 'run-web.sh').read_text())
        self.assertIn(str(self.dsh), (self.bin / 'dsh-web').read_text())

    def test_temp_cleanup_only_known_prefixes_and_current_owner(self):
        tmp = self.root / 'tmp'
        tmp.mkdir()
        owned = tmp / 'dsh-spill-orphan'
        owned.mkdir()
        other = tmp / 'dsh-unrelated'
        other.mkdir()
        # Override ps and /tmp selection to constrain the test to its own fixtures.
        self.run_script('TMPDIR=' + shlex.quote(str(tmp)) + '; ps() { printf "idle\\n"; }; cleanup_remove() { [ "$2" = ' + shlex.quote(str(owned)) + ' ] && rm -rf -- "$2"; return 0; }; cleanup_dsh_temp')
        self.assertFalse(owned.exists())
        self.assertTrue(other.exists())

    def test_running_dsh_prevents_temp_cleanup(self):
        result = self.run_script('CLEANUP_FAILED=0; ps() { printf "node node /repo/apps/cli/src/bin.ts web\\n"; }; cleanup_dsh_temp; [ "$CLEANUP_FAILED" = 1 ]')
        self.assertIn('DSH', result.stderr)

    def test_other_dsh_instance_blocks_uninstall_before_deletion(self):
        self.run_script('dsh_processes_active() { return 0; }; cmd_uninstall --purge -y', 1)
        self.assertTrue(self.dsh.exists())
        self.assertTrue((self.cfg / 'config').exists())

    def test_stop_process_tree_stops_descendants_and_preserves_unrelated_process(self):
        helper = self.root / 'process.py'
        helper.write_text("import subprocess, time, pathlib\nchild=subprocess.Popen(['sleep','120'])\npathlib.Path(" + repr(str(self.root / 'child.pid')) + ").write_text(str(child.pid))\ntime.sleep(120)\n")
        parent = subprocess.Popen(['python', str(helper)])
        unrelated = subprocess.Popen(['sleep', '120'])
        try:
            deadline = time.monotonic() + 3
            while not (self.root / 'child.pid').exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            child = int((self.root / 'child.pid').read_text())
            self.run_script('stop_process_tree ' + str(parent.pid))
            parent.wait(timeout=3)
            self.assertIsNone(unrelated.poll(), 'Stopped unrelated process')
            state = subprocess.run(['ps', '-p', str(child), '-o', 'stat='], text=True, capture_output=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), state)
        finally:
            for process in (parent, unrelated):
                if process.poll() is None:
                    process.kill()
                process.wait()

    def test_open_uses_latest_authenticated_url(self):
        result = self.run_script('is_running() { return 0; }; printf "dsh web: http://127.0.0.1:3080/?token=old-token\\ndsh web: http://127.0.0.1:3080/?token=current-token\\n" > "$LOG_FILE"; web_open_url')
        self.assertEqual(result.stdout, 'http://127.0.0.1:3080/?token=current-token')

    def test_blank_and_tilde_home_match_upstream(self):
        self.run_script('DSH_HOME_DIR="  "; set_dsh_home; [ "$DSH_HOME_DIR" = "$HOME_DIR/.dsh" ]; DSH_HOME_DIR="~/custom"; set_dsh_home; [ "$DSH_HOME_DIR" = "$HOME_DIR/custom" ]')


if __name__ == '__main__':
    unittest.main()
