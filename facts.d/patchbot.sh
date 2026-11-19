#!/bin/sh
# patchbot — external fact (facts.d, pluginsynced from the patchbot module).
# Patch posture the console reads (Patching page + Action Center). Schema version 2: the same keys as
# adapters/stagehand/facts.d/patchbot.sh, published as docs/schemas/patchbot-fact-v2.schema.json and described in
# docs/design/patch-fact-schema.md:
#   {"patchbot": {"schema_version": 2, "available": N, "security": N, "reboot_required": bool,
#                 "reboot_status": "required|not_required|unknown", "reboot_status_reason": "<fixed code>",
#                 "last_checked": "<ISO8601 UTC>", "manager": "apt|dnf|yum|",
#                 "repos": ["<suite or repo id>", ...],
#                 "packages": [{"name","arch","current","available","repo","security"}, ...],
#                 "package_count": N, "truncated": bool}}
#   dnf also reports "status" (ok | check_failed) and, when the check could not run, "check_error" (a fixed code): dnf is the one
#   manager whose check-update exit codes are verified.
#   (apt, dnf and yum all emit this shape as of 999.47-03. See 999.47-01 for
#   apt, 999.47-03 for dnf/yum -- the three branches converged onto one
#   shape via shared add_package/json_escape/rpm_installed_versions helpers
#   rather than each formatting its own JSON.)
#
# `reboot_status` is a three-state answer decided by the shared block below. That block is byte-identical to the ones in
# adapters/stagehand/facts.d/patchbot.sh and adapters/stagehand/tasks/patch.sh, and a Go test keeps all three the same. Unknown means
# this node cannot tell (the tool that reports it is missing or failed, or no supported package manager is present); it is never
# reported as not_required. `reboot_required` is kept for readers of version 1 and is true only when reboot_status is required. A
# fact without schema_version is version 1.
#
# Cost note: this fact is per-node state in PuppetDB, so the package list is capped (PCM_PATCH_MAX_PACKAGES, default 500) and
# `truncated` reports when it bites. The counts and package_count stay exact; only the detail array is capped.
#
# Structured JSON output requires Facter 4 (ships with Puppet 8 — OpenVox,
# Puppet Core, and PE all qualify).
#
# `packages[]` backs the console's per-patch picker (Windows Update screen
# today; nothing here is Windows-specific) and the Patching > Packages tab's
# version/source columns. Entries carry name, arch, current (installed)
# version, available version, repo/suite and a security boolean -- adopted
# from adapters/stagehand/facts.d/patchbot.sh's already-documented shape
# (D-02, 2026-09-23 design: docs/superpowers/specs/2026-09-23-patching-package-version-source-design.md)
# rather than inventing a third shape on top of the legacy "deliberately
# id+severity+security only" `patches[]` array. dnf/yum's `current` (the
# installed version) comes from a second, batched `rpm -q` lookup
# (rpm_installed_versions) since `check-update` only reports the candidate
# version -- one process invocation per fact run, not one per pending
# package (T-999.47-11).
#
# `patches[]` is no longer emitted by any branch of this script. The
# console's read side (patchFactPackages, backend/internal/httpapi/patching.go)
# still tries "packages" first and falls back to "patches" -- that fallback
# is the degradation path for any node still running a pre-999.47 copy of
# this module during rollout (spec section 7), not dead code to delete.
#
# Severity is no longer tracked as a separate field for the packages[] shape
# -- only the "security" boolean survives (D-02). Linux package managers
# don't cleanly expose per-package severity the way Windows' WUA does (see
# facts.d/patchbot.ps1) without heavier tooling (debsecan, dnf5's richer
# API) this module deliberately doesn't pull in. A package is
# `security: true` if the package manager's own security-update channel (or
# advisory list) flags it; everything else is `security: false`.
#
# Split out of the stagehand module into its own patchbot module (2026-08-18);
# originally renamed from the legacy `patches` fact at the pcm/stagehand cutover
# (2026-07-21).
# Deploy: patchbot/facts.d via pluginsync once patchbot is in the environment
# modulepath, or drop into /etc/puppetlabs/facter/facts.d/ (chmod 755).
set -u

# The package cap. A non-numeric value falls back to the default rather than breaking the comparison below.
LIMIT=${PCM_PATCH_MAX_PACKAGES:-500}
case "$LIMIT" in
  ''|*[!0-9]*) LIMIT=500 ;;
esac

AVAILABLE=0
SECURITY=0
TOTAL=0
# REBOOT_STATUS and REBOOT_REASON come from detect_reboot_status (the shared block below); the boolean is derived from the status in
# one place, further down. The defaults are the cannot-tell answer, so a path that forgot to ask never says "no".
REBOOT_STATUS=unknown
REBOOT_REASON=no_package_manager
MANAGER=""
PACKAGES=""
PKG_LISTED=0
REPOS=""
# status: ok = the check ran and the numbers are real (zero included); check_failed = it could not run, so the numbers say nothing
# about the node. check_error names why, from a fixed set, never raw command output. Only dnf claims a status (verified exit codes).
STATUS=ok
CHECK_ERROR=""

# BEGIN reboot_status
# Reboot-pending detection shared by tasks/patch.sh and facts.d/patchbot.sh. A
# test keeps the two copies byte-identical: change both or neither.
#
# detect_reboot_status MANAGER   (MANAGER is apt, dnf, yum or anything else)
# sets REBOOT_STATUS and REBOOT_REASON:
#   REBOOT_STATUS  required | not_required | unknown   (unknown is never "no")
#   REBOOT_REASON  marker_present | marker_absent | no_marker_writer |
#                  needs_restarting | plugin_missing | needs_restarting_failed |
#                  no_package_manager
# PATCHBOT_REBOOT_MARKER and PATCHBOT_MARKER_WRITER override the apt paths and
# exist for tests only.
detect_reboot_status() {
  REBOOT_STATUS="unknown"
  REBOOT_REASON="no_package_manager"
  case "${1:-}" in
    apt)
      if [ -f "${PATCHBOT_REBOOT_MARKER:-/var/run/reboot-required}" ]; then
        REBOOT_STATUS="required"
        REBOOT_REASON="marker_present"
      elif [ -x "${PATCHBOT_MARKER_WRITER:-/usr/share/update-notifier/notify-reboot-required}" ]; then
        # A writer is installed, so the marker's absence is meaningful.
        REBOOT_STATUS="not_required"
        REBOOT_REASON="marker_absent"
      else
        # Nothing on this node would ever write the marker: cannot tell.
        REBOOT_REASON="no_marker_writer"
      fi
      ;;
    dnf)
      # dnf4 plugin / dnf5: exit 0 = no reboot needed; exit 1 WITH output = a
      # reboot is required; exit 1 with NO output is dnf4 saying "No such
      # command" because the plugin is not installed; any other exit (dnf5
      # reports an unknown argument as 2) means the probe itself failed. The
      # text of the output is never parsed: it is locale dependent.
      _nr_out=$(dnf -q needs-restarting -r 2>/dev/null)
      _nr_rc=$?
      case "$_nr_rc" in
        0)
          REBOOT_STATUS="not_required"
          REBOOT_REASON="needs_restarting"
          ;;
        1)
          if [ -n "$_nr_out" ]; then
            REBOOT_STATUS="required"
            REBOOT_REASON="needs_restarting"
          else
            REBOOT_REASON="plugin_missing"
          fi
          ;;
        *) REBOOT_REASON="needs_restarting_failed" ;;
      esac
      ;;
    yum)
      # yum hosts carry no dnf plugin; the standalone needs-restarting (from
      # yum-utils) answers with exit 0 (no) or 1 (yes). Absent: cannot tell.
      if command -v needs-restarting >/dev/null 2>&1; then
        needs-restarting -r >/dev/null 2>&1
        _nr_rc=$?
        case "$_nr_rc" in
          0)
            REBOOT_STATUS="not_required"
            REBOOT_REASON="needs_restarting"
            ;;
          1)
            REBOOT_STATUS="required"
            REBOOT_REASON="needs_restarting"
            ;;
          *) REBOOT_REASON="needs_restarting_failed" ;;
        esac
      else
        REBOOT_REASON="plugin_missing"
      fi
      ;;
    *) : ;;
  esac
}
# END reboot_status


# json_escape backslash-and-quote-escapes a value before it is interpolated
# into emitted JSON (T-999.47-01: suite/version/arch strings, unlike the bare
# package names the legacy add_patch call trusted, are less tightly
# controlled). Mirrors adapters/stagehand/facts.d/patchbot.sh's esc()
# (backslash substitution before quote substitution, same order).
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Appends one {"name","arch","current","available","repo","security"} object
# to $PACKAGES. Used by all three branches (apt: 999.47-01; dnf/yum:
# 999.47-03). Every string field is routed through json_escape first.
add_package() {
  # The detail list is capped (PCM_PATCH_MAX_PACKAGES): past the cap an entry is dropped, never the count, so package_count and the
  # top-level counts stay exact and `truncated` says the list is partial.
  [ "$PKG_LISTED" -lt "$LIMIT" ] || return 0
  PKG_LISTED=$((PKG_LISTED + 1))
  _name=$(json_escape "$1")
  _arch=$(json_escape "$2")
  _cur=$(json_escape "$3")
  _avail=$(json_escape "$4")
  _repo=$(json_escape "$5")
  _sec="$6"
  _entry="{\"name\": \"${_name}\", \"arch\": \"${_arch}\", \"current\": \"${_cur}\", \"available\": \"${_avail}\", \"repo\": \"${_repo}\", \"security\": ${_sec}}"
  if [ -z "$PACKAGES" ]; then
    PACKAGES="$_entry"
  else
    PACKAGES="${PACKAGES}, ${_entry}"
  fi
}

# pkgname_is_safe validates that NAME is a plain package-name token before it
# reaches rpm's argv (T-999.47-09, same argument-injection class the
# patchbot patch task's own patch_ids validation already fixed --
# tasks/patch.sh's `[A-Za-z0-9][A-Za-z0-9._:+-]*` shape). A name containing
# whitespace or a leading dash would otherwise split into extra argv entries
# or be read as an rpm flag. A name that fails this check is simply skipped
# -- it never reaches rpm_installed_versions, so it contributes no "current"
# value, which the collapse rule already treats as an empty-tuple
# contributor rather than a fatal error.
pkgname_is_safe() {
  case "$1" in
    '') return 1 ;;
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._:+-]*) return 1 ;;
  esac
  return 0
}

# rpm_installed_versions NAMES...
#
# Runs exactly ONE `rpm -q` invocation across every pending package name,
# emitting one "name version" line per name rpm recognizes on stdout. This
# is the mitigation for the open risk spec section 9 records (T-999.47-11):
# the naive shape is one `rpm -q` per pending package, which on a node with
# hundreds of pending updates is the place fact-collection time noticeably
# grows -- batching it into one invocation makes the cost constant instead
# of linear in the number of pending packages. Names are passed after `--`
# (T-999.47-09) and stderr is discarded so an unrecognized name does not
# abort the run.
rpm_installed_versions() {
  [ "$#" -gt 0 ] || return 0
  rpm -q --queryformat '%{NAME} %|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}\n' -- "$@" 2>/dev/null
  return 0
}

# rpm_installed_version_for NAME TABLE
#
# Resolves NAME against the "name version" TABLE rpm_installed_versions
# produced, returning the first match on stdout. A multilib pair (i686 and
# x86_64 reported as two lines for the same name) would otherwise double the
# emitted entry count -- taking the first keeps exactly one entry per
# check-update line. Prints nothing (empty "current") when NAME is absent
# from TABLE.
rpm_installed_version_for() {
  printf '%s\n' "$2" | awk -v name="$1" '$1 == name { print $2; exit }'
}

# security_names: reads `updateinfo list security` rows on stdin, prints the exact package names they name, sorted and unique, one per
# line. An advisory row ends with a NEVRA (name-[epoch:]version-release.arch); dropping the .arch and the last two hyphen fields leaves
# the exact name, so an advisory for curl-minimal is never taken for one for curl, and a package under several advisories or builds
# appears once. The awk body is the adapters copy's nevra_name (adapters/stagehand/facts.d/patchbot.sh, SEC_AWK). The rows go in on
# stdin, never through `awk -v`: BSD awk (macOS, where the harness runs) rejects a multi-line -v value.
security_names() {
  awk '
    function nevra_name(s,   n, parts, i) {
      sub(/\.[^.-]+$/, "", s)               # drop .arch
      n = split(s, parts, "-")
      if (n < 3) return s
      s = parts[1]; for (i = 2; i <= n - 2; i++) s = s "-" parts[i]
      return s
    }
    NF >= 3 { print nevra_name($NF) }' | sort -u
}

if command -v apt-get >/dev/null 2>&1; then
  # Simulated dist-upgrade: count Inst lines; security = those from a
  # -security suite. Uses the package cache only (no network) — the patchbot
  # patch task and unattended-upgrades keep the cache fresh.
  #
  #   Inst openssl [3.0.2-0ubuntu1.15] (3.0.2-0ubuntu1.18 Ubuntu:24.04/noble-security [amd64])
  #
  # A package pulled in fresh as a dependency has no [current] bracket, so
  # the third field is parsed defensively rather than positionally (ported
  # from adapters/stagehand/facts.d/patchbot.sh's apt awk block, the proven
  # reference implementation of this exact parse).
  MANAGER="apt"
  UPGR=$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst ' || true)
  if [ -n "$UPGR" ]; then
    TOTAL=$(printf '%s\n' "$UPGR" | wc -l | tr -d ' ')
    AVAILABLE=$TOTAL
    SECURITY=$(printf '%s\n' "$UPGR" | grep -ci 'security' || true)
    OLDIFS=$IFS
    IFS='
'
    # Field separator between the five extracted values below: the ASCII
    # Unit Separator (0x1F), not a tab -- POSIX `read` treats IFS tab as
    # whitespace and collapses adjacent delimiters (silently dropping an
    # empty "current" field, e.g. a freshly-pulled dependency with no
    # [current] bracket), which a non-whitespace IFS character does not.
    USEP=$(printf '\037')
    for LINE in $UPGR; do
      FIELDS=$(printf '%s\n' "$LINE" | awk -v usep="$USEP" '
        {
          name = $2
          cur = ""
          if ($3 ~ /^\[/) { cur = $3; gsub(/[][]/, "", cur) }

          p = index($0, "(")
          rest = (p ? substr($0, p + 1) : "")
          split(rest, r, " ")
          avail = r[1]

          # Origins look like "Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security".
          # Take the suite of the first one as the repo.
          repo = ""
          if (match(rest, /\/[A-Za-z0-9._-]+/)) {
            repo = substr(rest, RSTART + 1, RLENGTH - 1)
          }

          arch = ""
          if (match(rest, /\[[A-Za-z0-9_-]+\][)]?[ ]*$/)) {
            arch = substr(rest, RSTART + 1, RLENGTH - 1)
            gsub(/[])] */, "", arch)
          }

          printf "%s%s%s%s%s%s%s%s%s", name, usep, cur, usep, avail, usep, repo, usep, arch
        }')
      [ -n "$FIELDS" ] || continue
      IFS="$USEP" read -r PKG_NAME PKG_CUR PKG_AVAIL PKG_REPO PKG_ARCH <<PKGFIELDS
$FIELDS
PKGFIELDS
      [ -n "$PKG_NAME" ] || continue
      # Security determination stays byte-for-byte the legacy behavior: a
      # case-insensitive "security" match against the WHOLE Inst line, not
      # adapters/stagehand's stricter "-security"-suite-only match (that is a
      # different fleet-wide security count and out of scope here).
      if printf '%s\n' "$LINE" | grep -qi 'security'; then
        add_package "$PKG_NAME" "$PKG_ARCH" "$PKG_CUR" "$PKG_AVAIL" "$PKG_REPO" "true"
      else
        add_package "$PKG_NAME" "$PKG_ARCH" "$PKG_CUR" "$PKG_AVAIL" "$PKG_REPO" "false"
      fi
    done
    IFS=$OLDIFS
  fi

  # Configured suites, from the resolved policy rather than sources.list, so pinning and deb822 sources are both accounted for.
  REPOS=$(apt-cache policy 2>/dev/null \
    | grep -o 'a=[A-Za-z0-9._-]*' | cut -d= -f2 \
    | grep -v '^now$' | sort -u \
    | awk '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }')

  # The reboot-required marker, read through the shared block. A node with no marker and nothing installed that would ever write
  # one reports unknown rather than "no".
  detect_reboot_status apt

elif command -v dnf >/dev/null 2>&1; then
  # `check-update -q` exits 100 with a package list when updates exist:
  #   openssl.x86_64  1:3.2.2-6.el9_5  rhel-9-appstream
  # Column 2 is the CANDIDATE (available) version, not the installed one --
  # check-update never reports what's currently installed, so the batched
  # rpm_installed_versions lookup below is what makes `current` true
  # (D-02, spec S4). NF>=3 drops a wrapped two-line check-update entry (a
  # pre-existing limitation this plan does not change). The LIST filter also
  # drops a `Last metadata expiration` line and any row whose first field has
  # no dot, and it stops reading at an `Obsoleting Packages` header: every row
  # under that header (the replacing package and its indented replaced
  # package) is a replacement, not a pending update, and the replaced row has
  # a dot and three fields, so a per-row test alone would count it.
  MANAGER="dnf"
  # Capture the exit codes the old pipelines discarded: `check-update` exits 0 with nothing pending, 100 with updates pending, and
  # anything else when it could not run (AlmaLinux 8.10 exits 1 when repo metadata is unreachable). Without this a failed check
  # printed exactly what a fully patched host prints. Only dnf's exit codes are verified, so only dnf reports a status.
  CHECK_OUT=$(dnf -q check-update 2>/dev/null)
  CHECK_RC=$?
  case "$CHECK_RC" in
    0|100) ;;
    *) STATUS=check_failed; CHECK_ERROR=metadata_unavailable ;;
  esac
  LIST=$(printf '%s\n' "$CHECK_OUT" | awk '/^Obsoleting/ {exit} NF>=3 && $1 !~ /^Last/ && $1 ~ /\./ {print}' || true)
  # Security advisories name their packages as full NEVRA, one row per advisory per package build. If this lookup fails the update
  # list is real but every security flag would silently be false, so a failure here fails the whole check too.
  SEC_OUT=$(dnf -q updateinfo list security --available 2>/dev/null)
  SEC_RC=$?
  if [ "$SEC_RC" -ne 0 ] && [ "$STATUS" = ok ]; then
    STATUS=check_failed; CHECK_ERROR=package_manager_error
  fi
  # The exact names the advisories name (see security_names). `security` is NOT a count of these rows: one package can sit under
  # several advisories and builds. It is the number of distinct pending updates whose exact name is in this set, counted over the
  # WHOLE list in pass 2 below (the detail list may be capped, the count is not), so it can never exceed `available`.
  SECNAMES=$(printf '%s\n' "$SEC_OUT" | security_names)
  SEC_COUNT=0
  if [ -n "$LIST" ] && [ "$STATUS" = ok ]; then
    TOTAL=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
    AVAILABLE=$TOTAL
    OLDIFS=$IFS
    IFS='
'
    # Pass 1: collect every pending package's bare name (arch stripped via
    # the branch's existing name.arch trailing-component convention),
    # validated by pkgname_is_safe (T-999.47-09) before it can reach rpm's
    # argv. An invalid name is skipped, not aborted -- see pkgname_is_safe.
    NAMES=""
    NAMES_SEEN=0
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      # Only the entries that will be listed are looked up: a capped list does not cost a full rpm lookup.
      [ "$NAMES_SEEN" -lt "$LIMIT" ] || break
      NAMES_SEEN=$((NAMES_SEEN + 1))
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      NAME=${NAMEARCH%.*}
      if pkgname_is_safe "$NAME"; then
        NAMES="${NAMES}${NAMES:+ }${NAME}"
      fi
    done
    # shellcheck disable=SC2086 # intentional word-splitting: NAMES is a
    # space-joined list of already-validated (pkgname_is_safe) tokens, and
    # this is the ONE batched rpm -q call (T-999.47-11) rather than one per
    # package.
    RPM_TABLE=$(rpm_installed_versions $NAMES)

    # Pass 2: one packages[] entry per check-update line. An entry is flagged when its exact name is one an advisory names (whole-line
    # fixed-string match: a name is data, never a pattern or an option). The walk covers the WHOLE list; add_package drops entries
    # past the cap, SEC_COUNT does not.
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      AVAIL=$(printf '%s\n' "$ENTRY" | awk '{print $2}')
      REPO=$(printf '%s\n' "$ENTRY" | awk '{print $3}')
      NAME=${NAMEARCH%.*}
      ARCH=${NAMEARCH##*.}
      CUR=$(rpm_installed_version_for "$NAME" "$RPM_TABLE")
      if [ -n "$NAME" ] && printf '%s\n' "$SECNAMES" | grep -qxF -- "$NAME"; then
        SEC_COUNT=$((SEC_COUNT + 1))
        add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true"
      else
        add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "false"
      fi
    done
    IFS=$OLDIFS
    SECURITY=$SEC_COUNT
  fi

  REPOS=$(dnf -q repolist --enabled 2>/dev/null \
    | awk 'NR>1 && NF>=1 && $1 !~ /^repo[ -]?id/ {print $1}' \
    | sort -u | awk '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }')

  # The reboot answer comes from the shared block (`dnf needs-restarting -r`). A host without the plugin (dnf4 exits 1 with no
  # output) reports unknown, never "no" and never "required". needs-restarting does not depend on repository metadata, so the answer
  # is valid even when the update check above failed.
  detect_reboot_status dnf

elif command -v yum >/dev/null 2>&1; then
  # Same shape as the dnf branch above, reusing rpm_installed_versions,
  # rpm_installed_version_for, pkgname_is_safe, add_package, json_escape and
  # the shared exact-name rule (security_names, counted once per pending
  # update over the whole list) rather than duplicating any of them. The
  # yum-specific differences from the dnf branch are: `yum -q updateinfo list
  # security` without --available, and the bare needs-restarting reboot probe
  # (not `yum -q needs-restarting`). The LIST filter is the same as dnf's: yum
  # prints the same `Obsoleting Packages` section, whose rows are replacements,
  # not pending updates, so reading stops at its header.
  MANAGER="yum"
  LIST=$(yum -q check-update 2>/dev/null | awk '/^Obsoleting/ {exit} NF>=3 && $1 !~ /^Last/ && $1 ~ /\./ {print}' || true)
  # The exact names the advisories name, and the count of pending updates among them: never advisory rows (see the dnf branch).
  SECNAMES=$(yum -q updateinfo list security 2>/dev/null | security_names)
  SEC_COUNT=0
  if [ -n "$LIST" ]; then
    TOTAL=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
    AVAILABLE=$TOTAL
    OLDIFS=$IFS
    IFS='
'
    NAMES=""
    NAMES_SEEN=0
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      # Only the entries that will be listed are looked up: a capped list does not cost a full rpm lookup.
      [ "$NAMES_SEEN" -lt "$LIMIT" ] || break
      NAMES_SEEN=$((NAMES_SEEN + 1))
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      NAME=${NAMEARCH%.*}
      if pkgname_is_safe "$NAME"; then
        NAMES="${NAMES}${NAMES:+ }${NAME}"
      fi
    done
    # shellcheck disable=SC2086 # intentional word-splitting: NAMES is a
    # space-joined list of already-validated (pkgname_is_safe) tokens, and
    # this is the ONE batched rpm -q call (T-999.47-11) rather than one per
    # package.
    RPM_TABLE=$(rpm_installed_versions $NAMES)

    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      AVAIL=$(printf '%s\n' "$ENTRY" | awk '{print $2}')
      REPO=$(printf '%s\n' "$ENTRY" | awk '{print $3}')
      NAME=${NAMEARCH%.*}
      ARCH=${NAMEARCH##*.}
      CUR=$(rpm_installed_version_for "$NAME" "$RPM_TABLE")
      if [ -n "$NAME" ] && printf '%s\n' "$SECNAMES" | grep -qxF -- "$NAME"; then
        SEC_COUNT=$((SEC_COUNT + 1))
        add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true"
      else
        add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "false"
      fi
    done
    IFS=$OLDIFS
    SECURITY=$SEC_COUNT
  fi

  REPOS=$(yum -q repolist --enabled 2>/dev/null \
    | awk 'NR>1 && NF>=1 && $1 !~ /^repo[ -]?id/ {print $1}' \
    | sort -u | awk '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }')

  # yum hosts carry no dnf plugin; the standalone needs-restarting (yum-utils) answers, read through the shared block. Absent:
  # cannot tell.
  detect_reboot_status yum

# ----------------------------------------------- no supported manager -----
else
  # No apt, dnf or yum on PATH: this node cannot tell, and must not look like a clean one.
  detect_reboot_status ""
fi

TRUNCATED=false
[ "$TOTAL" -gt "$LIMIT" ] && TRUNCATED=true

# The one place the boolean is derived: true only when the status is required (unknown and not_required are both false).
REBOOT=false
[ "$REBOOT_STATUS" = required ] && REBOOT=true
# Only a non-empty reason is written; the key is absent, not empty, when there is none.
REASON_FIELD=""
[ -n "$REBOOT_REASON" ] && REASON_FIELD=", \"reboot_status_reason\": \"$REBOOT_REASON\""

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A check that did not run knows nothing about the node's updates: report no packages and zero counts, never a partial list. The
# reboot answer is the exception: needs-restarting does not depend on repository metadata, so it is reported truthfully even when the
# update check failed.
if [ "$STATUS" != ok ]; then
  printf '{"patchbot": {"schema_version": 2, "status": "%s", "check_error": "%s", "available": 0, "security": 0, "reboot_required": %s, "reboot_status": "%s"%s, "last_checked": "%s", "manager": "%s", "repos": [], "packages": [], "package_count": 0, "truncated": false}}\n' \
    "$STATUS" "$CHECK_ERROR" "$REBOOT" "$REBOOT_STATUS" "$REASON_FIELD" "$NOW" "$MANAGER"
  exit 0
fi

# status is only claimed where the exit codes are verified: the dnf branch. The apt branch captures no exit codes and real yum's are
# unverified, so their output stays without one rather than asserting a status never measured.
STATUS_FIELD=""
case "$MANAGER" in dnf) STATUS_FIELD='"status": "ok", ' ;; esac

# All three branches (apt, dnf, yum) build $PACKAGES (999.47-03); a node with no supported package manager on PATH gets this shape
# too, with an empty packages[] array and an empty manager. The legacy patches[] shape is no longer emitted by this script;
# patchFactPackages's fallback to "patches" (backend/internal/httpapi/patching.go) remains the only thing that still knows it, as
# the degradation path for any node still running a pre-999.47 copy of this module during rollout (spec section 7).
printf '{"patchbot": {"schema_version": 2, %s"available": %s, "security": %s, "reboot_required": %s, "reboot_status": "%s"%s, "last_checked": "%s", "manager": "%s", "repos": [%s], "packages": [%s], "package_count": %s, "truncated": %s}}\n' \
  "$STATUS_FIELD" "${AVAILABLE:-0}" "${SECURITY:-0}" "$REBOOT" "$REBOOT_STATUS" "$REASON_FIELD" "$NOW" "$MANAGER" \
  "$REPOS" "$PACKAGES" "${TOTAL:-0}" "$TRUNCATED"
