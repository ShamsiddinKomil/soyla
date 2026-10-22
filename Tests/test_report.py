import csv
import io
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "report.py")
SAMPLE = os.path.join(HERE, "sample_runs.jsonl")


def run(*args):
    p = subprocess.run([sys.executable, "-I", SCRIPT, "--file", SAMPLE, *args], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return p.stdout, p.stderr


class ReportTests(unittest.TestCase):
    def test_table_groups(self):
        out, err = run()
        self.assertIn("skipped 1 malformed", err)
        data = [l for l in out.splitlines() if l.startswith("fake/")]
        self.assertEqual(len(data), 16)  # 2 models x 2 formats x 2 cleanup x 2 sources
        # the errored replay row is counted, excluded from latency
        row = [l.split() for l in data if l.split()[:4] == ["fake/model-a", "wav", "on", "replay"]][0]
        self.assertEqual(row[-1], "1")
        self.assertEqual(row[5:7], ["-", "-"])

    def test_source_filter(self):
        out, _ = run("--source", "live")
        self.assertNotIn(" replay ", out)

    def test_since(self):
        out, _ = run("--since", "2026-10-16")
        self.assertEqual(len([l for l in out.splitlines() if l.startswith("fake/")]), 1)

    def test_phrase_2(self):
        out, _ = run("--phrase", "2")
        ids = [l.split()[0] for l in out.splitlines() if l.startswith("2026-")]
        self.assertEqual(ids, ["2026-10-15T10-00-01-000", "2026-10-15T10-00-06-000", "2026-10-15T10-00-30-000",
                               "2026-10-15T10-00-11-000", "2026-10-15T10-00-16-000"])
        self.assertIn("clean: Fake phrase 2 clean.", out)

    def test_csv_header(self):
        out, _ = run("--csv")
        rows = list(csv.reader(io.StringIO(out)))
        self.assertEqual(rows[0][:9], ["run_id", "ts", "source", "phrase_id", "model", "format", "cleanup",
                                       "duration_sec", "bytes"])
        for k in ("stt_total", "release_to_paste", "net_ttfb", "net_reused", "cost", "error", "raw_text", "clean_text"):
            self.assertIn(k, rows[0])
        self.assertEqual(len(rows), 1 + 19)


class EngineTests(unittest.TestCase):
    """FE-6: apple (on-device) vs cloud rows are grouped per engine, side by side."""

    def _rows(self):
        import json

        def row(i, model, meta, stt, err=None):
            return {"run_id": f"2026-10-16T11-00-0{i}-000", "ts": "2026-10-16T11:00:00.000Z", "source": "replay",
                    "model": model, "cleanup": False, "audio": {"format": "wav", "duration_sec": 4.0, "bytes": 10},
                    "timeline_ms": {"stt_total": stt, "stt_request": stt}, "provider_meta": meta, "error": err}
        rows = [row(1, "en-US", {"provider": "apple", "engine": "apple-analyzer"}, 100),
                row(2, "en-US", {"provider": "apple"}, 300),
                row(3, "en-US", {"provider": "apple"}, None, err="model-not-installed"),
                row(4, "fake/model-a", None, 900), row(5, "fake/model-a", {"x": "y"}, 1100)]
        return "\n".join(json.dumps(r) for r in rows) + "\n"

    def _run(self, *args):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "runs.jsonl")
            with open(f, "w") as fh:
                fh.write(self._rows())
            p = subprocess.run([sys.executable, "-I", SCRIPT, "--file", f, *args], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            return p.stdout

    def test_engine_column_and_groups(self):
        out = self._run()
        lines = out.splitlines()
        self.assertEqual(lines[0].split()[:2], ["engine", "model"])
        apple = [l.split() for l in lines if l.startswith("apple ")][0]
        cloud = [l.split() for l in lines if l.startswith("cloud ")][0]
        self.assertEqual(apple[1:5], ["en-US", "wav", "off", "replay"])
        self.assertEqual(cloud[1:5], ["fake/model-a", "wav", "off", "replay"])
        self.assertEqual(apple[5], "3")      # n
        self.assertEqual(apple[-1], "1")     # the failed run is counted, excluded from latency
        self.assertEqual(apple[8], "100")    # stt_p50 over the two good runs (nearest rank of 100, 300)
        self.assertEqual(apple[9], "300")    # stt_p90
        self.assertEqual(cloud[8], "900")
        self.assertEqual(cloud[9], "1100")
        self.assertLess(out.index("apple "), out.index("cloud "))

    def test_csv_has_engine_last(self):
        rows = list(csv.reader(io.StringIO(self._run("--csv"))))
        self.assertEqual(rows[0][-1], "engine")
        self.assertEqual([r[-1] for r in rows[1:]], ["apple", "apple", "apple", "cloud", "cloud"])

    def test_all_cloud_log_has_no_engine_column(self):
        out, _ = run()
        self.assertNotIn("engine", out.splitlines()[0])


class HomeTests(unittest.TestCase):
    """--home / SOYLA_HOME resolution (A2): App Support is flat, a repo home keeps logs/runs.jsonl."""

    def _report(self, args, env):
        p = subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def test_home_flag_and_env(self):
        import shutil, tempfile
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "repo", "logs"))
            shutil.copy(SAMPLE, os.path.join(d, "repo", "logs", "runs.jsonl"))
            base = {"PATH": os.environ.get("PATH", ""), "HOME": d}
            out = self._report(["--home", os.path.join(d, "repo")], base)
            self.assertIn("fake/model-a", out)
            out = self._report([], dict(base, SOYLA_HOME=os.path.join(d, "repo")))
            self.assertIn("fake/model-a", out)
            # no SOYLA_HOME: App Support under the (fake) HOME; flat runs.jsonl
            app = os.path.join(d, "Library", "Application Support", "Soyla")
            self.assertEqual(self._report([], base).strip(), "no runs")
            os.makedirs(app)
            shutil.copy(SAMPLE, os.path.join(app, "runs.jsonl"))
            self.assertIn("fake/model-a", self._report([], base))


if __name__ == "__main__":
    unittest.main()
