#!/usr/bin/env python3
"""Packs a single-file extension as a shared extension file (.piext), for UI tests that open it with -openSharedFile.

    tools/DemoTour/Fixtures/make-piext.py permtest.ts OUT.piext
"""
import base64
import json
import os
import sys

source, out = sys.argv[1], sys.argv[2]
name = os.path.splitext(os.path.basename(source))[0]
with open(source, "rb") as file:
    data = base64.b64encode(file.read()).decode()
shared = {"pi": "extension", "format": 1, "name": name, "files": {os.path.basename(source): data},
          "entries": [os.path.basename(source)], "skills": [], "tools": [], "apps": []}
with open(out, "w") as file:
    json.dump(shared, file)
