# Changelog

## 0.3.1 (unreleased)

- **Fixed: `Obsoleting Packages` rows were counted as pending updates on yum (and on dnf when the replaced row had a dot).**
  `yum -q check-update` and `dnf -q check-update` print an `Obsoleting Packages` section after the real updates; its rows are
  replacements, not updates. The yum filter kept every row of three or more fields, so both the replacing package and the
  indented replaced package were counted: `available` and `package_count` were too high, both rows appeared in
  `packages[]`, and `security` could include them. The dnf filter dropped only the header, so the
  indented replaced row still got through. Both branches now stop reading at the `Obsoleting Packages` header.
- **Correction to the 0.3.0 notes: the Windows fact changed shape, and the "keeps working" statement below does not hold for
  Windows readers.** The 0.3.0 entry says a version 1 reader keeps working and that everything else is additive. That is true
  of the Linux fact. On Windows, `facts.d/patchbot.ps1` no longer emits the `patches[]` array (`{"id","severity","security"}`)
  that 0.2.0 and earlier emitted. Anything that read `patches[]` on Windows nodes (PuppetDB queries, third-party reporting)
  must move to `missing[]`:
  - `patches[]` is replaced by `missing[]`, one entry per missing update with `kbs` (an array of KB numbers), `title`,
    `severity` (the raw MSRC severity string, or null; no longer folded into low/medium/high/unknown), `cve_ids` and
    `reboot`. An update with no KB has an empty `kbs` array; it is no longer keyed by its Windows Update GUID.
  - `os_build` (four-part build, for example `10.0.20348.3328`) and `installed_kbs` (sorted array of installed KB numbers) are
    added, along with `source`, `wsus_server`, `cve_ids_populated` and `scan_error`.
  - `cache_age_seconds` (always `0`) and `cache_stale` (always `false`) are added. The Windows fact scans the Windows Update
    Agent live on every run, as it did before; there is no cache to age.
  - `security` on Windows is now the number of missing updates whose MSRC severity is set and not `Unspecified`, counted over the
    whole scan. It used to also count any update in the `Security Updates` category.
  - `reboot_required` is now derived from the four reboot probes, not from the Windows Update `SystemInfo.RebootRequired` flag.
- `facts.d/patchbot.sh` is again a byte-identical copy of the development copy kept in the Puppet Stagehand Console repository.
  sha256: `patchbot.sh` `73fa520357f3e1857ae6fb30534c8876141b9fcf602e96c2a542efd2a49f94cd`. `facts.d/patchbot.ps1` is unchanged from
  0.3.0.

## [0.3.0] - 2026-11-18

0.2.0 was never tagged or released, and 0.3.0 is the first release that carries it: everything under 0.2.0 below ships in 0.3.0
too.

- **The `patchbot` fact is now schema version 2, on Linux and Windows.** The fact carries `schema_version: 2`. A reader written
  for version 1 keeps working: `available`, `security`, `reboot_required` and `last_checked` mean what they always did, and
  everything else is additive.
- **Three-state reboot answer.** `reboot_status` is always present and is `required`, `not_required` or `unknown`. `unknown`
  means the node cannot tell, and it is never read as "no". `reboot_status_reason` is a fixed code saying why, never raw command
  output. `reboot_required` is kept for version 1 readers and is true only when `reboot_status` is `required`.
- **How each platform decides.** apt reads the `/var/run/reboot-required` marker, and reports `unknown` when no marker exists and
  nothing installed would ever write one. dnf runs `needs-restarting -r` and reads its exit code; a missing plugin is reported as
  `unknown` (`plugin_missing`), not as "no reboot needed". yum uses the standalone `needs-restarting` the same way. Windows runs
  four probes (Component Based Servicing, Windows Update, pending file renames, and System Center Configuration Manager when
  present); any yes is `required`, and a probe that failed is never read as a no.
- **dnf reports when the update check could not run.** `status` is `ok`, or `check_failed` with a fixed `check_error`
  (`metadata_unavailable` or `package_manager_error`), and the counts are then zero instead of looking like a clean node.
- **Package detail.** The fact lists `repos`, `package_count` and `truncated`. `packages[]` is capped by `PCM_PATCH_MAX_PACKAGES`
  (default 500); only the list is capped, and `available`, `security` and `package_count` stay exact.
- **`security` is now an exact count of pending updates.** It used to count advisory rows, so a package named in several
  advisories was counted several times and `security` could exceed `available`. It now counts each pending update that has a
  security advisory once, matched by exact package name, so one package can no longer be flagged by another package's advisory
  that merely starts with the same letters.
- The patch task (`tasks/patch.*`) is unchanged in this release.
- `facts.d/patchbot.sh` and `facts.d/patchbot.ps1` are byte-identical copies of the development copy kept in the Puppet Stagehand
  Console repository. sha256: `patchbot.sh` `daf7d4fb4ad702f2cbe55cc9d3c8dc58a6cb630dc69403a535389200633431f1`, `patchbot.ps1`
  `fd934bbec566b876b93e9adc81c32c556e6e57688b6462ed7da291ecd593f333`.

## [0.2.0] - 2026-09-23

- **Breaking (external fact consumers):** `facts.d/patchbot.sh`'s apt, dnf, and yum
  branches no longer emit the `patches[]` array (`{"id","severity","security"}`).
  All three now emit `packages[]` (`{"name","arch","current","available","repo",
  "security"}`), carrying real installed/available version and repo/suite data
  instead of a bare identifier + approximated severity. Any external consumer of
  the retired `patches[]` shape (PuppetDB queries, third-party reporting) must
  move to `packages[]`. Puppet Stagehand Console's own read side
  (`patchFactPackages`) already accepts both shapes, preferring `packages[]` and
  falling back to `patches[]` for nodes still running a pre-0.2.0 module — see
  puppet-console phase 999.47 (`packages-tab-version-and-installation-source`).
- dnf/yum's installed (`current`) version now comes from one batched `rpm -q`
  lookup per fact run (`rpm_installed_versions`/`rpm_installed_version_for`),
  not `check-update`'s candidate-version column, and not one `rpm -q` per
  pending package.
- Package names are validated (`pkgname_is_safe`) against the same
  `[A-Za-z0-9][A-Za-z0-9._:+-]*` token shape `tasks/patch.sh`'s `patch_ids`
  validation already enforces, before reaching `rpm`'s argv.
- Severity is no longer tracked as a separate field; only the `security`
  boolean survives.
- The Windows fact (`facts.d/patchbot.ps1`) is unaffected — it keeps its own
  legacy `patches[]`-shaped KB-entry array.
  (Superseded in 0.3.0: the Windows fact no longer emits `patches[]`. See the
  0.3.1 notes above for the replacement `missing[]` shape.)

## [0.1.0] - 2026-08-20

- refactor: rename pcm module to stagehand (puppetlabs-stagehand) (2a33ade)
- feat: extract trivy/openscap/patchbot; patchbot Package Updates + Windows Update (b367ddd)
- fix(patchbot): argument injection via patch_ids in patch.sh (b0e3606)
- test(02-01): add failing test for patch.sh JSON-on-fail and sensitive-param contract (f045495)
- feat(02-01): patch.sh embeds JSON on business-logic failure, patch.json marks ingest_token sensitive and input_method both (2e49529)
- test(02-01): add Pester coverage for patch.ps1 (RED, unexecuted — no local pwsh) (b441acd)
- feat(02-01): patch.ps1 emits FailJson on business-logic failure (unexecuted locally — verified on Windows/pwsh host via Task 3's checkpoint) (e1dd5cf)
- fix(patchbot,trivy,openscap,inspector): correct metadata.json/README to unified stagehand Forge author + puppet-stagehand org (SPLIT-01, D-16/D-17/D-18, supersedes D-02) (e592c49)
