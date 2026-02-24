#!/usr/bin/env python3

import csv
import json
import sys


data = {}
for row in csv.reader(sys.stdin, delimiter=' '):
    package = row[2]
    ocp_version = row[1]
    if ocp_version not in data:
        data[ocp_version] = []
    data[ocp_version].append(package)
json.dump(data, sys.stdout, indent=2)
sys.stdout.write('\n')
