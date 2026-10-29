"""Exercise the offline launch script against isolated launcher installations."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "play-installed.sh"


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("jq")
                     and shutil.which("sha1sum"), "needs Linux, jq and GNU coreutils")
class PlayInstalledTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="horizon-installed-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "source checkout"
        self.project.mkdir()
        self.script = self.project / "play-installed.sh"
        shutil.copyfile(SOURCE, self.script)
        self.home = self.root / "player home"
        self.home.mkdir()
        self.client = b"fixture client"
        self.server = b"fixture server"
        self.manifest = b'{"id":"26.3"}'
        digest = lambda data: hashlib.sha1(data).hexdigest()
        lock = {"minecraft": {
            "version": "26.3", "java_major": 25,
            "client_sha1": digest(self.client), "server_sha1": digest(self.server),
            "manifest_sha1": digest(self.manifest),
        }}
        (self.project / "research-lock.json").write_text(json.dumps(lock))
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("HORIZON_", "XDG_"))}
        self.env["HOME"] = str(self.home)

    def install(self, base=None, atlauncher=False):
        base = base or self.home / ".minecraft"
        (base / "libraries").mkdir(parents=True)
        (base / "assets").mkdir()
        if atlauncher:
            manifest = base / "configs/json/minecraft/26.3.json"
            client = base / "libraries/net/minecraft/client/26.3/client-26.3.jar"
        else:
            manifest = base / "versions/26.3/26.3.json"
            client = base / "versions/26.3/26.3.jar"
        for path, data in [(manifest, self.manifest), (client, self.client)]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return base, client, manifest

    def server_jar(self):
        jar = self.project / ".local/server.jar"
        jar.parent.mkdir(exist_ok=True)
        jar.write_bytes(self.server)
        return jar

    def run_check(self, *args):
        return subprocess.run(["bash", str(self.script), "--check", *map(str, args)],
                              env=self.env, capture_output=True, text=True, timeout=15)

    def test_missing_install_exits_before_dependencies_or_downloads(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Please install release 26.3 from your client", result.stderr)
        self.assertFalse((self.project / ".local").exists())

    def test_default_tlauncher_layout_and_spaces(self):
        self.install()
        self.server_jar()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.home / ".minecraft"), result.stdout)
        self.assertFalse((self.project / ".local/installed-minecraft").exists())

    def test_rejects_wrong_client_hash(self):
        _, client, _ = self.install()
        client.write_bytes(b"wrong version")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Please install release 26.3", result.stderr)

    def test_rejects_rewritten_manifest_without_local_original(self):
        _, _, manifest = self.install()
        manifest.write_bytes(b'{"id":"26.3","modified":true}')
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("original version JSON", result.stderr)

    def test_custom_folder_is_authoritative(self):
        self.install()
        custom = self.root / "missing custom launcher"
        result = self.run_check("--minecraft-dir", custom)
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(custom), result.stderr)

    def test_atlauncher_layout(self):
        base, _, _ = self.install(self.root / "AT Launcher", atlauncher=True)
        self.server_jar()
        result = self.run_check("--minecraft-dir", base)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_modrinth_flatpak_meta_layout(self):
        base = self.home / ".var/app/com.modrinth.ModrinthApp/data/ModrinthApp/meta"
        self.install(base)
        self.server_jar()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(base), result.stdout)

    def test_partial_default_does_not_hide_complete_other_launcher(self):
        _, client, _ = self.install()
        client.unlink()
        base, _, _ = self.install(self.home / ".local/share/PrismLauncher")
        self.server_jar()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(base), result.stdout)

    def test_server_is_required_and_checked(self):
        self.install()
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("--server-jar", result.stderr)
        bad = self.root / "wrong server.jar"
        bad.write_bytes(b"wrong server")
        result = self.run_check("--server-jar", bad)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match release 26.3", result.stderr)

    def test_help_does_not_require_installed_game(self):
        result = subprocess.run(["bash", str(self.script), "--help"], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--no-install", result.stdout)

    def test_package_managers_and_preparation_without_system_changes(self):
        self.install()
        self.server_jar()
        # Expose only these commands, so the host distro cannot affect detection.
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("bash", "uname", "dirname", "cat", "jq", "sha1sum", "cut", "find",
                     "basename", "realpath", "sed", "sort", "head", "mkdir", "cp", "ln"):
            (tools / name).symlink_to(shutil.which(name))
        def executable(path, body):
            path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
            path.chmod(0o755)
        for name in ("cc", "c++", "make", "cmake", "git", "curl", "tar"):
            executable(tools / name, "exit 0")
        executable(tools / "sudo", 'exec "$@"')
        executable(tools / "pkg-config", '[[ -f "$TEST_LOG/deps-ready" ]]')
        executable(tools / "cargo", 'printf "%s\\n" "$*" >> "$TEST_LOG/cargo"')
        executable(tools / "rustc", 'echo "rustc 1.99.1 (fixture)"')
        java = self.project / ".local/jdk25/bin"
        java.mkdir(parents=True)
        executable(java / "javac", 'echo "javac 25.0.1"')
        binaries = self.project / "target/release"
        binaries.mkdir(parents=True)
        executable(binaries / "horizon-prepare", 'printf "%s\\n" "$*" >> "$TEST_LOG/prepare"')
        (self.project / "crates/horizon-client").mkdir(parents=True)
        (self.project / "crates/horizon-client/Cargo.toml").write_text('rust-version = "1.90"\n')
        env = dict(self.env, PATH=str(tools), TEST_LOG=str(self.root), CARGO_HOME=str(tools))
        expected = {"pacman": "-S --needed", "apt-get": "install build-essential",
                    "dnf": "install gcc", "zypper": "install gcc"}
        for manager, arguments in expected.items():
            with self.subTest(manager=manager):
                package = tools / manager
                executable(package, 'printf "%s\\n" "$*" >> "$TEST_LOG/packages"\n'
                           ': > "$TEST_LOG/deps-ready"')
                result = subprocess.run([shutil.which("bash"), str(self.script), "--prepare-only"],
                                        env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(arguments, (self.root / "packages").read_text())
                self.assertIn("--prepare", (self.root / "prepare").read_text())
                self.assertIn("sounds", (self.root / "prepare").read_text())
                linked = self.project / ".local/installed-minecraft"
                self.assertEqual((linked / "assets").resolve(), self.home / ".minecraft/assets")
                package.unlink()
                for name in ("deps-ready", "packages", "prepare"):
                    (self.root / name).unlink()


if __name__ == "__main__":
    unittest.main()
