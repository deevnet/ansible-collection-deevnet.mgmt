#!/usr/bin/env python3
"""Discovery report: what is running, against the Software Catalog and the pins.

playbooks/discover.yml collects raw, read-only output from every substrate
system and hands it here as one JSON file. This script parses it, compares each
item with the Software Catalog's rows (deevnet-docs data/software_catalog.yaml)
and each running container with the image the automation declares, and writes
a dated report: Markdown to read, JSON for whatever reads it next.

    discovery-report.py --observed RAW.json --catalog CATALOG.yaml \
        --inventory INVENTORY_DIR --roles ROLES_DIR [--roles ...] \
        --markdown OUT.md --json OUT.json

Read-only. It never opens a vault file: pins are never secrets, and every file
whose name starts with "vault" is skipped, unread.
"""
import argparse
import datetime
import json
import os
import re
import sys

import yaml

# --- Catalog ------------------------------------------------------------------

MD_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
NOT_RECORDED = re.compile(r"^(not recorded|not pinned)\b", re.I)


def plain(cell):
    """A catalog cell as text: links to their text, no bold or code marks."""
    s = MD_LINK.sub(r"\1", str(cell or ""))
    return s.replace("**", "").replace("`", "").strip()


def item_name(cell):
    """A row's name as collectors use it: before the first ' (' or ','."""
    s = plain(cell)
    for sep in (" (", ","):
        if sep in s:
            s = s.split(sep, 1)[0]
    return s.strip()


def token(version):
    """The first token of a version string, for comparing."""
    s = plain(version)
    if not s:
        return ""
    t = re.split(r"[\s,;]+", s.lstrip("\"'"), maxsplit=1)[0].rstrip(".\"'")
    return t[1:] if re.match(r"^v\d", t) else t


def same_version(observed, cataloged):
    """Equal, or one is the other with more after a boundary: 7.0.14 and 7.0.14-1-pve."""
    a, b = token(observed).lower(), token(cataloged).lower()
    if not a or not b:
        return False
    if a == b:
        return True
    short, long_ = sorted((a, b), key=len)
    return long_.startswith(short) and not long_[len(short)].isalnum()


def load_catalog(path):
    """{table: {"has_version": bool, "rows": {name: version cell}}}."""
    data = yaml.safe_load(open(path, encoding="utf-8"))
    out = {}
    for tid, table in data["tables"].items():
        cols = [c["key"] for c in table["columns"]]
        key = cols[0]
        rows = {}
        for r in table["rows"]:
            rows.setdefault(item_name(r.get(key)), r.get("version"))
        out[tid] = {"has_version": "version" in cols, "rows": rows}
    return out


# --- Pins: role defaults and inventory, never the vault -----------------------

REF = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
IMAGE = re.compile(r"^[\w.\-]+(:\d+)?/[\w./\-]+:[\w.\-]+$")


def yaml_files(path):
    """A vars file, or every .yml in a vars directory, never a vault file."""
    if os.path.isfile(path):
        files = [path]
    elif os.path.isdir(path):
        files = sorted(os.path.join(path, f) for f in os.listdir(path)
                       if f.endswith((".yml", ".yaml")))
    else:
        return []
    return [f for f in files if not os.path.basename(f).startswith("vault")]


def read_vars(path):
    out = {}
    for f in yaml_files(path):
        d = yaml.safe_load(open(f, encoding="utf-8")) or {}
        if isinstance(d, dict):
            out.update(d)
    return out


def host_groups(hosts_yml):
    """{host: [group, ...]} from an inventory hosts.yml, parents included."""
    inv = yaml.safe_load(open(hosts_yml, encoding="utf-8"))
    groups = {}

    def walk(name, node, parents):
        node = node or {}
        chain = parents + [name]
        for h in (node.get("hosts") or {}):
            groups.setdefault(h, [])
            for g in chain:
                if g not in groups[h]:
                    groups[h].append(g)
        for child, sub in (node.get("children") or {}).items():
            walk(child, sub, chain)

    walk("all", inv.get("all"), [])
    return groups


def resolve(value, scope, depth=0):
    """Fill in plain {{ name }} references; anything more is left as it is."""
    if not isinstance(value, str) or depth > 8:
        return value
    def sub(m):
        v = scope.get(m.group(1))
        return str(resolve(v, scope, depth + 1)) if isinstance(v, (str, int, float)) else m.group(0)
    return REF.sub(sub, value)


def pins_for(host, groups, inventory, defaults):
    """{image repository: {pinned refs}} the automation declares for this host."""
    scope = dict(defaults)
    for g in groups.get(host, ["all"]):
        scope.update(read_vars(os.path.join(inventory, "group_vars", g)))
        scope.update(read_vars(os.path.join(inventory, "group_vars", g + ".yml")))
    scope.update(read_vars(os.path.join(inventory, "host_vars", host)))
    scope.update(read_vars(os.path.join(inventory, "host_vars", host + ".yml")))
    refs = set()
    for k, v in scope.items():
        if k.endswith("_image"):
            refs.add(resolve(v, scope))
        elif k.endswith("_image_name"):
            tag = scope.get(k[: -len("_name")] + "_tag")
            if tag is not None:
                refs.add(f"{resolve(v, scope)}:{resolve(tag, scope)}")
    pins = {}
    for r in refs:
        if isinstance(r, str) and IMAGE.match(r):
            repo, tag = r.rsplit(":", 1)
            pins.setdefault(repo, set()).add(tag)
    return pins


# --- Parsers: raw collector output into (catalog item, version, detail) -------

def sections(text):
    """Collector output split on its '### name' marker lines."""
    out, cur = {}, None
    for line in (text or "").splitlines():
        if line.startswith("### "):
            cur = line[4:].strip()
            out[cur] = []
        elif cur:
            out[cur].append(line)
    return {k: "\n".join(v).strip() for k, v in out.items()}


def kv_lines(text, sep="="):
    out = {}
    for line in (text or "").splitlines():
        if sep in line:
            k, v = line.split(sep, 1)
            out[k.strip()] = v.strip()
    return out


def installed(entry):
    v = entry.get("installed", "1")
    return str(v).lower() in ("1", "true", "yes")


def parse_router(o):
    """core/firmware/info: the product, then the packages and plugins installed.

    Its fields are not documented, so each one is looked for, never assumed."""
    info = o.get("info") or {}
    items = []
    product = info.get("product") or {}
    ver = product.get("product_version") or product.get("CORE_VERSION") or ""
    items.append(("core-router", "OPNsense", ver, product.get("product_name", "")))
    pkgs = {p.get("name"): p for p in (info.get("package") or []) if isinstance(p, dict) and installed(p)}
    # The "base" package is OPNsense's own base set, versioned like OPNsense. The
    # FreeBSD release it is built on shows only in the package mirror's ABI,
    # e.g. https://pkg.opnsense.org/FreeBSD:15:amd64/26.7.
    m = re.search(r"FreeBSD:(\d+):", str(product.get("product_mirror", "")))
    if m:
        base = pkgs.get("base", {}).get("version", "")
        items.append(("core-router", "FreeBSD base", m.group(1),
                      f"base set {base}" if base else ""))
    for name, label in (("kea", "Kea DHCPv4"), ("unbound", "Unbound")):
        if name in pkgs:
            items.append(("core-router-services", label, pkgs[name].get("version", ""), ""))
    plugins = [p for p in (info.get("plugin") or []) if isinstance(p, dict) and installed(p)]
    plugins += [p for n, p in pkgs.items() if str(n).startswith("os-")]
    seen = set()
    for p in plugins:
        n = p.get("name", "")
        if n.startswith("os-") and n not in seen:
            seen.add(n)
            items.append(("core-router-plugins", n, p.get("version", ""), ""))
    return items


def parse_hypervisor(o, table):
    pve = kv_lines(o.get("pveversion"), ":")
    items = []
    mgr = pve.get("pve-manager", "")
    if mgr:
        items.append((table, "Proxmox VE", mgr.split()[0].split("/")[0], ""))
    if o.get("debian"):
        items.append((table, "Debian", o["debian"].strip(), ""))
    if o.get("kernel"):
        items.append((table, "Linux kernel", o["kernel"].strip(), ""))
    if o.get("bios"):
        items.append((table, "Dell BIOS", o["bios"].strip(), ""))
    if table == "tenant-hypervisor":
        sdn = pve.get("libpve-network-perl", "")
        if sdn:
            items.append((table, "Proxmox SDN", sdn.split()[0], ""))
        if o.get("frr"):
            items.append((table, "FRR", o["frr"].strip(), ""))
    return items


def parse_linux(o, table, os_item, image_items):
    """A Fedora or Raspberry Pi host: its OS, Podman and running containers."""
    k = kv_lines(o.get("facts"))
    items = []
    detail = ", ".join(x for x in (
        f"kernel {k['kernel']}" if k.get("kernel") else "",
        k.get("systemd", ""),
    ) if x)
    if k.get("rpi_issue"):
        name, version = "Raspberry Pi OS Lite", (k.get("os_codename") or "").capitalize()
        detail = "; ".join(x for x in (k["rpi_issue"], detail) if x)
    else:
        name, version = os_item or k.get("os_name", "OS"), k.get("os_version", "")
    items.append((table, name, version, detail))
    if k.get("bios") and os_item == "Fedora Workstation":
        items.append((table, "AOOSTAR BIOS", k["bios"], ""))
    if k.get("podman"):
        items.append((table, "Podman", k["podman"].split()[-1], ""))
    containers = []
    try:
        containers = json.loads(o.get("containers") or "[]") or []
    except ValueError:
        pass
    for c in containers:
        image = c.get("Image", "")
        names = c.get("Names") or []
        cname = names[0] if isinstance(names, list) and names else str(names)
        repo, _, tag = image.rpartition(":")
        if not repo or "/" in tag:
            repo, tag = image, ""
        base = repo.rsplit("/", 1)[-1]
        name = image_items.get(base, base)
        items.append((table, name, tag, f"container {cname}", repo))
    return items


def parse_switch(o):
    k = kv_lines(o.get("system_info"), "-")
    fw = k.get("Firmware Version", "")
    model = k.get("Hardware Version", "")
    return [("network-edge", "TP-Link SG2218 firmware", fw, model)] if fw else []


def parse_omada(o, models):
    items = []
    ver = (o.get("controller") or {}).get("controllerVer")
    if ver:
        items.append(("network-edge", "Omada Software Controller", ver, "controller API"))
    for d in o.get("devices") or []:
        model = d.get("model", "")
        name = next((v for m, v in models.items() if m in model), f"{model} firmware")
        fw = d.get("firmwareVersion") or d.get("version") or ""
        items.append(("network-edge", name, fw, f"{d.get('name', '')} ({model})"))
    return items


# --- Report -------------------------------------------------------------------

def compare(items, catalog, pins):
    rows = []
    for it in items:
        table, name, version, detail = it[:4]
        repo = it[4] if len(it) > 4 else None
        t = catalog.get(table)
        cat = None
        if t is None:
            status = "no such catalog table"
        elif name not in t["rows"]:
            status = "not in catalog"
        elif not t["has_version"]:
            status = "catalog has no version column"
        else:
            cat = t["rows"][name]
            if not cat or NOT_RECORDED.match(plain(cat)):
                status = "not recorded in catalog"
            elif not version:
                status = "not read"
            elif same_version(version, cat):
                status = "match"
            else:
                status = "MISMATCH"
        pin, pin_status = "", ""
        if repo is not None:
            tags = sorted(pins.get(repo, set()))
            pin = ", ".join(tags)
            if not tags:
                pin_status = "no pin"
            elif version in tags:
                pin_status = "pinned"
            else:
                pin_status = "DRIFT"
        rows.append({
            "table": table, "item": name, "observed": version, "detail": detail,
            "catalog": plain(cat) if cat else "", "status": status,
            "image": repo or "", "pin": pin, "pin_status": pin_status,
        })
    return rows


def esc(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--observed", required=True)
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--inventory", required=True)
    ap.add_argument("--roles", action="append", default=[])
    ap.add_argument("--markdown", required=True)
    ap.add_argument("--json", required=True)
    a = ap.parse_args()

    raw = json.load(open(a.observed, encoding="utf-8"))
    catalog = load_catalog(a.catalog)
    groups = host_groups(os.path.join(a.inventory, "hosts.yml"))
    defaults = {}
    for roles in a.roles:
        for role in sorted(os.listdir(roles)):
            defaults.update(read_vars(os.path.join(roles, role, "defaults", "main.yml")))
    image_items = raw.get("image_items", {})
    models = raw.get("omada_models", {})

    hosts, unreachable = {}, {}
    for host, h in sorted(raw["hosts"].items()):
        if h.get("status") != "ok":
            unreachable[host] = h.get("status") or "no answer"
            continue
        kind, table = h["kind"], h.get("table", "")
        o = sections(h["stdout"]) if "stdout" in h else h.get("outputs", {})
        if kind == "router":
            items = parse_router(o)
        elif kind == "hypervisor":
            items = parse_hypervisor(o, table)
        elif kind == "linux":
            items = parse_linux(o, table, h.get("os_item"), image_items)
        elif kind == "switch":
            items = parse_switch(o)
        elif kind == "omada":
            items = parse_omada(o, models)
        else:
            items = []
        hosts[host] = compare(items, catalog, pins_for(host, groups, a.inventory, defaults))

    # Catalog rows with a version that nothing reported, in the tables this run read
    seen = {(r["table"], r["item"]) for rows in hosts.values() for r in rows}
    read_tables = {r["table"] for rows in hosts.values() for r in rows}
    unobserved = [(t, n, plain(v)) for t in sorted(read_tables) if catalog.get(t, {}).get("has_version")
                  for n, v in catalog[t]["rows"].items()
                  if (t, n) not in seen and "Fedora package" not in plain(v)]

    date = raw.get("date") or datetime.date.today().isoformat()
    findings = [(h, r) for h, rows in hosts.items() for r in rows
                if r["status"] in ("MISMATCH", "not recorded in catalog", "not in catalog", "not read")
                or r["pin_status"] in ("DRIFT",)]
    counts = {}
    for rows in hosts.values():
        for r in rows:
            counts[r["status"]] = counts.get(r["status"], 0) + 1
    drift = sum(1 for rows in hosts.values() for r in rows if r["pin_status"] == "DRIFT")

    report = {"date": date, "counts": counts, "pin_drift": drift, "unreachable": unreachable,
              "hosts": hosts, "unobserved_catalog_rows": [
                  {"table": t, "item": n, "catalog": v} for t, n, v in unobserved]}
    with open(a.json, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, sort_keys=True)

    order = {"MISMATCH": 0, "not read": 1, "not recorded in catalog": 2, "not in catalog": 3}
    md = [f"# Discovery report {date}", ""]
    md.append(f"Read {len(hosts)} systems; {len(unreachable)} did not answer. "
              + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())) + f"; {drift} pin drift.")
    md += ["", "## Findings", ""]
    if findings:
        md += ["| Host | Table | Item | Observed | Catalog | Pin | Status |", "|---|---|---|---|---|---|---|"]
        for h, r in sorted(findings, key=lambda x: (order.get(x[1]["status"], 9), x[0], x[1]["item"])):
            st = r["status"] + (" / pin " + r["pin_status"] if r["pin_status"] == "DRIFT" else "")
            md.append(f"| {h} | {r['table']} | {esc(r['item'])} | {esc(r['observed'])} | "
                      f"{esc(r['catalog'])} | {esc(r['pin'])} | {st} |")
    else:
        md.append("None: every item read matches the catalog and its pin.")
    md += ["", "## Did not answer", ""]
    md += [f"- {h}: {s}" for h, s in sorted(unreachable.items())] or ["Every system answered."]
    md += ["", "## Catalog rows nothing reported", ""]
    md += [f"- {t}: {esc(n)} ({esc(v)})" for t, n, v in unobserved] or ["None."]
    md += ["", "## Everything read", ""]
    for h, rows in hosts.items():
        md += [f"### {h}", "", "| Item | Observed | Catalog | Pin | Status | Detail |",
               "|---|---|---|---|---|---|"]
        for r in rows:
            st = r["status"] + (f"; pin {r['pin_status']}" if r["pin_status"] else "")
            md.append(f"| {esc(r['item'])} | {esc(r['observed'])} | {esc(r['catalog'])} | "
                      f"{esc(r['pin'])} | {st} | {esc(r['detail'])} |")
        md.append("")
    with open(a.markdown, "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")
    print(a.markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
