import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class LifecycleCommandTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_init_writes_install_receipt_after_successful_scaffold(self):
        init = self.read("commands/init.md")
        self.assertIn("## Phase 7 — Write the install receipt", init)
        self.assertIn("## Phase 8 — Summary", init)
        for required in [
            "docs/workflow/install-receipt.yaml",
            "receipt_version: 1",
            "fingerprint_method: sha256",
            "written_by: idc:init",
            "path:",
            "fingerprint:",
            "state: stamped",
            "final on-disk bytes",
            "never lists itself",
            "TRACKER.md",
            "skipped-existing",
            "pre-receipt install",
        ]:
            self.assertIn(required, init)

    def test_uninstall_command_documents_receipt_driven_revertable_removal(self):
        uninstall_path = ROOT / "commands/uninstall.md"
        self.assertTrue(uninstall_path.exists(), "commands/uninstall.md must exist")
        uninstall = uninstall_path.read_text(encoding="utf-8")
        for required in [
            "argument-hint: \"[--close-issues] [--delete-board]\"",
            "docs/workflow/install-receipt.yaml",
            "hardcoded footprint list",
            "WORKFLOW.md",
            "WORKFLOW-config.yaml",
            "docs/workflow/",
            "TRACKER.md",
            ".claude/settings.json",
            "idc-archive-",
            "single revertable commit",
            "skipped-absent",
            "could not verify in-flight items",
            "typed confirmation",
            "issue deletion is never offered",
            "claude plugin uninstall",
            "install-codex.sh --revert",
        ]:
            self.assertIn(required, uninstall)

    def test_update_and_upgrade_commands_preserve_operator_customizations(self):
        for command_name in ("update", "upgrade"):
            path = ROOT / "commands" / f"{command_name}.md"
            self.assertTrue(path.exists(), f"commands/{command_name}.md must exist")
            body = path.read_text(encoding="utf-8")
            for required in [
                "docs/workflow/install-receipt.yaml",
                "fingerprint mismatch",
                "operator review",
                "state: customized",
                "written_by: idc:update",
                "no silent overwrite",
                "skipped-existing",
                "CHANGELOG",
                "single revertable commit",
            ]:
                self.assertIn(required, body)

    def test_docs_and_manifest_advertise_lifecycle_commands(self):
        readme = self.read("README.md")
        installing = self.read("docs/installing.md")
        changelog = self.read("CHANGELOG.md")
        for text in (readme, installing):
            self.assertIn("/idc:uninstall", text)
            self.assertIn("/idc:update", text)
            self.assertIn("/idc:upgrade", text)
        self.assertIn("install-receipt", changelog)
        self.assertIn("/idc:uninstall", changelog)
        self.assertIn("/idc:update", changelog)

        plugin = json.loads((ROOT / ".claude-plugin/plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(plugin["name"], "idc")
        self.assertIn("IDC workflow", plugin["description"])


if __name__ == "__main__":
    unittest.main()
