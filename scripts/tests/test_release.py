"""Fast, offline safety/argument checks. Real Xcode packaging is verified on the release Mac."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseGuardTests(unittest.TestCase):
    def run_script(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith('ASHOT_')}
        return subprocess.run(['bash', str(ROOT / 'release.sh'), *args], env=env,
                              capture_output=True, text=True, timeout=15)

    def test_help_has_no_side_effects(self):
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('--publish', result.stdout)

    def test_missing_version(self):
        self.assertEqual(self.run_script().returncode, 2)

    def test_invalid_versions(self):
        for version in ['v1.0.0', '../escape', '1.0', '1.0.0;echo bad', '1.0.0-']:
            with self.subTest(version=version):
                result = self.run_script(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('semantic version', result.stderr)

    def test_unknown_argument(self):
        result = self.run_script('1.0.0', '--force')
        self.assertIn('Unknown option', result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_unnotarized_stable_release_is_rejected(self):
        result = self.run_script('1.0.0', '--allow-unnotarized', '--publish')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('prerelease version', result.stderr)

    def test_trusted_release_requires_credentials(self):
        result = self.run_script('1.0.0', '--publish')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Developer ID', result.stderr)

    def test_build_rejects_unknown_signing(self):
        env = dict(os.environ, ASHOT_SIGNING='invalid')
        result = subprocess.run(['bash', str(ROOT / 'build.sh')], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 2)


class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for key, value in [('user.name', 'Test'), ('user.email', 'test@example.invalid'),
                           ('commit.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
            subprocess.run(['git', '-C', str(self.root), 'config', key, value], check=True)
        spec = importlib.util.spec_from_file_location('public_check', ROOT / 'scripts/check_public_files.py')
        self.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.checker)
        self.checker.ROOT = self.root
        (self.root / 'README.md').write_text('Example project\n')
        self.commit()

    def commit(self):
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.root), 'commit', '-qm', 'test'], check=True)

    def test_clean_sources_pass(self):
        self.assertEqual(self.checker.main(), 0)

    def test_private_file_type_is_rejected(self):
        (self.root / 'signing.p12').write_bytes(b'not a certificate')
        self.assertEqual(self.checker.main(), 1)

    def test_removed_secret_in_history_is_still_rejected(self):
        # Synthetic token; never a usable credential.
        path = self.root / 'fixture.txt'
        path.write_text('gh' + 'p_' + 'A' * 40)
        self.commit()
        path.unlink()
        self.commit()
        self.assertEqual(self.checker.main(), 1)


if __name__ == '__main__':
    unittest.main()
