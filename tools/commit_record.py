"""Commits the recorder's patch and deletes the one-shot files.

It uses the Git Data API so the tree is built from the checked-out commit and only
the recorded paths change: the two scripts and the workflow that runs them cannot
be re-run afterwards, because this commit removes them.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

TOKEN = os.environ["GITHUB_TOKEN"]
REPO = os.environ["GITHUB_REPOSITORY"]
MESSAGE = "Record the click milestone: a tempo clock, a click in the window, CI evidence"
WRITE = [
    "docs/progress.md",
    "README.md",
    "Sources/SundayKeysApp/AppModel.swift",
    "Sources/SundayKeysApp/ContentView.swift",
    "Sources/SundayKeysApp/ClickSection.swift",
]
DELETE = [
    ".github/workflows/record_click.yml",
    "tools/record_click.py",
    "tools/commit_record.py",
]


def stop(message):
    print("commit: " + message)
    print("::error title=record-commit::" + " ".join(message.split()))
    sys.exit(1)


def api(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request("https://api.github.com" + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + TOKEN)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            payload = response.read().decode()
    except urllib.error.HTTPError as error:
        stop("%s %s returned %s: %s" % (method, path, error.code, error.read().decode()[:200]))
    return json.loads(payload) if payload.strip() else {}


def git(*args):
    done = subprocess.run(["git"] + list(args), check=True, capture_output=True, text=True)
    return done.stdout.strip()


def blob(path):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    return api("POST", "/repos/%s/git/blobs" % REPO, {"content": text, "encoding": "utf-8"})["sha"]


head = git("rev-parse", "HEAD")
base = api("GET", "/repos/%s/git/commits/%s" % (REPO, head))
entries = [{"path": path, "mode": "100644", "type": "blob", "sha": blob(path)} for path in WRITE]
for path in DELETE:
    entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
tree = api("POST", "/repos/%s/git/trees" % REPO, {"base_tree": base["tree"]["sha"], "tree": entries})
commit = api(
    "POST",
    "/repos/%s/git/commits" % REPO,
    {"message": MESSAGE, "tree": tree["sha"], "parents": [head]},
)
api("PATCH", "/repos/%s/git/refs/heads/main" % REPO, {"sha": commit["sha"], "force": False})
print("commit: %s on %s" % (commit["sha"], head[:8]))
