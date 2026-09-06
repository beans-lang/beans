#!/usr/bin/env python3
"""One ledger row: wrk's throughput and latency joined to the server's rusage.

Reads a wrk report and a rusage_wrap stats file and writes a single tab
separated row. Kept out of the shell script because wrk reports latency in
whichever unit fits (us, ms, s) and comparing those as text is how a p99 in
microseconds comes to look slower than one in milliseconds.
"""
import re
import sys

UNITS = {"us": 1e-3, "ms": 1.0, "s": 1e3, "m": 60e3}


def to_ms(text):
    """wrk latency -> milliseconds. Returns None when the field is absent."""
    if not text:
        return None
    m = re.fullmatch(r"([0-9.]+)(us|ms|s|m)", text.strip())
    if not m:
        return None
    return float(m.group(1)) * UNITS[m.group(2)]


def main():
    route, server, rnd, wrk_path, stats_path = sys.argv[1:6]

    requests = rps = None
    p50 = p99 = None
    non2xx = 0
    sock_err = ""
    for line in open(wrk_path, errors="replace"):
        s = line.strip()
        m = re.match(r"([0-9]+) requests in", s)
        if m:
            requests = int(m.group(1))
        m = re.match(r"Requests/sec:\s+([0-9.]+)", s)
        if m:
            rps = float(m.group(1))
        m = re.match(r"50%\s+(\S+)", s)
        if m:
            p50 = to_ms(m.group(1))
        m = re.match(r"99%\s+(\S+)", s)
        if m:
            p99 = to_ms(m.group(1))
        m = re.match(r"Non-2xx or 3xx responses:\s+([0-9]+)", s)
        if m:
            non2xx = int(m.group(1))
        if s.startswith("Socket errors:"):
            sock_err = s[len("Socket errors:"):].strip()

    stats = {}
    try:
        for line in open(stats_path):
            k, _, v = line.partition(" ")
            stats[k] = v.strip()
    except FileNotFoundError:
        pass

    if not requests or requests <= 0 or "user_sec" not in stats:
        why = "NO-REQUESTS" if not requests else "NO-RUSAGE"
        print(f"{route}\t{server}\t{rnd}\t{why}")
        return

    user = float(stats["user_sec"])
    sysc = float(stats["sys_sec"])
    rss_mb = int(stats.get("maxrss_bytes", 0)) / 1048576

    # A run with dropped connections or error responses is not a measurement of
    # the route; it is flagged here so no reader has to open the wrk log to
    # find out. Read timeouts alone are noted but not disqualifying — wrk
    # counts a slow tail as a timeout.
    flags = []
    if non2xx:
        flags.append(f"NON2XX={non2xx}")
    if sock_err:
        real = [p for p in sock_err.split(",") if "timeout 0" not in p and "timeout" not in p]
        flags.append("SOCKERR" if real else "timeouts")

    print(
        "\t".join(
            [
                route,
                server,
                rnd,
                str(requests),
                f"{rps:.0f}" if rps else "",
                f"{(user + sysc) * 1e6 / requests:.3f}",
                f"{user * 1e6 / requests:.3f}",
                f"{sysc * 1e6 / requests:.3f}",
                f"{rss_mb:.2f}",
                f"{p50:.3f}" if p50 is not None else "",
                f"{p99:.3f}" if p99 is not None else "",
                ",".join(flags) if flags else "-",
            ]
        )
    )


if __name__ == "__main__":
    main()
