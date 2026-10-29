"""Independent client acceptance/IPC controls; no finite-element solve here."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from jfem_client import JFEMWorker, resolve_sysimage
from wingbox_sizing_demo import checked_design


class AcceptanceTests(unittest.TestCase):
    def response(self):
        return {"spectra": [{"eigenvalues": [2.0, 1.2, 1.5, 3.0]}],
            "minimum_positive_eigenvalue": 1.2,
            "property_energy": [{"pid": 5, "strain_energy": 8.0, "updateable": True},
                                {"pid": 2, "strain_energy": 8.0, "updateable": True},
                                {"pid": 9, "strain_energy": 20.0, "updateable": False}]}

    def test_order_independent_minimum_and_eligible_tie(self):
        minimum, chosen = checked_design(self.response(), 4)
        self.assertEqual((minimum, chosen["pid"]), (1.2, 2))

    def test_missing_and_partial_spectra_fail(self):
        for spectra in ([], [{"eigenvalues": []}], [{"eigenvalues": [2.0]}]):
            response = self.response()
            response["spectra"] = spectra
            with self.assertRaises(ValueError):
                checked_design(response, 4)

    def test_bad_roots_cannot_pass(self):
        for value in (float("nan"), float("inf"), 0, -1):
            response = self.response()
            response["spectra"][0]["eigenvalues"][0] = value
            with self.assertRaises(ValueError):
                checked_design(response, 4)

    def test_inconsistent_root_and_zero_energy_fail(self):
        response = self.response()
        response["minimum_positive_eigenvalue"] = 2
        with self.assertRaises(ValueError):
            checked_design(response, 4)
        response = self.response()
        for row in response["property_energy"]:
            row["strain_energy"] = 0
        with self.assertRaises(ValueError):
            checked_design(response, 4)

    def test_missing_image_fails_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                resolve_sysimage(directory, Path(directory) / "missing.dll")


class ProtocolTests(unittest.TestCase):
    def exercise(self, behavior):
        fixture = '''import json,sys,time
print(json.dumps({"status":"ready","pid":123,"worker_session_id":"fixture"}),flush=True)
for line in sys.stdin:
    request=json.loads(line)
    if request["command"]=="quit":
        print(json.dumps({"status":"stopping"}),flush=True);break
    BEHAVIOR
'''.replace("BEHAVIOR", behavior)
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "protocol_fixture.py"
            script.write_text(fixture, encoding="utf-8")
            actual_popen = subprocess.Popen
            def start(_command, **options):
                options["cwd"] = str(Path(__file__).resolve().parent)
                return actual_popen([sys.executable, "-u", str(script)], **options)
            with patch("jfem_client.subprocess.Popen", side_effect=start):
                return JFEMWorker(repo_root=directory, request_timeout=.2)

    def test_mismatched_id_stops_owned_worker(self):
        worker = self.exercise('print(json.dumps({"id":999,"status":"ok"}),flush=True)')
        with self.assertRaisesRegex(RuntimeError, "ID"):
            worker.status()
        self.assertIsNotNone(worker.process.poll())
        worker.close()

    def test_timeout_stops_owned_worker(self):
        worker = self.exercise("time.sleep(5)")
        with self.assertRaises(TimeoutError):
            worker.status()
        self.assertIsNotNone(worker.process.poll())
        worker.close()

    def test_utf8_response_is_independent_of_windows_codepage(self):
        worker = self.exercise('sys.stdout.buffer.write((json.dumps({"id":request["id"],"status":"ok","value":"Wing \\u00e9"},ensure_ascii=False)+"\\n").encode("utf-8"));sys.stdout.buffer.flush()')
        try:
            self.assertEqual(worker.status()["value"], "Wing \u00e9")
        finally:
            worker.close()


if __name__ == "__main__":
    unittest.main()
