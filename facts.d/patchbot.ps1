# patchbot.ps1 -- external fact (facts.d, pluginsynced from the patchbot
# module). Windows counterpart to facts.d/patchbot.sh, schema version 2: the same keys as adapters/stagehand/facts.d/patchbot.ps1
# (published as docs/schemas/patchbot-fact-v2.schema.json, described in docs/design/patch-fact-schema.md):
#   {"patchbot": {"schema_version": 2, "available": N, "security": N, "reboot_required": bool,
#                 "reboot_status": "required|not_required|unknown", "reboot_status_reason": "<fixed code>",
#                 "last_checked": "<ISO8601 UTC>", "manager": "wua", "os_build": "10.0.x.y",
#                 "installed_kbs": ["KB..."], "missing": [{"kbs","title","severity","cve_ids","reboot"}],
#                 "source": "...", "wsus_server": "...|null", "package_count": N, "truncated": bool,
#                 "cache_age_seconds": 0, "cache_stale": false, "cve_ids_populated": bool|null, "scan_error": "...|null"}}
#
# Facter's facts.d loader runs .ps1 scripts directly on Windows (no wrapping
# .bat needed) and, on Linux, simply skips this file (not executable, no
# shebang) -- patchbot.sh and patchbot.ps1 coexist in the same facts.d/ and
# only the platform-appropriate one ever actually runs.
#
# Unlike the adapters fact, which reads a cache written by a scheduled scanner (patchbot_refresh.ps1), this fact scans LIVE with the
# built-in Windows Update Agent (WUA) COM API -- no PSWindowsUpdate module dependency, matching this module's dependency-light design.
# So cache_age_seconds is always 0 and cache_stale is always false: there is no cache. The scan keys (installed_kbs, missing, source,
# wsus_server, cve_ids_populated, scan_error) are built the way patchbot_refresh.ps1 builds them.
#
# `reboot_status` is a three-state answer decided by the shared block below, byte-identical to the one in the adapters fact (a Go test
# keeps them the same). Each probe answers yes, no or error and an error is never read as a no, so a host that cannot tell reports
# unknown. `reboot_required` is kept for readers of version 1 and is true only when reboot_status is required.
#
# `security` is the number of missing updates whose MSRC severity is anything but Unspecified, counted over the whole scan; `missing`
# is capped (PCM_PATCH_MAX_PACKAGES, default 500) and `truncated` says so, while `available` and `package_count` stay exact.
#
# A scan that cannot run (WUA unavailable, WSUS unreachable) never breaks a Puppet run: the fact still prints every key, with zero
# counts, an empty missing list, the reboot answer and scan_error naming the failure.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# The detail cap. A value that is not a positive whole number falls back to the default.
$MaxMissing = 500
$capEnv = 0
if ([int]::TryParse([string]$env:PCM_PATCH_MAX_PACKAGES, [ref]$capEnv) -and $capEnv -gt 0) { $MaxMissing = $capEnv }

function Get-OsBuild {
    # Four-part build: CurrentMajorVersionNumber.CurrentMinorVersionNumber.
    # CurrentBuildNumber.UBR — e.g. 10.0.20348.3328.
    #
    # UBR is the revision that changes with every cumulative update and is the
    # ONLY part that distinguishes a patched host from an unpatched one. It
    # lives in the registry and nowhere else convenient: Facter's os.release
    # stops at the build number, and [Environment]::OSVersion has been
    # shimmed/lying since Windows 8.1. Read the registry.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $cv  = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($null -eq $cv) { return $null }

    $major = $cv.CurrentMajorVersionNumber
    $minor = $cv.CurrentMinorVersionNumber
    if ($null -eq $major) {
        # Pre-Windows 10 (Server 2012 R2 and older) has no
        # CurrentMajorVersionNumber; fall back to the "6.3" style string.
        $parts = ("$($cv.CurrentVersion)").Split('.')
        if ($parts.Count -ge 2) { $major = $parts[0]; $minor = $parts[1] }
        else { return $null }
    }
    $build = $cv.CurrentBuildNumber
    $ubr   = $cv.UBR
    if ($null -eq $ubr) { $ubr = 0 }   # absent on pre-Win10; treat as .0
    return "$major.$minor.$build.$ubr"
}

# BEGIN reboot_status
# Reboot answer, three states. Each probe answers yes, no or error, and an
# error is never read as a no (D-09). The classification below is D-25: any yes
# is required; the CBS and Windows Update probes both answering a definite no is
# not required (the file-rename and SCCM probes only add a yes); otherwise
# unknown with reason probes_failed.
#
# ASSUMED until a Windows host confirms it (RESEARCH A1): a missing registry key
# raises ItemNotFoundException and a denied key raises another exception type,
# as the filesystem provider does. Verified on the filesystem provider only.
function Test-PatchbotProbe([scriptblock]$Probe) {
    try {
        if (& $Probe) { 'yes' } else { 'no' }
    } catch [System.Management.Automation.ItemNotFoundException] {
        'no'
    } catch {
        'error'
    }
}

function Resolve-PatchbotRebootStatus([string]$Cbs, [string]$WindowsUpdate, [string]$FileRename, [string]$Sccm) {
    if (($Cbs, $WindowsUpdate, $FileRename, $Sccm) -contains 'yes') {
        return [pscustomobject]@{ Status = 'required'; Reason = 'pending_reboot_probe' }
    }
    if ($Cbs -eq 'no' -and $WindowsUpdate -eq 'no') {
        return [pscustomobject]@{ Status = 'not_required'; Reason = 'probes_clear' }
    }
    return [pscustomobject]@{ Status = 'unknown'; Reason = 'probes_failed' }
}
# END reboot_status

function Get-RebootStatus {
    # Four independent signals; each is run through Test-PatchbotProbe with
    # -ErrorAction Stop inside its scriptblock, so a probe that could not read
    # the registry answers error and not no.
    $cbs = Test-PatchbotProbe {
        $null = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction Stop
        $true
    }
    $wu = Test-PatchbotProbe {
        $null = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction Stop
        $true
    }
    $fileRename = Test-PatchbotProbe {
        # GetValue returns a plain null when the value is absent, so an absent
        # value is a no and only a failure to open the key is an error.
        $key = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        $v = $key.GetValue('PendingFileRenameOperations')
        ($null -ne $v) -and (@($v).Count -gt 0)
    }

    # SCCM's own opinion, only when the client is actually installed. A missing
    # client is not applicable, not an error.
    $sccm = 'absent'
    if (Get-CimClass -Namespace 'root\ccm\clientsdk' -ClassName 'CCM_ClientUtilities' -ErrorAction SilentlyContinue) {
        $sccm = Test-PatchbotProbe {
            $r = Invoke-CimMethod -Namespace 'root\ccm\clientsdk' -ClassName 'CCM_ClientUtilities' `
                                  -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
            ($null -ne $r) -and ($r.RebootPending -eq $true -or $r.IsHardRebootPending -eq $true)
        }
    }
    return Resolve-PatchbotRebootStatus -Cbs $cbs -WindowsUpdate $wu -FileRename $fileRename -Sccm $sccm
}

function Get-KbList($update) {
    $out = @()
    try {
        foreach ($kb in $update.KBArticleIDs) {
            if ($kb) { $out += ("KB" + ($kb -replace '^KB', '')) }
        }
    } catch { }
    return $out
}

# ---- fast path: no network, no WUA ------------------------------------------
# Neither read may break the run: a build that cannot be read is null, and a reboot answer that cannot be read is unknown.
$osBuild = $null
try { $osBuild = Get-OsBuild } catch { }
$reboot = [pscustomobject]@{ Status = 'unknown'; Reason = 'probes_failed' }
try { $reboot = Get-RebootStatus } catch { }

# ---- live scan --------------------------------------------------------------
$installedKbs = New-Object System.Collections.Generic.HashSet[string]
$missing      = @()
$total        = 0
$securityCount = 0
$source       = 'unknown'
$wsus         = $null
$scanError    = $null
$cveSeen      = $false   # did ANY update expose a non-empty CveIDs?
$cveChecked   = $false   # did we get far enough to look?

try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()

    # Which service are we actually asking? 0=default 1=WSUS 2=Windows Update 3=other. A box pointed at WSUS reports what WSUS has
    # approved, not what Microsoft has published.
    switch ($searcher.ServerSelection) {
        1 { $source = 'wsus' }
        2 { $source = 'windowsupdate' }
        3 { $source = 'other' }
        default { $source = 'default' }
    }
    $wsusKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'WUServer' -ErrorAction SilentlyContinue
    if ($null -ne $wsusKey) { $wsus = [string]$wsusKey.WUServer; if ($source -eq 'default') { $source = 'wsus' } }

    # ---- installed: history first (cheap, local) --------------------------
    try {
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            foreach ($entry in $searcher.QueryHistory(0, $count)) {
                if ($entry.ResultCode -ne 2) { continue }   # 2 = succeeded
                if ($entry.Title -match 'KB(\d{6,})') { [void]$installedKbs.Add("KB" + $Matches[1]) }
            }
        }
    } catch { }

    # ---- installed: searcher view (catches image-baked updates) -----------
    try {
        $inst = $searcher.Search("IsInstalled=1 and Type='Software'")
        foreach ($u in $inst.Updates) { foreach ($kb in (Get-KbList $u)) { [void]$installedKbs.Add($kb) } }
    } catch { }

    # ---- missing: IsHidden=0 matches what a user checking Windows Update manually would see -- dismissed or postponed updates are
    # excluded.
    $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
    $cveChecked = $true
    $total = $result.Updates.Count
    $listed = 0
    foreach ($u in $result.Updates) {
        $sev = $null
        try { if ($u.MsrcSeverity) { $sev = [string]$u.MsrcSeverity } } catch { }
        # Counted over every update, not only the listed ones, so the count stays exact when the detail list is capped.
        if ($sev -and $sev -ne 'Unspecified') { $securityCount++ }

        if ($listed -ge $MaxMissing) { continue }
        $listed++

        # IUpdate2::CveIDs. Reported as a diagnostic rather than assumed: cve_ids_populated answers, with data, whether WUA fills it.
        $cves = @()
        try {
            if ($null -ne $u.CveIDs) {
                foreach ($c in $u.CveIDs) { if ($c) { $cves += [string]$c } }
            }
        } catch { }
        if ($cves.Count -gt 0) { $cveSeen = $true }

        $missing += [ordered]@{
            kbs      = (Get-KbList $u)
            title    = [string]$u.Title
            severity = $sev
            cve_ids  = $cves
            reboot   = [bool]$u.RebootRequired
        }
    }
} catch {
    # Same contract as the shell fact: never break a Puppet run over a patch-posture read failure. Report a zeroed, honest "could not
    # check" state, with the reason, instead of crashing pluginsync'd fact resolution. Nothing half-collected is kept.
    $scanError     = $_.Exception.Message
    $missing       = @()
    $total         = 0
    $securityCount = 0
    $cveChecked    = $false
}

$payload = [ordered]@{
    schema_version  = 2
    available       = $total
    security        = $securityCount
    # Kept for version 1 readers: true only when reboot_status is required.
    reboot_required = ($reboot.Status -eq 'required')
    reboot_status        = $reboot.Status
    reboot_status_reason = $reboot.Reason
    last_checked    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    manager         = 'wua'
    os_build        = $osBuild
    installed_kbs   = @($installedKbs | Sort-Object)
    missing         = $missing
    source          = $source
    wsus_server     = $wsus
    package_count   = $total
    truncated       = ($total -gt $MaxMissing)
    # The scan is live, so there is no cache to age or to go stale.
    cache_age_seconds  = 0
    cache_stale        = $false
    cve_ids_populated  = $(if ($cveChecked) { $cveSeen } else { $null })
    scan_error         = $scanError
}

# -Compress keeps it to one line; Depth 6 covers missing[].cve_ids.
@{ patchbot = $payload } | ConvertTo-Json -Compress -Depth 6
