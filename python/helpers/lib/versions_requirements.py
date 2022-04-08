import json
from packaging.requirements import Requirement, InvalidRequirement
from packaging.version import Version, InvalidVersion
import sys


def parse_version(version):
    try:
        ver = Version(version)
    except InvalidVersion as e:
        return json.dumps({"result": {"ok": False, "error": "Invalid version", "msg": str(e)}})
    return json.dumps({"result": {"ok": True, "version": ver}})


def parse_constraint(constraint):
    sys.stderr.write("I GOT" + constraint)
    try:
        # PEP508 says it should start with a name, though we don't use it, so make it dummy
        req = Requirement("dummy" + constraint)
    except InvalidRequirement as e:
        return json.dumps({"result": {"ok": False, "error": "Invalid requirement", "msg": str(e)}})
    return json.dumps({"result": {"ok": True, "constraint": str(req.specifier)}})


def contains(requirements, version):
    ver = Version(version)
    req = Requirement("dummy"+requirements)

    return json.dumps({"result": ver in req.specifier})
