import json
import posixpath
import re

from codemap.graphs import closure
from codemap.model import entity, flag, worst
from codemap.repo import line_count

HOOK_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
               "Notification", "SubagentStart", "SubagentStop", "Stop", "PreCompact", "SessionEnd"]
CODE_KINDS = {"measured", "estimated", "not measured", "unavailable"}
LIBRARY_KINDS = ("agent", "skill", "command")


def detect_roots(paths):
    candidates = {""} | {p[:p.index(".claude/") + 8] for p in paths if ".claude/" in p}
    return sorted(r for r in candidates if is_setup_root(r, paths))


def is_setup_root(root, paths):
    for path in paths:
        rest = path[len(root):] if path.startswith(root) else None
        if rest is None:
            continue
        if re.fullmatch(r"agents/[^/]+\.md|skills/[^/]+/SKILL\.md|commands/[^/]+\.md", rest):
            return True
        if rest in ("settings.json", "settings.local.json") and '"hooks"' in paths[path]:
            return True
    return False


def frontmatter(text):
    if not text.startswith("---"):
        return {}
    block = text.split("---", 2)[1] if text.count("---") >= 2 else ""
    fields = {}
    for line in block.splitlines():
        m = re.match(r"([A-Za-z_-]+):\s*(.*)", line)
        if m:
            fields[m.group(1)] = m.group(2).strip().strip("'\"")
    return fields


def name_pattern(kind, name):
    n = re.escape(name)
    parts = [r"%ss/%s\b" % (kind, n)]
    if kind == "agent":
        parts += [r"`%s`" % n, r"\b%s\s+agents?\b" % n, r"\|\s*%s\s*\|" % n, r"(?i:\b%ss?\b)" % n]
    else:
        parts += [r"(?<![\w/.-])/%s(?![\w-])" % n, r"\b%s`?\s+%s\b" % (n, kind)]
        if re.search(r"[-_]", name):
            parts.append(r"(?<![\w/.-])%s(?![\w-]|\.\w)" % n)
    return re.compile("|".join(parts))


class SetupLens:
    def __init__(self, analysis, entities, root):
        self.a, self.entities, self.root = analysis, entities, root
        self.lens = "setup:" + root
        self.components = {}
        self.owner = {}
        self.problems = []
        self.workflow = None

    def path(self, rel):
        return self.root + rel

    def add(self, record, files):
        record["lens"] = self.lens
        self.entities[record["id"]] = record
        self.components[record["id"]] = files
        for f in files:
            self.owner[f] = record["id"]

    def build(self):
        self.discover()
        self.link_by_path()
        self.link_by_name()
        self.add_hooks()
        self.add_workflow()
        self.set_children()
        self.check_reachability()
        self.finish_root()
        return self.problems

    def discover(self):
        texts = self.a.texts
        for path in sorted(texts):
            if not path.startswith(self.root):
                continue
            rest = path[len(self.root):]
            m = re.fullmatch(r"(agents|commands)/([^/]+)\.md", rest) or re.fullmatch(r"(skills)/([^/]+)/SKILL\.md", rest)
            if m:
                self.add_component(m.group(1)[:-1], m.group(2), path)
        parent = posixpath.dirname(self.root.rstrip("/"))
        for candidate in sorted({self.path("CLAUDE.md"), self.path("AGENTS.md"), posixpath.join(parent, "CLAUDE.md") if self.root else "CLAUDE.md"}):
            if candidate in texts:
                record = entity("protocol:" + candidate, "protocol", posixpath.basename(candidate), path=candidate,
                                description="Loaded into every session — what it names is always in play")
                record["metrics"] = {"lines": line_count(texts[candidate])}
                self.add(record, [candidate])

    def add_component(self, kind, name, path):
        text = self.a.texts[path]
        fields = frontmatter(text)
        label = fields.get("name") or name
        files = [path]
        if kind == "skill":
            folder = posixpath.dirname(path) + "/"
            files = sorted(p for p in self.a.texts if p.startswith(folder))
        record = entity("%s:%s%s" % (kind, self.root, name), kind, label, path=path, description=fields.get("description", ""))
        record["metrics"] = {"lines": sum(line_count(self.a.texts[f]) for f in files)}
        if kind == "skill":
            record["metrics"]["files"] = len(files)
            record["meta"]["files"] = files
        if kind == "agent":
            tools = [t.strip() for t in fields.get("tools", "").split(",") if t.strip()]
            record["metrics"]["tools"] = len(tools)
            record["meta"].update({"model": fields.get("model", "(inherits)"), "tools": tools})
        self.add(record, files)

    def target_for(self, path):
        if path in self.owner:
            return self.owner[path]
        record = self.entities.get("file:" + path)
        if record and record["meta"].get("complexity") in CODE_KINDS:
            return record["id"]
        return None

    def connect(self, source, target, kind, where=None, label=None):
        record = self.entities[source]
        if target == source or any(e["to"] == target and e["kind"] == kind for e in record["out"]):
            return
        edge = {"to": target, "kind": kind}
        if where:
            edge["where"] = where
        if label:
            edge["label"] = label
        record["out"].append(edge)

    def link_by_path(self):
        for cid, files in self.components.items():
            for path in files:
                for target, (_, line) in self.a.links[path].items():
                    found = self.target_for(target)
                    if found:
                        self.connect(cid, found, "uses", "%s:%d" % (path, line))

    def name_sources(self):
        sources = [(cid, f) for cid, files in self.components.items() for f in files]
        scripts = {p for p in self.a.texts if p.startswith(self.path("scripts/"))}
        return sources + [("file:" + p, p) for p in sorted(scripts) if p not in self.owner]

    def link_by_name(self):
        targets = [(cid, name_pattern(self.entities[cid]["kind"], cid.split(":", 1)[1][len(self.root):]))
                   for cid in self.components if self.entities[cid]["kind"] in LIBRARY_KINDS]
        for source, path in self.name_sources():
            text = self.a.texts[path]
            for target, pattern in targets:
                m = pattern.search(text)
                if m and target != source:
                    self.connect(source, target, "uses", "%s:%d" % (path, text.count("\n", 0, m.start()) + 1))

    def settings(self):
        for name in ("settings.json", "settings.local.json"):
            path = self.path(name)
            if path in self.a.texts:
                try:
                    yield path, json.loads(self.a.texts[path]).get("hooks", {}) or {}
                except ValueError:
                    self.problems.append({"level": "error", "message": "%s is not valid JSON" % path})

    def add_hooks(self):
        events = {}
        for settings_path, hooks in self.settings():
            for event, groups in hooks.items():
                for i, group in enumerate(groups or []):
                    for j, hook in enumerate(group.get("hooks", [])):
                        events.setdefault(event, []).append(self.add_hook(settings_path, event, "%d.%d" % (i, j), group.get("matcher"), hook))
        if not events:
            return
        group = entity("group:%shooks" % self.root, "group", "Hooks (always on)", lens=self.lens,
                       description="Run by the harness on session events, whatever the workflow stage")
        order = sorted(events, key=lambda e: (HOOK_EVENTS.index(e) if e in HOOK_EVENTS else 99, e))
        for event in order:
            record = entity("event:%s%s" % (self.root, event), "hook-event", event, lens=self.lens, parent=group["id"], children=events[event])
            self.entities[record["id"]] = record
            group["children"].append(record["id"])
        self.entities[group["id"]] = group

    def add_hook(self, settings_path, event, slot, matcher, hook):
        command = hook.get("command", "")
        hid = "hook:%s%s#%s" % (self.root, event, slot)
        script = next((t for t in (self.a.index.mention(tok, settings_path) for tok in re.findall(r"[\w.~/@+-]+", command)) if t), None)
        label = posixpath.basename(script) if script else (command.split() or ["(empty)"])[0]
        if matcher and matcher != "*":
            label += " (%s)" % matcher
        record = entity(hid, "hook", label, lens=self.lens, parent="event:%s%s" % (self.root, event))
        record["meta"] = {"event": event, "matcher": matcher or "(every tool)", "command": command, "defined in": settings_path}
        if script:
            self.connect_new(record, "file:" + script, "runs", settings_path)
            record["children"] = ["file:" + script]
        else:
            flag(record, "unresolved", "its command isn't a file in this repo — the map can't follow it", "info")
        self.entities[hid] = record
        return hid

    def connect_new(self, record, target, kind, where):
        record["out"].append({"to": target, "kind": kind, "where": where})

    def resolve(self, ref):
        kind, _, value = ref.partition(":")
        if kind in LIBRARY_KINDS:
            cid = "%s:%s%s" % (kind, self.root, value)
            return cid if cid in self.entities else None
        if kind in ("script", "file"):
            path = self.a.index.mention(value, self.path("x"))
            return "file:" + path if path else None
        if kind == "hook":
            eid = "event:%s%s" % (self.root, value)
            return eid if eid in self.entities else None
        if kind == "protocol":
            path = self.path(value or "CLAUDE.md")
            return "protocol:" + path if "protocol:" + path in self.entities else None
        return None

    def load_workflow(self):
        path = self.path("workflow.json")
        if path not in self.a.texts:
            return None
        try:
            return json.loads(self.a.texts[path])
        except ValueError as error:
            self.problems.append({"level": "error", "message": "%s is not valid JSON: %s" % (path, error)})
            return None

    def add_workflow(self):
        self.workflow = self.load_workflow()
        if not self.workflow:
            return
        stage_ids = {s.get("id") for s in self.workflow.get("stages", [])}
        for stage in self.workflow.get("stages", []):
            self.add_stage(stage, stage_ids)
        group = entity("group:%son-demand" % self.root, "group", "On demand", lens=self.lens,
                       description="Loaded only when a task or a person calls for it")
        for ref in self.workflow.get("on_demand", []):
            target = self.resolve(ref)
            if target:
                group["children"].append(target)
            else:
                self.problems.append({"level": "error", "message": "on_demand names %s, which doesn't exist" % ref})
        self.entities[group["id"]] = group

    def add_stage(self, stage, stage_ids):
        sid = "stage:%s%s" % (self.root, stage.get("id"))
        record = entity(sid, "stage", stage.get("label") or stage.get("id"), lens=self.lens, description=stage.get("description", ""))
        for ref in stage.get("uses", []):
            target = self.resolve(ref)
            if target:
                record["out"].append({"to": target, "kind": "uses"})
                record["children"].append(target)
            else:
                flag(record, "dangling", "uses %s, which doesn't exist" % ref, "high")
                self.problems.append({"level": "error", "message": "stage %s uses %s, which doesn't exist" % (stage.get("id"), ref)})
        for step in stage.get("next", []):
            to, label = (step, None) if isinstance(step, str) else (step.get("to"), step.get("label"))
            if to not in stage_ids:
                self.problems.append({"level": "error", "message": "stage %s goes next to %s, which isn't a stage" % (stage.get("id"), to)})
                continue
            edge = {"to": "stage:%s%s" % (self.root, to), "kind": "next"}
            if label:
                edge["label"] = label
            record["out"].append(edge)
        if stage.get("when"):
            record["meta"]["when"] = stage["when"]
        self.entities[sid] = record

    def set_children(self):
        for cid in self.components:
            record = self.entities[cid]
            record["children"] = sorted({e["to"] for e in record["out"] if e["kind"] == "uses" and e["to"] in self.entities})

    def adjacency(self):
        return {eid: {e["to"] for e in r["out"] if e["kind"] in ("uses", "runs", "import", "reference")}
                for eid, r in self.entities.items() if r.get("lens") == self.lens or eid in self.components or eid.startswith("file:")}

    def reach_roots(self):
        mine = [r for r in self.entities.values() if r.get("lens") == self.lens]
        roots = {c for r in mine if r["kind"] == "stage" for c in r["children"]}
        roots |= {e["to"] for r in mine if r["kind"] == "hook" for e in r["out"]}
        roots |= {cid for cid in self.components if self.entities[cid]["kind"] == "protocol"}
        on_demand = self.entities.get("group:%son-demand" % self.root)
        return roots | set(on_demand["children"] if on_demand else [])

    def check_reachability(self):
        if not self.workflow:
            return
        roots = self.reach_roots()
        reached = roots | closure(roots, self.adjacency())
        for cid in sorted(c for c in self.components if c not in reached):
            self.flag_unreached_component(self.entities[cid])
        for path in sorted(p for p in self.a.texts if p.startswith(self.path("scripts/"))):
            record = self.entities.get("file:" + path)
            if record and record["id"] not in reached and record["meta"].get("complexity") in CODE_KINDS and record["metrics"]["lines"]:
                flag(record, "unreachable", "nothing in the workflow, hooks or protocol reaches this script (only tests, CI or docs may use it)", "medium")
                self.problems.append({"level": "warning", "message": "%s isn't reached from the workflow" % path})

    def flag_unreached_component(self, record):
        if record["kind"] not in LIBRARY_KINDS:
            return
        flag(record, "unreachable", "no stage, hook or protocol file reaches this %s, and workflow.json doesn't list it as on demand" % record["kind"], "high")
        self.problems.append({"level": "error", "message": "%s is unreachable — add it to a stage's uses or to on_demand in %s" % (record["id"], self.path("workflow.json"))})

    def root_children(self):
        if self.workflow:
            children = ["stage:%s%s" % (self.root, s.get("id")) for s in self.workflow.get("stages", [])]
        else:
            children = self.kind_groups()
        for extra in ("group:%shooks" % self.root, "group:%son-demand" % self.root):
            if extra in self.entities and self.entities[extra]["children"]:
                children.append(extra)
        return children + [c for c in self.components if self.entities[c]["kind"] == "protocol"]

    def finish_root(self):
        workflow = self.workflow or {}
        name = workflow.get("name") or ("Setup (%s)" % self.root.rstrip("/") if self.root else "Setup")
        description = workflow.get("description") or ("" if self.workflow else "No workflow.json here, so components are grouped by kind. Add one to see the stage flow.")
        root = entity(self.lens, "workflow", name, lens=self.lens, description=description, children=self.root_children())
        if self.workflow:
            root["meta"]["layout"] = "flow"
        self.assign_parents(root)
        self.entities[root["id"]] = root
        for record in self.entities.values():
            if record.get("lens") == self.lens:
                record["risk"] = worst([f["level"] for f in record["flags"]])
        root["metrics"] = self.root_metrics()

    def root_metrics(self):
        kinds = [self.entities[c]["kind"] for c in self.components]
        metrics = {kind + "s": kinds.count(kind) for kind in LIBRARY_KINDS}
        metrics["hooks"] = sum(1 for r in self.entities.values() if r["kind"] == "hook" and r.get("lens") == self.lens)
        metrics["problems"] = sum(1 for p in self.problems if p["level"] == "error")
        return metrics

    def kind_groups(self):
        ids = []
        for kind, label in (("agent", "Agents"), ("skill", "Skills"), ("command", "Commands")):
            members = sorted(c for c in self.components if self.entities[c]["kind"] == kind)
            if members:
                gid = "group:%s%ss" % (self.root, kind)
                self.entities[gid] = entity(gid, "group", label, lens=self.lens, children=members)
                ids.append(gid)
        return ids

    def assign_parents(self, root):
        queue = [root["id"]]
        seen = {root["id"]}
        while queue:
            current = queue.pop(0)
            record = root if current == root["id"] else self.entities[current]
            for child in record["children"]:
                target = self.entities.get(child)
                if target is None or child in seen or target.get("lens") != self.lens:
                    continue
                seen.add(child)
                target.setdefault("parent", current)
                queue.append(child)
        for cid in self.components:
            self.entities[cid].setdefault("parent", root["id"])
