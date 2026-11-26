#!/bin/zsh
# Restart every other running Claude Code CLI session in its own terminal and resume the exact session.
#
# Usage: restart-claude-sessions.zsh [--dry-run] [--yes] [--gui] [--skip PID,...] [--only PID,...] [--self-test]
#   --dry-run    Print the table and the relaunch commands. Change nothing.
#   --yes        Do not ask for confirmation.
#   --gui        Confirm in a macOS dialog and report in a notification. For hotkeys.
#   --skip       Leave these PIDs running.
#   --only       Restart only these PIDs.
#   --self-test  Run the argument-rebuild checks and exit.
#
# Session ID, first match wins:
#   1. <config dir>/sessions/<pid>.json  (live ID, correct after /clear)
#   2. --resume <uuid> or --session-id <uuid> in the process arguments
#   3. an open .jsonl transcript (lsof)
#   4. the transcript in projects/<encoded cwd>/ that contains the start prompt, else the newest one (a guess).
#      Guesses skip IDs that another live process owns and transcripts older than the process.
# A session with no resumable transcript is listed but not stopped.
#
# Input injection, first that works:
#   1. TIOCSTI on the target TTY, root only (macOS refuses it for other users)
#   2. `orca terminal send` with the ORCA_TERMINAL_HANDLE of the target process
#   3. a printed one-line command per session
# Without root, a session outside an Orca pane is listed but not stopped.

emulate -L zsh
setopt pipe_fail no_unset

# Hotkey daemons and launchers start with a minimal PATH.
path=($HOME/.local/bin /opt/homebrew/bin /usr/local/bin $path /usr/bin /bin /usr/sbin /sbin
      /Applications/Orca.app/Contents/Resources/bin $HOME/Apps/Orca.app/Contents/Resources/bin)
for c in claude python3; do (( $+commands[$c] )) || { print -u2 "$c not found on PATH"; exit 1; }; done

dry=0 yes=0 gui=0 skip=() only=()
while (( $# )); do
  case $1 in
    --dry-run|-n) dry=1 ;;
    --yes|-y) yes=1 ;;
    --gui) gui=1 ;;
    --skip) skip+=(${(s:,:)2}); shift ;;
    --skip=*) skip+=(${(s:,:)1#--skip=}) ;;
    --only) only+=(${(s:,:)2}); shift ;;
    --only=*) only+=(${(s:,:)1#--only=}) ;;
    --self-test) mode=test ;;
    -h|--help) sed -n '2,25p' $0 | cut -c3-; exit 0 ;;
    *) print -u2 "unknown option: $1"; exit 2 ;;
  esac
  shift
done

read -r -d '' PY <<'PY'
import ctypes, ctypes.util, errno, fcntl, glob, json, os, re, shlex, struct, subprocess, sys, termios, time

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DROP = {"-r", "--resume", "-c", "--continue", "--session-id", "--fork-session", "-p", "--print"}
SEP = "\x1f"

def option_arity(help_text):
    """Map every option name to None (flag), 'req', 'opt' or 'var' from `claude --help`."""
    arity = {}
    for line in help_text.splitlines():
        m = re.match(r"^  (-[^\s<\[,]+(?:,\s+-[^\s<\[,]+)*)(?:\s([<\[])[^\s>\]]*?(\.\.\.)?[>\]])?", line)
        if not m:
            continue
        kind = None if not m.group(2) else "var" if m.group(3) else "req" if m.group(2) == "<" else "opt"
        for name in re.split(r",\s+", m.group(1)):
            arity[name] = kind
    return arity

def split_args(args, arity):
    """Return (options to keep, session id found in arguments, positional prompt)."""
    keep, found, prompt, i = [], None, None, 0
    while i < len(args):
        a = args[i]; i += 1
        if a == "--":
            prompt = prompt or (args[i] if i < len(args) else None); break
        if not a.startswith("-") or a == "-":
            prompt = prompt or a; continue
        name, eq, inline = a.partition("=")
        kind, vals = arity.get(name), ([inline] if eq else [])
        if not eq:
            if kind == "req" and i < len(args):
                vals = [args[i]]; i += 1
            elif kind == "opt" and i < len(args) and not args[i].startswith("-"):
                vals = [args[i]]; i += 1
            elif kind == "var":
                while i < len(args) and not args[i].startswith("-"):
                    vals.append(args[i]); i += 1
        if name in DROP:
            if name in ("-r", "--resume", "--session-id") and vals and UUID.match(vals[0]):
                found = vals[0]
            continue
        keep += [a] + ([] if eq else vals)
    return keep, found, prompt

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

def procargs(pid):
    """Exact argv and environment of a process, via sysctl KERN_PROCARGS2."""
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(1 << 20)
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno(), "sysctl KERN_PROCARGS2")
    raw = buf.raw[:size.value]
    argc = struct.unpack("i", raw[:4])[0]
    rest = raw[4:]
    rest = rest[rest.index(b"\0"):].lstrip(b"\0")   # skip the executable path
    parts = [p.decode(errors="replace") for p in rest.split(b"\0")]
    env = dict(p.split("=", 1) for p in parts[argc:] if "=" in p)
    return parts[:argc], env

def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def session_file(pid, conf):
    try:
        with open(f"{conf}/sessions/{pid}.json") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}

def known_session(pid, conf, found):
    s = session_file(pid, conf)
    if s.get("sessionId"):
        return s["sessionId"], "sessions-file", s.get("status", "?")
    if found:
        return found, "argument", "?"
    for line in run("lsof", "-p", str(pid), "-Fn").splitlines():
        m = re.search(r"/projects/[^/]+/([0-9a-f-]{36})\.jsonl$", line)
        if m:
            return m.group(1), "open-file", "?"
    return None

def guess_session(pid, cwd, conf, prompt, claimed):
    """Transcripts in the cwd project that no other live process owns and that changed after this process started."""
    started = time.mktime(time.strptime(run("ps", "-o", "lstart=", "-p", str(pid)).strip(), "%a %b %d %H:%M:%S %Y"))
    files = sorted((p for p in glob.glob(f"{conf}/projects/{re.sub(r'[^A-Za-z0-9]', '-', cwd)}/*.jsonl")
                    if os.path.basename(p)[:-6] not in claimed and os.path.getmtime(p) >= started),
                   key=os.path.getmtime, reverse=True)
    if prompt:
        needle = json.dumps(prompt[:80])[1:-1].encode()
        for path in files:
            with open(path, "rb") as f:
                if needle in f.read():
                    return os.path.basename(path)[:-6], "prompt-match", "?"
    if len(files) == 1:   # more than one candidate: too ambiguous to resume
        return os.path.basename(files[0])[:-6], "newest-guess", "?"
    return "", "none" if not files else f"ambiguous({len(files)})", "?"

def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

def scan(exclude):
    arity = option_arity(run("claude", "--help"))
    if not arity:
        sys.exit("`claude --help` listed no options; cannot rebuild command lines safely")
    procs = []
    for line in run("ps", "-ax", "-o", "pid=,tty=,comm=").splitlines():
        pid, tty, comm = line.split(None, 2)
        if not tty.startswith("ttys") or os.path.basename(comm) != "claude" or int(pid) in exclude:
            continue
        pid = int(pid)
        try:
            argv, env = procargs(pid)
        except OSError as e:
            print(f"skip {pid}: {e}", file=sys.stderr); continue
        cwd = next((l[1:] for l in run("lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn").splitlines()
                    if l.startswith("n")), "")
        conf = env.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
        keep, found, prompt = split_args(argv[1:], arity)
        procs.append((pid, tty, cwd, conf, env, argv[0], keep, prompt, known_session(pid, conf, found)))
    claimed = {p[-1][0] for p in procs if p[-1]}
    for conf in {p[3] for p in procs}:   # sessions of every live process, with or without a TTY
        for path in glob.glob(f"{conf}/sessions/*.json"):
            pid = int(os.path.basename(path).split(".")[0])
            if pid_alive(pid):
                claimed.add(session_file(pid, conf).get("sessionId"))
    rows = []
    for pid, tty, cwd, conf, env, exe, keep, prompt, known in procs:
        uuid, source, status = known or guess_session(pid, cwd, conf, prompt, claimed)
        if uuid and not glob.glob(f"{conf}/projects/*/{uuid}.jsonl"):
            source += ",no-transcript"
            uuid = ""
        # No resumable session: leave the process alone, a restart would lose it.
        line = f"cd {shlex.quote(cwd)} && {shlex.join([exe] + keep + ['--resume', uuid])}" if uuid else ""
        name = session_file(pid, conf).get("name") or next(
            (keep[i + 1] for i, k in enumerate(keep[:-1]) if k in ("-n", "--name")), "-")
        # A session that another claude process started inherits that parent's Orca pane handle.
        handle = "" if "CLAUDE_PID" in env else env.get("ORCA_TERMINAL_HANDLE", "")
        rows.append([str(pid), "/dev/" + tty, name, status, source, uuid or "-", cwd, handle, line])
    for r in rows:
        print(SEP.join(x.replace(SEP, " ").replace("\n", " ") for x in r))

def tiocsti(tty, text):
    fd = os.open(tty, os.O_RDWR | os.O_NOCTTY)
    try:
        for b in text.encode():
            fcntl.ioctl(fd, termios.TIOCSTI, bytes([b]))
    except OSError as e:
        print(f"TIOCSTI {tty}: {os.strerror(e.errno)}", file=sys.stderr)
        sys.exit(3 if e.errno in (errno.EPERM, errno.EACCES) else 1)
    finally:
        os.close(fd)

def test():
    help_text = ("  -r, --resume [value]   x\n  -c, --continue   x\n  --effort <level>   x\n"
                 "  --add-dir <directories...>   x\n  --plugin-dir <path>   x\n  -n, --name <name>   x\n"
                 "                                        --resume <session-id>, ignored\n")
    a = option_arity(help_text)
    assert a == {"-r": "opt", "--resume": "opt", "-c": None, "--continue": None, "--effort": "req",
                 "--add-dir": "var", "--plugin-dir": "req", "-n": "req", "--name": "req"}, a
    u = "7b831b94-31a0-4e4d-b600-6427ff03607f"
    assert split_args(["--plugin-dir", "/a b/c", "--effort", "high", "--resume", u], a) == \
        (["--plugin-dir", "/a b/c", "--effort", "high"], u, None)
    assert split_args(["--permission-mode", "x", "-n", "s1", "do the thing"], a | {"--permission-mode": "req"}) == \
        (["--permission-mode", "x", "-n", "s1"], None, "do the thing")
    assert split_args(["-c", "--effort=max"], a) == (["--effort=max"], None, None)
    assert split_args(["--resume", "--add-dir", "d1", "d2", "--", "hi"], a) == (["--add-dir", "d1", "d2"], None, "hi")
    print("self-test ok")

mode = sys.argv[1]
if mode == "scan":
    scan({int(x) for x in sys.argv[2:]})
elif mode == "inject":
    tiocsti(sys.argv[2], sys.argv[3] + "\n")
else:
    test()
PY

if [[ ${mode:-} == test ]]; then python3 -I -c "$PY" test; exit; fi

# Exclude this script and every ancestor, so the calling session survives.
exclude=() p=$$
while (( p > 1 )); do exclude+=$p; p=${$(ps -o ppid= -p $p)// /}; [[ -n $p ]] || break; done

notify() {   # macOS notification in --gui mode
  (( gui )) && osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Claude sessions"' \
    -e 'end run' "$1" >/dev/null 2>&1
  return 0
}
confirm_dialog() {   # exit 0 only when the user clicks Restart
  osascript - "$1" >/dev/null 2>&1 <<'AS'
on run argv
  activate
  set r to display dialog (item 1 of argv) with title "Restart Claude sessions" buttons {"Cancel", "Restart"} ¬
    default button "Cancel" cancel button "Cancel" with icon caution giving up after 60
  if gave up of r then error number -128
end run
AS
}

rows=("${(@f)$(python3 -I -c "$PY" scan $exclude)}")
rows=(${rows:#})
if (( ! $#rows )); then print "No other Claude Code sessions on a TTY."; notify "No other sessions found."; exit 0; fi

S=$'\x1f'
{
  print -r -- "PID${S}TTY${S}NAME${S}STATUS${S}SOURCE${S}SESSION${S}CWD"
  for r in $rows; do f=("${(@ps:\x1f:)r}"); print -r -- "${(pj:\x1f:)f[1,7]}"; done
} | column -t -s $S
print "\nRelaunch commands:"
keep=()
for r in $rows; do
  f=("${(@ps:\x1f:)r}")
  if (( ${skip[(Ie)$f[1]]} )) || { (( $#only )) && (( ! ${only[(Ie)$f[1]]} )) }; then
    print -r -- "  $f[1]  (not restarted: --skip or --only)"
  elif [[ -z $f[9] ]]; then print -r -- "  $f[1]  (not restarted: no resumable session)"
  elif (( EUID )) && [[ -z $f[8] || $+commands[orca] == 0 ]]; then
    # Without root (TIOCSTI) or an Orca pane, nothing can type the relaunch command.
    print -r -- "  $f[1]  (not restarted: not in an Orca pane)"
  else print -r -- "  $f[1]  $f[9]"; keep+=$r; fi
done
rows=($keep)
(( ${#${(M)rows:#*newest-guess*}} )) && print "\nSOURCE newest-guess: the session ID is a guess. Check it before you continue."

(( dry )) && exit 0
(( $#rows )) || { print "Nothing to restart."; notify "Nothing to restart."; exit 0; }
if (( ! yes && gui )); then
  list=(); for r in $rows; do f=("${(@ps:\x1f:)r}"); list+="$f[3]   ($f[4])"; done
  confirm_dialog "Restart $#rows sessions?"$'\n\n'"${(F)list}" || { print "Cancelled."; exit 1; }
elif (( ! yes )); then
  read -q "?Restart these $#rows sessions? [y/N] " </dev/tty || { print "\nCancelled."; exit 1; }
  print
fi

pids=(); for r in $rows; do pids+=${r%%$S*}; done
alive() { local x out=(); for x in $@; do kill -0 $x 2>/dev/null && out+=$x; done; print -r -- $out }
stop() {   # stop <signal> <seconds> <pids...>; prints the PIDs still alive
  local sig=$1 secs=$2; shift 2
  kill -$sig $@ 2>/dev/null
  local left=($@) n=0
  while (( $#left && n < secs * 5 )); do left=($(alive $left)); (( $#left )) && sleep 0.2; (( n++ )); done
  print -r -- $left
}
left=($(stop INT 10 $pids))
(( $#left )) && { print "SIGTERM to: $left"; left=($(stop TERM 5 $left)); }

shell_ready() {   # the foreground process on the TTY is a shell
  local n=0
  while (( n++ < 25 )); do
    ps -t ${1#/dev/} -o stat=,comm= | grep -qE '\+.*[-/]?(zsh|bash|fish|sh)$' && return 0
    sleep 0.2
  done
  return 1
}

tiocsti=$(( EUID == 0 )) manual=() relaunched=0
for r in $rows; do
  f=("${(@ps:\x1f:)r}"); pid=$f[1] tty=$f[2] handle=$f[8] cmd=$f[9]
  if (( ${left[(Ie)$pid]} )); then print "$pid: still running, skipped"; continue; fi
  shell_ready $tty || print "$pid: no shell prompt on $tty, input may be lost"
  if (( tiocsti )); then
    python3 -I -c "$PY" inject $tty $cmd && { print "$pid: relaunched via TIOCSTI"; (( relaunched++ )); continue; }
    (( $? == 3 )) && tiocsti=0
  fi
  if [[ -n $handle ]] && (( $+commands[orca] )) &&
     orca terminal send --terminal $handle --text $cmd --enter >/dev/null; then
    print "$pid: relaunched via orca terminal send"; (( relaunched++ )); continue
  fi
  manual+=("$tty: $cmd")
done
(( $#manual )) && { print "\nRun these by hand:"; print -rl -- "  "$^manual; }
notify "$relaunched of $#rows sessions restarted.${${relaunched:#$#rows}:+ Run restart-claude-sessions in a terminal for details.}"
exit 0
