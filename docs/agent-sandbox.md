# Agent sandbox box — design and build plan

**Status: SUPERSEDED (2026-09-26).** Built instead as `devbox`
(`terraform/lxc-devbox.tf`): same unprivileged LXC at VMID 201, but on the
**primary LAN** (10.1.0.230) rather than VLAN 30 so it can do infra work, sized
128c / 48 GiB / 300 GiB now that the cluster collapse freed RAM, running T3
Code instead of DSH. The capacity analysis and LXC-vs-VM reasoning below still
hold; the placement and remote-access sections do not.

Goal: a box that runs Claude Code + DeepSeek Harness (DSH) agents unattended
overnight, reproducing Jacob's workstation toolchain, reachable remotely.

## Host capacity (probed live on `prox`, 2026-09-20)

| Resource | Total | Committed | Actually free |
|---|---|---|---|
| CPU | 256 threads (2x64C EPYC) | 111 vCPU assigned | load avg ~9.9 — effectively idle |
| **RAM** | **125.6 GiB** | 147 GB *configured*, 113.8 GB used | **~14.8 GiB** |
| Disk (`nvme` pool) | 1.9 TB | 677 GB | 1.23 TB |
| Cold spare | Samsung 990 PRO 4 TB (`nvme4n1`) | deliberately unassigned — do NOT claim | 3.6 TiB |

**CPU and disk are abundant. RAM is the only scarce resource.**

Two findings that shaped the design:

1. **The RAM overcommit is structural, not waste.** Workers 9111-9113 each
   hold `hostpci0` (Ceph OSD NVMe passthrough). **PCI passthrough pins the
   entire guest allocation**, so their `balloon` values are inert and that
   72 GiB cannot be reclaimed by right-sizing. The vault's "right-size VM
   allocations" idea does not apply to these three.
2. **CT 200 (minecraft) cannot be downsized** — it is capped at 49 GiB and
   holds 24.3 GiB (Java itself is 11.3 GiB, rest is reclaimable page cache),
   but that box is being sold to a friend, so it stays as-is.

## Decision: unprivileged LXC, not a VM

RAM math decides it:

- A **VM reserves** its allocation up front — 8 GiB costs 8 GiB on day one.
- An **LXC is a cgroup cap, not a reservation** — an idle sandbox costs what
  it touches (~1-2 GiB) and shares the host page cache.

With ~14.8 GiB free, that difference is the whole argument.

**Verified prerequisite (this is the risk that could have killed the LXC
plan):** DSH's local sandbox selects `bwrap`/Landlock and **fails closed with
`SANDBOX_UNAVAILABLE`** if it cannot get a user namespace. Probed inside
CT 200 (also unprivileged + `nesting=1`):

```
/proc/sys/user/max_user_namespaces = 2147483647
unshare -Ur            -> USERNS OK (uid=0)
unshare -Umpf          -> NESTED NS OK   (mount + PID)
/proc/self/attr/current -> unconfined     (AppArmor)
```

So userns, nested namespaces and Docker all work in this profile. **LXC is
safe.** If a future kernel/AppArmor change breaks this, fall back to a VM at
8 GiB and accept the reservation.

Packer template 9001 is *k8s-specific* (containerd + pinned kubelet) and is
the wrong base for a dev box; the generic
`ubuntu-26.04-standard` vztmpl is already on the `nvme` pool.

## Placement

| Setting | Value | Why |
|---|---|---|
| VMID | **201** | 2xx = one-off guest band (CT 200 precedent); verified free |
| IP | **10.4.0.230** | Above DHCP range (.6-.199) and MetalLB pool (.200-.220); verified unused |
| VLAN | **30 (k8s-lab)** | See below |
| Sizing | 8 cores / 8192 MiB cap / 150 GiB on `nvme` | Fits today with zero disruption |
| MAC | `BC:24:11:30:00:C9` | Pinned so the DHCP reservation can be declared first |

**VLAN 30 is a deliberate sandbox posture, not convenience.** The
`Allow Internal to k8s-lab` policy lets the primary LAN reach the box, while
the k8s-lab zone **default-denies outbound to Internal**. So a misbehaving
agent can reach the internet and the cluster, but **not** the primary LAN.

## Files to create

1. `terraform/lxc-agent-sandbox.tf` — follows `lxc-ryan-minecraft.tf`
   exactly (same module, same state, same `terraform@pve!k8s-homelab` token).
   `unprivileged = true`, `features { nesting = true }`.
2. `UnifiTerraform/dhcp_reservations.tf` — `unifi_client` pinning the MAC
   above to .230 so DHCP can never hand it out. Keep in sync with (1).
3. `UnifiTerraform/pihole_dns.tf` — an `agent-sandbox` DNS record.

**Note:** `terraform/lxc-ryan-minecraft.tf` is currently **untracked in
git**. Commit it alongside this work.

## Toolchain to replicate (inventoried from the live workstation)

- **Claude Code 2.1.278 via the native installer** (NOT npm) —
  `~/.local/bin/claude` -> `~/.local/share/claude/versions/<ver>`.
- 5 plugins across 4 marketplaces: `gopls-lsp`, `skill-creator`,
  `clangd-lsp` (anthropics/claude-plugins-official), `claude-seo`
  (AgriciDaniel/claude-seo), `autoresearch` (uditgoenka/autoresearch).
- 26 user skills + `settings.json` + the 14 KB custom `statusline.sh`.
- **DSH** checkout at `fb2c4b9e69` (0.1.5-rc.2), `pnpm build`, symlink
  `~/.local/bin/dsh` -> `apps/cli/lib/bin.js`. Config dir is `~/.dsh`
  (not `~/.config/dsh`).
- DSH profile `web` deps: `@linxin666/dsh-web-all@0.3.23`,
  `dsh-client-ui-skin-center`, `@openviking/dsh-memory-plugin`,
  `@vectorize-io/hindsight-coding-agents`, `dsh-context`,
  `dsh-plugin-subscriptions`, `dshmarket`.
- **Node >= 22.19.0.** The workstation runs 22.18.0, which is *below* DSH's
  declared engine floor — install a compliant version rather than reproduce
  the mismatch. `corepack` for `pnpm@11.7.0`.
- zsh + oh-my-zsh (3 external plugins). Note `ConfigFiles` does **not**
  track `~/.zshrc`, `~/.claude/` or `~/.dsh/` — those must be copied from
  the live home.

**Do not copy credentials.** `.credentials.json`, `auth.json`, `~/.aws`,
`~/.kube/config` must be re-authenticated on the box. Copying workstation
OAuth tokens onto an unattended agent host defeats the point of a sandbox.

## Remote access — corrected understanding

An early search of the `deepseek-harness` checkout concluded there is "no
remote access plugin." **That is true of the core repo but wrong overall.**
The plugin is third-party and lives in the DSH profile, not the checkout:

**`@linxin666/dsh-remote-web-ui` v0.3.23**, installed transitively via
`@linxin666/dsh-web-all`, at
`~/.dsh/profiles/web/node_modules/@linxin666/dsh-remote-web-ui`
(repo `github.com/zhu1090093659/dsh-web`). Verified present.

It provides QR scan-to-pair, one-time pairing tokens, revocable device
sessions, a LAN-bind toggle, and a bundled `cloudflared` tunnel. ("Remote" in
the *core* DSH tree means Typert RPC — unrelated.)

**Chosen approach: the plugin's Cloudflare tunnel. No Kubernetes endpoint.**

A Traefik/EndpointSlice ingress was designed and rejected as unnecessary: it
would have been the first external-backend-through-ingress in this cluster
(zero existing `ExternalName`/`EndpointSlice` precedent), the Traefik->box hop
is plaintext over VLAN 30, and DSH reads **no `X-Forwarded-*` headers** (its
trust fence keys off the literal `Host`, so the external hostname must appear
in `trustedHosts` or every `/api` call 403s). The plugin already solves the
problem without any of that.

### Standing configuration: LAN-bound, tunnel off

A Cloudflare tunnel is by definition internet-reachable, which is in tension
with "LAN only." Resolution:

- **Standing state: LAN bind + pairing required, `autoTunnel` OFF.** Nothing
  is publicly reachable while unattended.
- **Tunnel is on-demand** — started deliberately when off-LAN access is
  wanted, and it is ephemeral per `dsh web` restart.

This matters because DSH here runs `permission.defaultPreset:
danger-full-access`: **anything reaching that GUI gets arbitrary code
execution as the OS user.** The auth cookie is deliberately **not** marked
`Secure`, and a paired device is a full-control credential.

Also note the plugin manages host firewall rules (firewalld/ufw/iptables); in
an unprivileged LXC that will degrade to "unmanaged" unless granted
capabilities. That is acceptable for LAN-bound operation.

## Open items

- `docs/architecture.md`'s node-sizing table is stale (says 2 vCPU/4 GB
  masters; reality is 6/6144 and 20/24576).
- `docs/new-environment-setup.md` is referenced from `unifi/README.md` but
  does not exist.
- No "add a new VM" runbook exists; this document is the closest thing.
- Live MetalLB has `rook-ceph-mgr-dashboard-lb` at 10.4.0.203, absent from
  the CLAUDE.md infrastructure table.
