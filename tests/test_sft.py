import importlib.util
import contextlib
import io
import shutil
import tempfile
from types import SimpleNamespace
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "sft", Path(__file__).resolve().parents[1] / "sft" / "sft.py"
)
sft = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sft)


class PaneTransferResultTests(unittest.TestCase):
    def run_transfer(self, result=True, error=None):
        with (
            patch.object(sft, "require"),
            patch.object(sft, "_pane_current_path", return_value="/source"),
            patch.object(sft, "_pane_meta", return_value={"path": "/destination"}),
            patch.object(sft, "_alt_screen_enter"),
            patch.object(sft, "_alt_screen_exit") as leave,
            patch.object(sft, "_fullpane_wait_for_files", side_effect=[["/source/file"], None]),
            patch.object(sft, "transfer_local_rsync", return_value=result, side_effect=error),
            patch.object(sft, "_fullpane_done") as done,
            patch.object(sft, "_fullpane_box") as message,
            patch.object(sft.time, "sleep"),
            patch("builtins.input", return_value=""),
        ):
            try:
                sft._run_pane_transfer("%1", to_pane="%1")
            finally:
                leave.assert_called_once()
                self.assertFalse(sft._FULLPANE)
            return done, message

    def test_success_shows_done(self):
        done, message = self.run_transfer()
        done.assert_called_once_with("file", "local:/destination")
        message.assert_not_called()

    def test_failure_does_not_show_done(self):
        done, message = self.run_transfer(result=False)
        done.assert_not_called()
        self.assertEqual(message.call_args.args[0], "✗ transfer failed")
        self.assertIn("local:/destination", message.call_args.args[1][1])

    def test_transfer_error_is_shown_and_cleanup_runs(self):
        done, message = self.run_transfer(error=OSError("connection lost"))
        done.assert_not_called()
        self.assertIn("connection lost", message.call_args.args[1])


class DiagnosticsTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("rsync"), "rsync required")
    def test_real_rsync_failure_retains_reason_and_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = str(Path(tmp) / "missing-file")
            sft._TRANSFER_ERRORS.clear()
            with patch.object(sft, "_FULLPANE", True), contextlib.redirect_stderr(io.StringIO()):
                self.assertFalse(sft.transfer_local_rsync(missing, tmp))
            details = "\n".join(sft._TRANSFER_ERRORS)
            self.assertIn("exit code", details)
            self.assertIn("No such file or directory", details)
            self.assertIn("missing-file", details)

    @unittest.skipUnless(shutil.which("rsync"), "rsync required")
    def test_real_local_copy_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "file with spaces"
            source.write_text("content")
            destination = Path(tmp) / "destination with spaces"
            destination.mkdir()
            with patch.object(sft, "draw_bar"), contextlib.redirect_stdout(io.StringIO()):
                self.assertTrue(sft.transfer_local_rsync(str(source), str(destination)))
            self.assertEqual((destination / source.name).read_text(), "content")

    def test_failure_waits_for_dismissal_and_keeps_details(self):
        sft._TRANSFER_ERRORS.clear()
        sft._TRANSFER_ERRORS.append("Permission denied")
        with patch.object(sft, "_fullpane_box") as box, patch("builtins.input", return_value="") as acknowledge:
            sft._fullpane_failed("file", "server:/target")
        acknowledge.assert_called_once()
        self.assertIn("Permission denied", box.call_args.args[1])

    def test_unterminated_subprocess_error_is_retained(self):
        process = SimpleNamespace(stdout=io.StringIO("ssh: connection refused"), returncode=255, wait=lambda: None)
        with patch.object(sft.subprocess, "Popen", return_value=process), patch.object(sft, "log_error") as error:
            self.assertFalse(sft._run_rsync(["rsync"], "file", 0))
        self.assertIn(unittest.mock.call("ssh: connection refused"), error.call_args_list)


class DestinationArgumentTests(unittest.TestCase):
    def test_destination_is_used_in_direct_and_interactive_modes(self):
        for args, exit_code in [
            (["server", "/source/file", "--dest", "/target dir"], 0),
            (["server", "--dest", "/target dir"], 0),
            (["--dest", "/target dir"], None),
        ]:
            with (
                self.subTest(args=args),
                patch.object(sft.sys, "argv", ["sft"] + args),
                patch.object(sft.sys, "stdin", io.StringIO()),
                patch.object(sft, "require"),
                patch.object(sft, "resolve_target_for_alias", return_value=SimpleNamespace(label="server")),
                patch.object(sft, "resolve_target", return_value=SimpleNamespace(label="server")),
                patch.object(sft, "cleanup"),
                patch.object(sft.os.path, "exists", return_value=True),
                patch.object(sft, "transfer_one", return_value=True) as transfer,
                patch("builtins.input", side_effect=["/source/file", "q"]),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                if exit_code is None:
                    sft.main()
                else:
                    with self.assertRaises(SystemExit) as exc:
                        sft.main()
                    self.assertEqual(exc.exception.code, exit_code)
                self.assertEqual(transfer.call_args.args[0], "/source/file")
                self.assertEqual(transfer.call_args.args[2], "/target dir")

    def test_failed_direct_transfer_exits_nonzero(self):
        with (
            patch.object(sft.sys, "argv", ["sft", "server", "/source/file", "-d", "/target"]),
            patch.object(sft.sys, "stdin", io.StringIO()),
            patch.object(sft, "require"),
            patch.object(sft, "resolve_target_for_alias"),
            patch.object(sft, "cleanup"),
            patch.object(sft.os.path, "exists", return_value=True),
            patch.object(sft, "transfer_one", return_value=False),
            self.assertRaises(SystemExit) as exc,
        ):
            sft.main()
        self.assertEqual(exc.exception.code, 1)

    def test_missing_destination_value_is_rejected(self):
        with patch.object(sft.sys, "argv", ["sft", "server", "--dest"]), patch.object(sft, "log_error"), self.assertRaises(SystemExit) as exc:
            sft.main()
        self.assertEqual(exc.exception.code, 1)

    def test_remote_destination_with_spaces_is_one_argument(self):
        target = SimpleNamespace(ssh="server", control_path="/socket")
        with patch.object(sft, "require"), patch.object(sft, "path_size", return_value=0), patch.object(sft, "_exists_remote", return_value=False), patch.object(sft, "_run_rsync", return_value=True) as run:
            self.assertTrue(sft.transfer_rsync("/source/file", target, "/target dir"))
        self.assertEqual(run.call_args.args[0][-1], "server:/target dir/file")
        self.assertIn("--protect-args", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
