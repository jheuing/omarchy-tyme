#!/usr/bin/env python3
"""Local state engine for the Tyme Omarchy plugin."""

import argparse
import csv
import datetime as dt
import json
import os
import re
import sys
import tempfile
import uuid

STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "omarchy", "client-timer")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
RANKS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ranks.csv")
COLORS = {"#e06c75", "#d19a66", "#e5c07b", "#98c379", "#56b6c2", "#61afef", "#c678dd"}
THEME_COLOR_NAMES = ("red", "orange", "yellow", "green", "cyan", "blue", "magenta", "brown")
THEME_COLORS_FILE = os.path.expanduser("~/.local/state/omarchy/current/theme/colors.toml")
HEX_COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")
TIME_OF_DAY = re.compile(r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
MAX_STATE_BYTES = 256 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_CLIENTS = 500
MAX_ENTRIES = 5000
MAX_NAME_LENGTH = 256
MAX_NOTE_LENGTH = 1024
MAX_ID_LENGTH = 64


class Error(Exception):
    pass


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def default_state():
    return {"version": 1, "settings": {"workdayHours": 8, "menuLabelStyle": "project"}, "clients": [], "active": None, "entries": []}


def require_object(value, label):
    if not isinstance(value, dict):
        raise Error(f"Timer state has an invalid {label}")
    return value


def require_list(value, label, maximum):
    if not isinstance(value, list) or len(value) > maximum:
        raise Error(f"Timer state has an invalid {label}")
    return value


def require_string(value, label, maximum):
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise Error(f"Timer state has an invalid {label}")
    return value


def require_timestamp(value, label):
    value = require_string(value, label, 64)
    try:
        dt.datetime.fromisoformat(value)
    except ValueError:
        raise Error(f"Timer state has an invalid {label}")
    return value


def validate_client(value):
    value = require_object(value, "client")
    color = require_string(value.get("color"), "client color", 32).lower()
    name = require_string(value.get("name"), "client name", MAX_NAME_LENGTH)
    if not valid_color(color):
        raise Error("Timer state has an invalid client color")
    if "<" in name:
        raise Error("Timer state has an invalid client name")
    return {
        "id": require_string(value.get("id"), "client id", MAX_ID_LENGTH),
        "name": name,
        "color": color,
        "createdAt": require_timestamp(value.get("createdAt"), "client creation time"),
    }


def validate_entry(value):
    value = require_object(value, "entry")
    seconds = value.get("seconds")
    if type(seconds) is not int or seconds < 0:
        raise Error("Timer state has an invalid entry duration")
    return {
        "id": require_string(value.get("id"), "entry id", MAX_ID_LENGTH),
        "clientId": require_string(value.get("clientId"), "entry client id", MAX_ID_LENGTH),
        "note": require_string(value.get("note", ""), "entry note", MAX_NOTE_LENGTH) if value.get("note", "") else "",
        "start": require_timestamp(value.get("start"), "entry start time"),
        "end": require_timestamp(value.get("end"), "entry end time"),
        "seconds": seconds,
    }


def validate_active(value):
    if value is None:
        return None
    value = require_object(value, "active timer")
    paused_seconds = value.get("pausedSeconds")
    if type(paused_seconds) is not int or paused_seconds < 0:
        raise Error("Timer state has an invalid paused duration")
    paused_at = value.get("pausedAt")
    if paused_at is not None:
        paused_at = require_timestamp(paused_at, "pause time")
    return {
        "id": require_string(value.get("id"), "active timer id", MAX_ID_LENGTH),
        "clientId": require_string(value.get("clientId"), "active timer client id", MAX_ID_LENGTH),
        "note": require_string(value.get("note", ""), "active timer note", MAX_NOTE_LENGTH) if value.get("note", "") else "",
        "start": require_timestamp(value.get("start"), "active timer start time"),
        "pausedAt": paused_at,
        "pausedSeconds": paused_seconds,
    }


def validate_state(value):
    value = require_object(value, "root object")
    settings = require_object(value.get("settings", {}), "settings")
    workday_hours = settings.get("workdayHours", 8)
    menu_label_style = settings.get("menuLabelStyle", "project")
    if type(workday_hours) is not int or not 1 <= workday_hours <= 10:
        raise Error("Timer state has an invalid workday target")
    if menu_label_style not in {"project", "theme", "plain"}:
        raise Error("Timer state has an invalid menu label style")
    clients = [validate_client(item) for item in require_list(value.get("clients", []), "clients", MAX_CLIENTS)]
    if len({item["id"] for item in clients}) != len(clients):
        raise Error("Timer state has duplicate client ids")
    entries = [validate_entry(item) for item in require_list(value.get("entries", []), "entries", MAX_ENTRIES)]
    active = validate_active(value.get("active"))
    return {
        "version": 1,
        "settings": {"workdayHours": workday_hours, "menuLabelStyle": menu_label_style},
        "clients": clients,
        "active": active,
        "entries": entries,
    }


def load():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            source = f.read(MAX_STATE_BYTES + 1)
    except FileNotFoundError:
        return default_state()
    except (OSError, UnicodeDecodeError) as error:
        raise Error(f"Could not read timer state: {getattr(error, 'strerror', None) or error}")
    if len(source.encode("utf-8")) > MAX_STATE_BYTES:
        raise Error("Timer state is too large")
    try:
        return validate_state(json.loads(source))
    except (json.JSONDecodeError, RecursionError):
        raise Error("Timer state is not valid JSON")


def save(state):
    serialized = json.dumps(state, indent=2) + "\n"
    if len(serialized.encode("utf-8")) > MAX_STATE_BYTES:
        raise Error("Timer state is too large")
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".tmp.", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(serialized)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, STATE_FILE)
    except BaseException:
        os.unlink(temp)
        raise


def theme_colors():
    colors = {"red": "#e06c75", "orange": "#d19a66", "yellow": "#e5c07b", "green": "#98c379",
              "cyan": "#56b6c2", "blue": "#61afef", "magenta": "#c678dd", "brown": "#8b6f47"}
    try:
        with open(THEME_COLORS_FILE, encoding="utf-8") as f:
            for line in f:
                match = re.match(r"\s*([a-z_]+)\s*=\s*\"(#[0-9a-fA-F]{6})\"", line)
                if match and match.group(1) in colors:
                    colors[match.group(1)] = match.group(2).lower()
    except FileNotFoundError:
        pass
    return colors


def resolve_color(color, palette):
    if color.startswith("theme:"):
        return palette.get(color[6:], palette["blue"])
    return color


def valid_color(color):
    return HEX_COLOR.fullmatch(color) or color in {"theme:" + name for name in THEME_COLOR_NAMES}


def client(state, client_id):
    for item in state["clients"]:
        if item["id"] == client_id:
            return item
    raise Error("Client not found")


def parse_hhmmss(text):
    parts = text.strip().split(":")
    if len(parts) != 3:
        raise ValueError(f"invalid time {text.strip()!r}")
    hours = int(parts[0])
    minutes = int(parts[1])
    seconds = int(parts[2])
    if hours < 0 or not 0 <= minutes < 60 or not 0 <= seconds < 60:
        raise ValueError(f"invalid time {text.strip()!r}")
    return hours * 3600 + minutes * 60 + seconds


_ranks_cache = None


def load_ranks():
    global _ranks_cache
    if _ranks_cache is not None:
        return _ranks_cache
    ranks = []
    try:
        with open(RANKS_FILE, encoding="utf-8") as f:
            rows = list(csv.reader(f))
        for row in rows[1:]:
            if len(row) < 5 or not row[0].strip():
                continue
            ranks.append({"name": row[0].strip(), "divisions": [parse_hhmmss(value) for value in row[1:5]]})
    except (OSError, ValueError):
        ranks = []
    _ranks_cache = ranks
    return ranks


def lifetime_seconds(state):
    total = sum(max(0, int(entry["seconds"])) for entry in state["entries"])
    active = state["active"]
    if active:
        end = dt.datetime.fromisoformat(active["pausedAt"] or now())
        start = dt.datetime.fromisoformat(active["start"])
        total += max(0, int((end - start).total_seconds()) - active["pausedSeconds"])
    return total


def determine_rank(total_seconds):
    steps = []
    for rank in load_ranks():
        for index, seconds in enumerate(rank["divisions"]):
            steps.append({"name": rank["name"], "division": index + 1, "seconds": seconds})
    if not steps:
        return None
    match_index = 0
    for index, step in enumerate(steps):
        if total_seconds >= step["seconds"]:
            match_index = index
    match = steps[match_index]
    result = {
        "totalSeconds": total_seconds,
        "name": match["name"],
        "division": match["division"],
        "tier": match["name"].split(" ")[0],
        "currentThreshold": match["seconds"],
        "nextName": None,
        "nextThreshold": None,
        "progress": None,
    }
    if match_index + 1 < len(steps):
        following = steps[match_index + 1]
        span = following["seconds"] - match["seconds"]
        result["nextName"] = following["name"]
        result["nextThreshold"] = following["seconds"]
        result["progress"] = min(1.0, (total_seconds - match["seconds"]) / span) if span > 0 else 1.0
    return result


def view(state):
    palette = theme_colors()
    clients = []
    for item in state["clients"]:
        visible = dict(item)
        visible["colorToken"] = item["color"]
        visible["color"] = resolve_color(item["color"], palette)
        clients.append(visible)
    return {"settings": state["settings"], "themeColors": palette, "clients": clients, "active": state["active"], "entries": state["entries"][:8]}


def cmd_init(_):
    state = load()
    save(state)
    return {"state": view(state)}


def cmd_state(_):
    return {"state": view(load())}


def cmd_rank(_):
    return {"rank": determine_rank(lifetime_seconds(load()))}


def cmd_client_add(args):
    state = load()
    name = args.name.strip()
    if not name:
        raise Error("Client name is required")
    if len(name) > MAX_NAME_LENGTH:
        raise Error(f"Client name must be at most {MAX_NAME_LENGTH} characters")
    if "<" in name:
        raise Error("Client name cannot contain '<'")
    if not valid_color(args.color):
        raise Error("Project color must be a theme color or #RRGGBB value")
    if any(item["name"].casefold() == name.casefold() for item in state["clients"]):
        raise Error("A client with that name already exists")
    state["clients"].append({"id": uuid.uuid4().hex, "name": name, "color": args.color.lower(), "createdAt": now()})
    save(state)
    return {"state": view(state)}


def cmd_client_update(args):
    state = load()
    name = args.name.strip()
    if not name:
        raise Error("Company name is required")
    if len(name) > MAX_NAME_LENGTH:
        raise Error(f"Company name must be at most {MAX_NAME_LENGTH} characters")
    if "<" in name:
        raise Error("Company name cannot contain '<'")
    if not valid_color(args.color):
        raise Error("Project color must be a theme color or #RRGGBB value")
    target = client(state, args.id)
    if any(item["id"] != target["id"] and item["name"].casefold() == name.casefold() for item in state["clients"]):
        raise Error("A company with that name already exists")
    target["name"] = name
    target["color"] = args.color.lower()
    save(state)
    return {"state": view(state)}


def cmd_workday_set(args):
    if args.hours < 1 or args.hours > 10:
        raise Error("Workday target must be between 1 and 10 hours")
    state = load()
    state["settings"]["workdayHours"] = args.hours
    save(state)
    return {"state": view(state)}


def cmd_menu_labels_set(args):
    state = load()
    state["settings"]["menuLabelStyle"] = args.style
    save(state)
    return {"state": view(state)}


def cmd_start(args):
    state = load()
    if state["active"]:
        raise Error("A timer is already running")
    client(state, args.client_id)
    note = args.note.strip()
    if len(note) > MAX_NOTE_LENGTH:
        raise Error(f"Note must be at most {MAX_NOTE_LENGTH} characters")
    state["active"] = {"id": uuid.uuid4().hex, "clientId": args.client_id, "note": note, "start": now(), "pausedAt": None, "pausedSeconds": 0}
    save(state)
    return {"state": view(state)}


def finish_active(state, end):
    active = state["active"]
    if not active:
        return
    stopped_at = dt.datetime.fromisoformat(active["pausedAt"] or end)
    started_at = dt.datetime.fromisoformat(active["start"])
    state["entries"].insert(0, {
        "id": active["id"], "clientId": active["clientId"], "note": active["note"],
        "start": active["start"], "end": stopped_at.isoformat(),
        "seconds": max(0, int((stopped_at - started_at).total_seconds()) - active["pausedSeconds"]),
    })
    state["active"] = None


def cmd_switch(args):
    state = load()
    client(state, args.client_id)
    note = args.note.strip()
    if len(note) > MAX_NOTE_LENGTH:
        raise Error(f"Note must be at most {MAX_NOTE_LENGTH} characters")
    started = now()
    finish_active(state, started)
    state["active"] = {
        "id": uuid.uuid4().hex, "clientId": args.client_id, "note": note,
        "start": started, "pausedAt": None, "pausedSeconds": 0,
    }
    save(state)
    return {"state": view(state)}


def cmd_pause(_):
    state = load()
    if not state["active"] or state["active"]["pausedAt"]:
        raise Error("No running timer to pause")
    state["active"]["pausedAt"] = now()
    save(state)
    return {"state": view(state)}


def cmd_resume(_):
    state = load()
    active = state["active"]
    if not active or not active["pausedAt"]:
        raise Error("No paused timer to resume")
    active["pausedSeconds"] += int((dt.datetime.fromisoformat(now()) - dt.datetime.fromisoformat(active["pausedAt"])).total_seconds())
    active["pausedAt"] = None
    save(state)
    return {"state": view(state)}


def cmd_stop(_):
    state = load()
    if not state["active"]:
        raise Error("No active timer")
    finish_active(state, now())
    save(state)
    return {"state": view(state)}


def cmd_adjust_active_start(args):
    state = load()
    active = state["active"]
    if not active:
        raise Error("No active timer")
    adjusted = dt.datetime.fromisoformat(active["start"]) + dt.timedelta(minutes=args.minutes)
    if adjusted > dt.datetime.fromisoformat(now()):
        raise Error("Start time cannot be in the future")
    active["start"] = adjusted.isoformat()
    save(state)
    return {"state": view(state)}


def cmd_export(args):
    state = load()
    names = {item["id"]: item["name"] for item in state["clients"]}
    entries = entries_for_range(state, args.from_date, args.to_date)
    path = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["Client", "Note", "Started", "Ended", "Duration (hours)"])
        for entry in entries:
            writer.writerow([names.get(entry["clientId"], "Deleted client"), entry["note"], entry["start"], entry["end"], f'{entry["seconds"] / 3600:.2f}'])
    rank_info = determine_rank(lifetime_seconds(state))
    if rank_info:
        with open(path, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow([])
            writer.writerow(["Rank Summary"])
            if rank_info["name"] == "Unranked":
                writer.writerow(["Rank", "Unranked"])
            else:
                writer.writerow(["Rank", f'{rank_info["name"]} · Div {rank_info["division"]}'])
            writer.writerow(["Lifetime Total", f"{rank_info['totalSeconds'] / 3600:.2f} hours"])
            if rank_info["nextName"]:
                remaining_hours = max(0.0, (rank_info["nextThreshold"] - rank_info["totalSeconds"]) / 3600)
                writer.writerow([
                    "Next Rank",
                    rank_info["nextName"],
                    f"at {rank_info['nextThreshold'] / 3600:.2f} hours",
                    f"{round((rank_info['progress'] or 0) * 100)}% there",
                    f"{remaining_hours:.2f} hours to go",
                ])
            else:
                writer.writerow(["Status", "Maximum rank reached"])
    return {"path": path, "count": len(entries), "seconds": sum(entry["seconds"] for entry in entries), "state": view(state)}


def entries_for_range(state, from_date, to_date):
    try:
        lower = dt.date.fromisoformat(from_date) if from_date else None
        upper = dt.date.fromisoformat(to_date) if to_date else None
    except ValueError:
        raise Error("Dates must be YYYY-MM-DD")
    if lower and upper and lower > upper:
        raise Error("Start date must be before end date")
    entries = []
    for entry in state["entries"]:
        entry_day = dt.datetime.fromisoformat(entry["start"]).astimezone().date()
        if (lower is None or entry_day >= lower) and (upper is None or entry_day <= upper):
            entries.append(entry)
    return entries


def cmd_summary(args):
    state = load()
    entries = entries_for_range(state, args.from_date, args.to_date)
    companies = {item["id"]: item for item in state["clients"]}
    palette = theme_colors()
    totals = {}
    for entry in entries:
        totals[entry["clientId"]] = totals.get(entry["clientId"], 0) + entry["seconds"]
    rows = [{
        "clientId": client_id,
        "name": companies.get(client_id, {}).get("name", "Deleted company"),
        "color": resolve_color(companies.get(client_id, {}).get("color", "#61afef"), palette),
        "seconds": seconds,
    } for client_id, seconds in totals.items()]
    rows.sort(key=lambda row: row["seconds"], reverse=True)
    return {"summary": {"count": len(entries), "seconds": sum(entry["seconds"] for entry in entries), "rows": rows}}


def cmd_today(_):
    state = load()
    today = dt.datetime.now().astimezone().date()
    totals = {}
    segments = []
    for entry in state["entries"]:
        started = dt.datetime.fromisoformat(entry["start"]).astimezone()
        if started.date() == today:
            seconds = max(0, int(entry["seconds"]))
            totals[entry["clientId"]] = totals.get(entry["clientId"], 0) + seconds
            segments.append({"clientId": entry["clientId"], "startSeconds": started.hour * 3600 + started.minute * 60 + started.second, "seconds": seconds})
    companies = {item["id"]: item for item in state["clients"]}
    palette = theme_colors()
    rows = [{
        "clientId": client_id,
        "name": companies.get(client_id, {}).get("name", "Deleted company"),
        "color": resolve_color(companies.get(client_id, {}).get("color", "#61afef"), palette),
        "seconds": seconds,
    } for client_id, seconds in totals.items()]
    rows.sort(key=lambda row: row["seconds"], reverse=True)
    for segment in segments:
        segment["color"] = resolve_color(companies.get(segment["clientId"], {}).get("color", "#61afef"), palette)
    return {"today": {"rows": rows, "segments": segments, "seconds": sum(totals.values())}}


def cmd_report(args):
    state = load()
    try:
        requested = dt.date.fromisoformat(args.week)
    except ValueError:
        raise Error("Week must be a YYYY-MM-DD date")

    week_start = requested - dt.timedelta(days=requested.weekday())
    week_end = week_start + dt.timedelta(days=6)
    month_key = f"{week_start.year:04d}-{week_start.month:02d}"
    day_seconds = {week_start + dt.timedelta(days=index): 0 for index in range(7)}
    day_companies = {day: {} for day in day_seconds}
    company_seconds = {}
    companies = {item["id"]: item for item in state["clients"]}
    palette = theme_colors()

    for entry in state["entries"]:
        entry_day = dt.datetime.fromisoformat(entry["start"]).astimezone().date()
        seconds = max(0, int(entry.get("seconds", 0)))
        if entry_day in day_seconds:
            day_seconds[entry_day] += seconds
            company_totals = day_companies[entry_day]
            company_totals[entry["clientId"]] = company_totals.get(entry["clientId"], 0) + seconds
        if f"{entry_day.year:04d}-{entry_day.month:02d}" == month_key:
            company_seconds[entry["clientId"]] = company_seconds.get(entry["clientId"], 0) + seconds

    rows = []
    for company_id, seconds in company_seconds.items():
        company = companies.get(company_id, {})
        rows.append({
            "clientId": company_id,
            "name": company.get("name", "Deleted company"),
            "color": resolve_color(company.get("color", "#61afef"), palette),
            "seconds": seconds,
        })
    rows.sort(key=lambda row: row["seconds"], reverse=True)

    return {"report": {
        "weekStart": week_start.isoformat(),
        "weekEnd": week_end.isoformat(),
        "weekNumber": week_start.isocalendar().week,
        "month": month_key,
        "days": [{
            "date": day.isoformat(),
            "seconds": day_seconds[day],
            "segments": [{
                "clientId": company_id,
                "color": resolve_color(companies.get(company_id, {}).get("color", "#61afef"), palette),
                "seconds": seconds,
            } for company_id, seconds in sorted(day_companies[day].items(), key=lambda item: item[1], reverse=True)],
        } for day in day_seconds],
        "monthRows": rows,
        "monthTotalSeconds": sum(company_seconds.values()),
        "rank": determine_rank(lifetime_seconds(state)),
    }}


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name, func in {"init": cmd_init, "state": cmd_state, "rank": cmd_rank, "pause": cmd_pause, "resume": cmd_resume, "stop": cmd_stop}.items():
        commands.add_parser(name).set_defaults(func=func)
    add = commands.add_parser("client-add")
    add.add_argument("--name", required=True)
    add.add_argument("--color", required=True)
    add.set_defaults(func=cmd_client_add)
    update = commands.add_parser("client-update")
    update.add_argument("--id", required=True)
    update.add_argument("--name", required=True)
    update.add_argument("--color", required=True)
    update.set_defaults(func=cmd_client_update)
    workday = commands.add_parser("workday-set")
    workday.add_argument("--hours", type=int, required=True)

    menu_labels = commands.add_parser("menu-labels-set")
    menu_labels.add_argument("--style", choices=["project", "theme", "plain"], required=True)
    workday.set_defaults(func=cmd_workday_set)
    menu_labels.set_defaults(func=cmd_menu_labels_set)
    adjust_start = commands.add_parser("adjust-active-start")
    adjust_start.add_argument("--minutes", type=int, choices=[-15, -5, 5, 15], required=True)
    adjust_start.set_defaults(func=cmd_adjust_active_start)
    start = commands.add_parser("start")
    start.add_argument("--client-id", required=True)
    start.add_argument("--note", default="")
    start.set_defaults(func=cmd_start)
    switch = commands.add_parser("switch")
    switch.add_argument("--client-id", required=True)
    switch.add_argument("--note", default="")
    switch.set_defaults(func=cmd_switch)
    export = commands.add_parser("export")
    export.add_argument("--out", required=True)
    export.add_argument("--from", dest="from_date", default=None)
    export.add_argument("--to", dest="to_date", default=None)
    export.set_defaults(func=cmd_export)
    summary = commands.add_parser("summary")
    summary.add_argument("--from", dest="from_date", default=None)
    summary.add_argument("--to", dest="to_date", default=None)
    summary.set_defaults(func=cmd_summary)
    today = commands.add_parser("today")
    today.set_defaults(func=cmd_today)
    report = commands.add_parser("report")
    report.add_argument("--week", required=True, help="any YYYY-MM-DD day in the requested week")
    report.set_defaults(func=cmd_report)
    args = parser.parse_args()
    try:
        response = json.dumps({"ok": True, **args.func(args)})
        if len(response.encode("ascii")) > MAX_RESPONSE_BYTES:
            raise Error("Timer response is too large")
        print(response)
    except Error as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
