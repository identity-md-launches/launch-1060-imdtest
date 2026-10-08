#!/usr/bin/env python3
"""Offline regression checks for this assignment's manifest, ABI and vendored inputs.

Run after forge build. This is a local check, not the platform's admission validator.
Uses only the Python 3.11+ standard library; never accesses the network.
"""

import hashlib
import json
import math
from pathlib import Path
import tomllib


ROOT = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise SystemExit(message)


def main():
    manifest = json.loads((ROOT / "launch.json").read_text())
    check(
        set(manifest) == {"kind", "token", "contracts", "pool", "economics", "notes"},
        "Unexpected manifest root fields (chainId must not be present)",
    )
    check(manifest["kind"] == "custom_token", "Wrong launch kind")
    check(isinstance(manifest["notes"], str), "Notes must be text")
    check(manifest["contracts"] == [], "Only the token is deployed by this project")
    check(manifest["token"] == {
        "contract": "IMDTToken",
        "name": "IMDTEST",
        "symbol": "IMDT",
        "decimals": 18,
        "constructorArgs": [],
        "totalSupply": "1000000000000000000000000000",
    }, "Token manifest differs from the assignment")
    check(manifest["pool"] == {
        "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
        "fee": 3000,
        "tickSpacing": 60,
        "initialPrice": "125270724187523965593206900",
    }, "Pool manifest differs from the mandatory parameters")
    check(manifest["economics"] == {
        "poolBps": 9000,
        "initialMarketCapWei": "2500000000000000000000",
        "remainderTo": "0x000000000000000000000000000000000000dead",
    }, "Economics must be copied exactly")
    supply = int(manifest["token"]["totalSupply"])
    cap = int(manifest["economics"]["initialMarketCapWei"])
    check(
        math.isqrt((cap << 192) // supply) == int(manifest["pool"]["initialPrice"]),
        "Provenance price does not match economics for IMDT as currency0",
    )

    config = tomllib.loads((ROOT / "foundry.toml").read_text())["profile"]["default"]
    for key, expected in {
        "solc": "0.8.26", "evm_version": "cancun", "optimizer": True,
        "optimizer_runs": 200, "via_ir": True, "bytecode_hash": "none",
        "ffi": False, "fs_permissions": [],
    }.items():
        check(config.get(key) == expected, f"Unexpected Foundry setting: {key}")

    artifact = json.loads((ROOT / "out/IMDTToken.sol/IMDTToken.json").read_text())
    abi = artifact["abi"]
    functions = {
        item["name"] + "(" + ",".join(p["type"] for p in item["inputs"]) + ")"
        for item in abi if item["type"] == "function"
    }
    check(functions == {
        "name()", "symbol()", "decimals()", "totalSupply()", "balanceOf(address)",
        "transfer(address,uint256)", "approve(address,uint256)",
        "allowance(address,address)", "transferFrom(address,address,uint256)",
    }, "Token ABI must contain exactly the standard ERC-20 functions")
    check(not any(i["type"] in {"fallback", "receive"} for i in abi), "Unexpected fallback")
    constructors = [i for i in abi if i["type"] == "constructor"]
    check(len(constructors) == 1 and constructors[0]["inputs"] == [], "Unexpected constructor arguments")
    check(not artifact["bytecode"].get("linkReferences"), "Unresolved deployment libraries")

    dependencies = json.loads((ROOT / "lib/dependencies.json").read_text())
    for library, provenance in dependencies.items():
        for filename, expected in provenance["files"].items():
            actual = hashlib.sha256((ROOT / "lib" / library / filename).read_bytes()).hexdigest()
            check(actual == expected, f"Vendored source changed: {library}/{filename}")
    print("Launch parameters, compiler configuration, ERC-20 ABI and dependency hashes verified.")


if __name__ == "__main__":
    main()
