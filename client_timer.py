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
COLORS = {"#e06c75", "#d19a66", "#e5c07b", "#98c379", "#56b6c2", "#61afef", "#c678dd"}
HEX_COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")
TIME_OF_DAY = re.compile(r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")


class Error(Exception):
    pass


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def default_state():
    return {"version": 1, "settings": {"workdayHours": 8, "menuLabelStyle": "project"}, "clients": [], "active": None, "entries": []}


def load():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            state = json.load(f)
    except FileNotFoundError:
        return default_state()
    state.setdefault("settings", {"workdayHours": 8})
    state["settings"].setdefault("workdayHours", 8)
    state["settings"].setdefault("menuLabelStyle", "project")
    return state


def save(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".tmp.", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, STATE_FILE)
    except BaseException:
        os.unlink(temp)
        raise


def client(state, client_id):
    for item in state["clients"]:
        if item["id"] == client_id:
            return item
    raise Error("Client not found")


def view(state):
    return {"settings": state["settings"], "clients": state["clients"], "active": state["active"], "entries": state["entries"][:8]}


def cmd_init(_):
    state = load()
    save(state)
    return {"state": view(state)}


def cmd_state(_):
    return {"state": view(load())}


def cmd_client_add(args):
    state = load()
    name = args.name.strip()
    if not name:
        raise Error("Client name is required")
    if not HEX_COLOR.fullmatch(args.color):
        raise Error("Company color must be a #RRGGBB value")
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
    if not HEX_COLOR.fullmatch(args.color):
        raise Error("Company color must be a #RRGGBB value")
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
    state["active"] = {"id": uuid.uuid4().hex, "clientId": args.client_id, "note": args.note.strip(), "start": now(), "pausedAt": None, "pausedSeconds": 0}
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
    started = now()
    finish_active(state, started)
    state["active"] = {
        "id": uuid.uuid4().hex, "clientId": args.client_id, "note": args.note.strip(),
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
    totals = {}
    for entry in entries:
        totals[entry["clientId"]] = totals.get(entry["clientId"], 0) + entry["seconds"]
    rows = [{
        "clientId": client_id,
        "name": companies.get(client_id, {}).get("name", "Deleted company"),
        "color": companies.get(client_id, {}).get("color", "#61afef"),
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
    active = state["active"]
    if active and dt.datetime.fromisoformat(active["start"]).astimezone().date() == today:
        end = dt.datetime.fromisoformat(active["pausedAt"] or now())
        start = dt.datetime.fromisoformat(active["start"])
        seconds = max(0, int((end - start).total_seconds()) - active["pausedSeconds"])
        totals[active["clientId"]] = totals.get(active["clientId"], 0) + seconds
        local_start = start.astimezone()
        segments.append({"clientId": active["clientId"], "startSeconds": local_start.hour * 3600 + local_start.minute * 60 + local_start.second, "seconds": seconds})
    companies = {item["id"]: item for item in state["clients"]}
    rows = [{
        "clientId": client_id,
        "name": companies.get(client_id, {}).get("name", "Deleted company"),
        "color": companies.get(client_id, {}).get("color", "#61afef"),
        "seconds": seconds,
    } for client_id, seconds in totals.items()]
    rows.sort(key=lambda row: row["seconds"], reverse=True)
    for segment in segments:
        segment["color"] = companies.get(segment["clientId"], {}).get("color", "#61afef")
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
            "color": company.get("color", "#61afef"),
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
                "color": companies.get(company_id, {}).get("color", "#61afef"),
                "seconds": seconds,
            } for company_id, seconds in sorted(day_companies[day].items(), key=lambda item: item[1], reverse=True)],
        } for day in day_seconds],
        "monthRows": rows,
        "monthTotalSeconds": sum(company_seconds.values()),
    }}


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name, func in {"init": cmd_init, "state": cmd_state, "pause": cmd_pause, "resume": cmd_resume, "stop": cmd_stop}.items():
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
        print(json.dumps({"ok": True, **args.func(args)}))
    except Error as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
