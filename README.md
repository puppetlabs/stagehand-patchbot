# patchbot — Package Updates + Windows Update for the Puppet Stagehand Console

Forge: `stagehand-patchbot`. Split out of the `stagehand` module so patch
tooling versions and ships independently. Two complementary paths, both
cross-platform (Linux and Windows):

- **Pull path** — `include patchbot` classifies a node with the `patchbot`
  external fact. On every agent run, patch posture — summary counts *and* an
  itemized list of available patches — reaches the console via PuppetDB, with
  no Bolt push required. On Linux, `patchbot` also keeps the package
  manager's own update metadata fresh (a small systemd timer) so the fact's
  counts stay meaningful between runs; on Windows this is a deliberate no-op
  (Windows Update maintains its own metadata, and the fact queries WUA live
  every run). The fact scripts ship in `facts.d/` and reach agents by
  pluginsync automatically once the module is in the environment modulepath.
- **Push path** — the `patchbot::patch` Bolt task (the console's "Patch"
  button) applies updates on demand — all, security-only, or a specific
  hand-picked set — and best-effort refreshes the fact's cache immediately
  afterward, rather than waiting for the next agent run.

Same "bring your own" posture as `trivy`/`openscap`: the console only cares
that *something* keeps the `patchbot` fact populated in the shape below — use
your own patch-posture reporter if you'd rather, and skip this module.

## Two console screens, one fact shape

- **Package Update** screen (Linux) — the coarse-grained experience: apply
  all available updates, or security-only, across a node group.
- **Windows Update** screen — modeled on double-clicking Windows Update on a
  server: see the individual available updates by KB and either apply all or
  hand-pick specific ones.

The console decides which screen a node belongs on using `$facts['kernel']`
(`'Linux'` vs `'windows'`) — **not** a different fact structure. `patchbot`
reports the exact same JSON keys on both platforms; only the values differ
(`id` is a KB number on Windows, a package name on Linux).

## Class

`include patchbot`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `manage_cache` | `Boolean` | `true` | Keep package-manager update metadata fresh via a systemd timer. **Linux only** — a no-op on Windows nodes (see above). |
| `cache_refresh` | `String[1]` | `'daily'` | systemd `OnCalendar` expression for the refresh timer. |

## Task

`patchbot::patch` — dispatches to `tasks/patch.sh` (POSIX) or
`tasks/patch.ps1` (Windows) automatically via Bolt's `implementations`
metadata; same parameters and same JSON output shape either way.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `console_url` | `Optional[String[1]]` | — | Server-injected; unused by the patch itself (posture reaches the console via the fact, not the task's own output). |
| `ingest_token` | `Optional[String[1]]` | — | Server-injected; unused by the patch itself. |
| `security_only` | `Boolean` | `false` | Apply only security updates when true; otherwise apply all available updates. Ignored when `patch_ids` is set. |
| `patch_ids` | `Optional[Array[String[1]]]` | — | Install only these specific ids, as reported in the fact (KB numbers from `missing[].kbs` on Windows, package names from `packages[].name` on Linux). Takes priority over `security_only`. |
| `reboot` | `Boolean` | `false` | Reboot the node afterward if a reboot is required. |

On Linux, `patch_ids` requires `jq` on the target (only when actually used —
every other path stays dependency-light). On Windows, no extra dependency:
`ConvertFrom-Json` is built in.

## The `patchbot` fact schema

This module publishes **schema version 2** of the `patchbot` fact: the same keys, and the same reboot rule, as the fact the
console's own `stagehand` module ships. The full contract (every key and every reboot reason code) is kept with the Puppet Stagehand Console's own documentation, which
this repository does not link to. A fact without `schema_version` is version 1.

A Linux fact (dnf):

```json
{
  "patchbot": {
    "schema_version": 2,
    "status": "ok",
    "available": 3,
    "security": 1,
    "reboot_required": false,
    "reboot_status": "not_required",
    "reboot_status_reason": "needs_restarting",
    "last_checked": "2026-11-17T14:03:00Z",
    "manager": "dnf",
    "repos": ["appstream", "baseos"],
    "packages": [
      { "name": "openssl", "arch": "x86_64", "current": "1:3.2.2-2.el9", "available": "1:3.2.2-6.el9_5", "repo": "rhel-9-appstream", "security": true }
    ],
    "package_count": 3,
    "truncated": false
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | integer | Always `2`. |
| `available` | integer | Count of packages/updates with an available update. Exact even when the list is capped. |
| `security` | integer | How many pending updates have a security advisory. An update is counted once even when several advisories or builds name it, and it is matched by exact package name, so `security` is never more than `available`. |
| `reboot_status` | enum | `required`, `not_required` or `unknown`. `unknown` means this node cannot tell (the tool that reports it is missing or failed, or no supported package manager is present). It is never reported as `not_required`. |
| `reboot_status_reason` | string | A fixed code saying why (for example `marker_present`, `needs_restarting`, `plugin_missing`, `no_package_manager`; `pending_reboot_probe`, `probes_clear`, `probes_failed` on Windows). Never raw command output. |
| `reboot_required` | boolean | Kept for readers of version 1: true only when `reboot_status` is `required`. |
| `last_checked` | string | ISO 8601 UTC timestamp of the last time this fact ran. |
| `manager` | string | `apt`, `dnf`, `yum` or `wua`; empty on a Linux node with no supported package manager. |
| `repos` | array | Linux: the configured suites or repository ids. |
| `packages[]` | array | Linux: `name`, `arch`, `current` (installed version), `available`, `repo`, `security`. Capped (see below). |
| `package_count`, `truncated` | integer, boolean | The full count, and whether the list above was cut at the cap. |
| `status`, `check_error` | string | dnf only: `ok`, or `check_failed` with a fixed `check_error` (`metadata_unavailable`, `package_manager_error`) when the update check could not run. |
| `os_build`, `installed_kbs`, `missing[]`, `source`, `wsus_server`, `cve_ids_populated`, `scan_error` | various | Windows: the build, the installed KBs, the missing updates (`kbs`, `title`, `severity`, `cve_ids`, `reboot`), and where the scan looked. |
| `cache_age_seconds`, `cache_stale` | integer, boolean | Windows: always `0` and `false` here, because this module's Windows fact scans live and has no cache. |

The package list is capped (`PCM_PATCH_MAX_PACKAGES`, default 500) because the fact is stored in PuppetDB and re-sent every agent
run. Only the detail list is capped; the counts stay exact and `truncated` says so.

The `patches[]` array of version 1 is no longer emitted. The console still falls back to it for a node that has not yet received
this module's new facts.

Structured JSON output requires Facter 4, which ships with Puppet 8 --
OpenVox, Puppet Core, and PE all qualify.

## Tests

The fact is tested together with its development copy in the Puppet Stagehand Console repository. This repository's CI runs the
task tests, rspec-puppet and Pester.

## Files

- `manifests/init.pp` — the `patchbot` class (Linux refresh timer only; the
  fact itself needs no Puppet-side management beyond pluginsync).
- `facts.d/patchbot.sh` — the Linux/POSIX fact (apt/dnf/yum).
- `facts.d/patchbot.ps1` — the Windows fact (WUA COM API). Coexists with
  `patchbot.sh` in the same directory; Facter only ever runs the one that
  matches the platform.
- `tasks/patch.json` — task metadata, including the `implementations` split.
- `tasks/patch.sh` / `tasks/patch.ps1` — the two task implementations.
