"""Exercise deployment orchestration against overlapping GitHub workflow runs."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_SHA = "a" * 40

GH_STUB = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
state = Path(os.environ["MOCK_STATE"])
with (state / "calls.jsonl").open("a") as f:
    f.write(json.dumps(args) + "\n")

def option(name):
    return args[args.index(name) + 1]

if args[:2] == ["workflow", "run"]:
    (state / "request").write_text(option("-f").split("=", 1)[1])
elif args[:2] == ["run", "list"]:
    if option("--workflow") == "build.yml":
        request = (state / "request").read_text()
        rows = [
            {"databaseId": 901, "displayTitle": "Build Images (someone-else)"},
            {"databaseId": 111, "displayTitle": f"Build Images ({request})"},
        ]
    else:
        sha = "a" * 40
        rows = [
            {"databaseId": 902, "displayTitle": f"Deploy {sha} (build 901)"},
            {"databaseId": 222, "displayTitle": f"Deploy {sha} (build 111)"},
        ]
    print(json.dumps(rows))
elif args[:2] == ["run", "watch"]:
    if os.environ.get("MOCK_FAILED_RUN") == args[2]:
        sys.exit(1)
elif args[:2] == ["run", "view"]:
    if option("--json") == "headSha":
        print("a" * 40)
    else:
        print("skipped" if os.environ.get("MOCK_SKIPPED_RUN") == args[2] else "success")
else:
    sys.exit("Unexpected gh invocation: " + repr(args))
'''


class DeploymentWorkflowTests(unittest.TestCase):
    def run_deployment(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            stub = state / "gh"
            stub.write_text(GH_STUB)
            stub.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{state}:{os.environ['PATH']}",
                "MOCK_STATE": str(state),
                "GITHUB_REPOSITORY": "example/project",
                "DEPLOYMENT_LIB": str(ROOT / "scripts/lib.sh"),
                **overrides,
            }
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$DEPLOYMENT_LIB"; run_workflow_and_wait build.yml; '
                    "wait_for_production_deployment",
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            calls = [json.loads(line) for line in (state / "calls.jsonl").read_text().splitlines()]
            return result, calls

    def test_follows_own_build_and_matching_deployment_without_redispatch(self):
        result, calls = self.run_deployment()
        self.assertEqual(result.returncode, 0, result.stderr)
        watched = [call[2] for call in calls if call[:2] == ["run", "watch"]]
        self.assertEqual(watched, ["111", "222"])
        dispatched = [call[2] for call in calls if call[:2] == ["workflow", "run"]]
        self.assertEqual(dispatched, ["build.yml"])
        deployment_query = next(
            call for call in calls if call[:2] == ["run", "list"] and "deploy.yml" in call
        )
        self.assertEqual(deployment_query[deployment_query.index("--commit") + 1], BUILD_SHA)

    def test_failed_or_skipped_build_never_proceeds_to_production(self):
        for option in ("MOCK_FAILED_RUN", "MOCK_SKIPPED_RUN"):
            with self.subTest(option=option):
                result, calls = self.run_deployment(**{option: "111"})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("deploy.yml" in call for call in calls))

    def test_failed_or_skipped_deployment_is_not_reported_as_success(self):
        for option in ("MOCK_FAILED_RUN", "MOCK_SKIPPED_RUN"):
            with self.subTest(option=option):
                result, _ = self.run_deployment(**{option: "222"})
                self.assertNotEqual(result.returncode, 0)
