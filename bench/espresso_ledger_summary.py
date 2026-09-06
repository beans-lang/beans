import sys, statistics
from collections import OrderedDict

rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])][1:]
by = OrderedDict()
dropped = []
for r in rows:
    if len(r) < 12 or not r[3].isdigit():
        dropped.append(r); continue
    by.setdefault((r[0], r[1]), []).append(r)

def med(rs, i):
    return statistics.median(float(x[i].replace(",", "")) for x in rs)

routes, servers = [], []
for (route, srv) in by:
    if route not in routes: routes.append(route)
    if srv not in servers: servers.append(srv)

floor_rps = {r: med(by[(r, "floor")], 4) for r in routes if (r, "floor") in by}
floor_cpu = {r: med(by[(r, "floor")], 5) for r in routes if (r, "floor") in by}
floor_usr = {r: med(by[(r, "floor")], 6) for r in routes if (r, "floor") in by}

hdr = (f"{'route':<9} {'server':<9} {'req/s':>9} {'cpu/req':>9} {'user':>8} {'sys':>8} "
       f"{'rss MB':>7} {'p50 ms':>7} {'p99 ms':>7} {'of floor':>8}  flags")
print(hdr)
print("-" * len(hdr))
for route in routes:
    for srv in servers:
        if (route, srv) not in by: continue
        rs = by[(route, srv)]
        rps, cpu, usr, sysu = med(rs, 4), med(rs, 5), med(rs, 6), med(rs, 7)
        rss, p50, p99 = med(rs, 8), med(rs, 9), med(rs, 10)
        vs = f"{100 * rps / floor_rps[route]:.0f}%" if route in floor_rps else "-"
        flags = ",".join(sorted({x[11] for x in rs} - {"-"})) or ""
        print(f"{route:<9} {srv:<9} {rps:>9,.0f} {cpu:>8.2f}µ {usr:>7.2f}µ {sysu:>7.2f}µ "
              f"{rss:>7.1f} {p50:>7.2f} {p99:>7.2f} {vs:>8}  {flags}")
    if route in floor_cpu:
        # The user column is the one a lane moves. The floor's own user time is
        # what "no framework at all" costs, so the gap to it is the work left.
        print(f"{'':<9} {'':<9} {'':>9} {'floor: ':>9}{floor_cpu[route]:.2f}µ cpu, "
              f"{floor_usr[route]:.2f}µ user")
    print()

if dropped:
    print("dropped rows:")
    for d in dropped:
        print("  " + "\t".join(d))
