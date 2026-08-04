[CmdletBinding()]
param(
    [string]$OldRoot = (Join-Path $HOME 'Dropbox\Vibe'),
    [string]$NewRoot = $(if ($env:VIBE_ROOT) { $env:VIBE_ROOT } else { Join-Path $HOME 'Vibe' }),
    [string]$CodexHome = (Join-Path $HOME '.codex'),
    [string]$BackupBase = $(Join-Path $(if ($env:VIBE_ROOT) { $env:VIBE_ROOT } else { Join-Path $HOME 'Vibe' }) 'WindowsTuneUp\recovery-manifests'),
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $NewRoot -PathType Container)) {
    throw "The new Vibe root does not exist: $NewRoot"
}

$desktopProcesses = @(Get-Process -Name 'ChatGPT', 'codex', 'codex-code-mode-host' -ErrorAction SilentlyContinue)
if (-not $ReportOnly -and $desktopProcesses.Count -gt 0) {
    $ids = ($desktopProcesses.Id | Sort-Object -Unique) -join ', '
    throw "Codex is still running (process IDs: $ids). Close Codex Desktop and any Codex CLI sessions, then run this script from an ordinary PowerShell window."
}

$configPath = Join-Path $CodexHome 'config.toml'
$globalStatePath = Join-Path $CodexHome '.codex-global-state.json'
$stateDbPath = Join-Path $CodexHome 'state_5.sqlite'
$required = @($configPath, $globalStatePath, $stateDbPath)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required Codex state file was not found: $path"
    }
}

$pythonCommand = Get-Command python -ErrorAction Stop
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$backupDirectory = Join-Path $BackupBase "Codex-Vibe-path-migration-backup_$stamp"

if (-not $ReportOnly) {
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    foreach ($path in @(
        $configPath,
        $globalStatePath,
        (Join-Path $CodexHome '.codex-global-state.json.bak'),
        $stateDbPath,
        (Join-Path $CodexHome 'state_5.sqlite-wal'),
        (Join-Path $CodexHome 'state_5.sqlite-shm')
    )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Copy-Item -LiteralPath $path -Destination $backupDirectory -Force
        }
    }
}

$migrationCode = @'
import argparse
import json
import os
import re
import shutil
import sqlite3
import tempfile
import tomllib

parser = argparse.ArgumentParser()
parser.add_argument('--old', required=True)
parser.add_argument('--new', required=True)
parser.add_argument('--config', required=True)
parser.add_argument('--global-state', required=True)
parser.add_argument('--state-db', required=True)
parser.add_argument('--backup-directory', required=True)
parser.add_argument('--report-only', action='store_true')
args = parser.parse_args()

old = args.old.rstrip('\\/')
new = args.new.rstrip('\\/')

special_mappings = {
    (old + r'\WindowsDiag').lower(): new + r'\WindowsTuneUp',
    (old + r'\2026-04-09 Innsbruckworkshop').lower(): new + r'\Various\2026-04-09 Innsbruckworkshop',
}

def map_path(value):
    if not isinstance(value, str):
        return value
    lowered = value.lower()
    if lowered in special_mappings:
        return special_mappings[lowered]
    if lowered == old.lower():
        return new
    prefix = old.lower() + '\\'
    if lowered.startswith(prefix):
        return new + value[len(old):]
    return value

def atomic_write(path, text):
    directory = os.path.dirname(path)
    fd, temp_path = tempfile.mkstemp(prefix='.codex-vibe-migrate-', dir=directory, text=True)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as handle:
            handle.write(text)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)

def parse_project_header(line):
    stripped = line.strip()
    double_match = re.fullmatch(r'\[projects\."(.*)"\]', stripped)
    if double_match:
        return json.loads('"' + double_match.group(1) + '"')
    single_match = re.fullmatch(r"\[projects\.'(.*)'\]", stripped)
    if single_match:
        return single_match.group(1)
    return None

with open(args.config, 'r', encoding='utf-8') as handle:
    config_lines = handle.readlines()

rewritten_lines = []
seen_projects = set()
mapped_config_projects = 0
deduplicated_projects = 0
i = 0
while i < len(config_lines):
    project_path = parse_project_header(config_lines[i])
    if project_path is None:
        rewritten_lines.append(config_lines[i])
        i += 1
        continue
    j = i + 1
    while j < len(config_lines) and not config_lines[j].lstrip().startswith('['):
        j += 1
    mapped_path = map_path(project_path)
    if mapped_path != project_path:
        mapped_config_projects += 1
    normalized = mapped_path.lower()
    if normalized in seen_projects:
        deduplicated_projects += 1
    else:
        seen_projects.add(normalized)
        rewritten_lines.append("[projects.'" + mapped_path.replace("'", "''") + "']\n")
        rewritten_lines.extend(config_lines[i + 1:j])
    i = j

config_lines_out = ''.join(rewritten_lines).splitlines(keepends=True)
tui_index = next((index for index, line in enumerate(config_lines_out) if line.strip() == '[tui]'), None)
if tui_index is None:
    config_text = ''.join(config_lines_out).rstrip() + '\n\n[tui]\nresume_cwd = "current"\n'
else:
    tui_end = next(
        (index for index in range(tui_index + 1, len(config_lines_out)) if config_lines_out[index].lstrip().startswith('[')),
        len(config_lines_out),
    )
    resume_index = next(
        (index for index in range(tui_index + 1, tui_end) if re.match(r'^\s*resume_cwd\s*=', config_lines_out[index])),
        None,
    )
    if resume_index is None:
        config_lines_out.insert(tui_index + 1, 'resume_cwd = "current"\n')
    else:
        config_lines_out[resume_index] = 'resume_cwd = "current"\n'
    config_text = ''.join(config_lines_out)

# Refuse to write malformed TOML.
tomllib.loads(config_text)

with open(args.global_state, 'r', encoding='utf-8') as handle:
    global_state = json.load(handle)

mapped_global_strings = 0
def transform(value):
    global mapped_global_strings
    if isinstance(value, dict):
        return {key: transform(item) for key, item in value.items()}
    if isinstance(value, list):
        mapped = [transform(item) for item in value]
        if all(isinstance(item, str) for item in mapped):
            unique = []
            seen = set()
            for item in mapped:
                key = item.lower()
                if key not in seen:
                    seen.add(key)
                    unique.append(item)
            return unique
        return mapped
    if isinstance(value, str):
        mapped = map_path(value)
        if mapped != value:
            mapped_global_strings += 1
        return mapped
    return value

new_global_state = transform(global_state)
global_text = json.dumps(new_global_state, ensure_ascii=False, separators=(',', ':'))

connection = sqlite3.connect(args.state_db)
try:
    candidate_rows = connection.execute(
        '''SELECT id, rollout_path, cwd FROM threads
           WHERE lower(substr(cwd, 1, ?)) = lower(?)
              OR lower(substr(cwd, 1, ?)) = lower(?)''',
        (len(old), old, len(new), new),
    ).fetchall()
    old_rows = connection.execute(
        'SELECT id, cwd FROM threads WHERE lower(substr(cwd, 1, ?)) = lower(?)',
        (len(old), old),
    ).fetchall()
    mapped_thread_rows = [(map_path(cwd), thread_id) for thread_id, cwd in old_rows]
    if not args.report_only:
        connection.executemany('UPDATE threads SET cwd = ? WHERE id = ?', mapped_thread_rows)
        connection.commit()
finally:
    connection.close()

rollout_path_keys = {'cwd', 'workdir', 'working_directory'}
rollout_path_list_keys = {'workspace_roots', 'rootPaths'}

def transform_rollout_metadata(value, parent_key=None):
    changed = 0
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            mapped_item, item_changes = transform_rollout_metadata(item, key)
            result[key] = mapped_item
            changed += item_changes
        return result, changed
    if isinstance(value, list):
        result = []
        for item in value:
            mapped_item, item_changes = transform_rollout_metadata(item, parent_key)
            result.append(mapped_item)
            changed += item_changes
        return result, changed
    if isinstance(value, str) and (parent_key in rollout_path_keys or parent_key in rollout_path_list_keys):
        mapped = map_path(value)
        return mapped, int(mapped != value)
    return value, 0

mapped_rollout_files = 0
mapped_rollout_path_values = 0
rollout_backup_directory = os.path.join(args.backup_directory, 'rollouts')

for thread_id, rollout_path, _cwd in candidate_rows:
    normal_path = rollout_path[4:] if rollout_path.startswith('\\\\?\\') else rollout_path
    if not os.path.isfile(normal_path):
        continue
    file_changes = 0
    if args.report_only:
        with open(normal_path, 'r', encoding='utf-8') as source:
            for line in source:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                _mapped_item, line_changes = transform_rollout_metadata(item)
                file_changes += line_changes
    else:
        directory = os.path.dirname(normal_path)
        fd, temp_path = tempfile.mkstemp(prefix='.codex-rollout-migrate-', dir=directory, text=True)
        try:
            with open(normal_path, 'r', encoding='utf-8') as source, os.fdopen(fd, 'w', encoding='utf-8', newline='') as target:
                for line in source:
                    had_newline = line.endswith('\n')
                    try:
                        item = json.loads(line)
                    except json.JSONDecodeError:
                        target.write(line)
                        continue
                    mapped_item, line_changes = transform_rollout_metadata(item)
                    file_changes += line_changes
                    if line_changes:
                        target.write(json.dumps(mapped_item, ensure_ascii=False, separators=(',', ':')))
                        if had_newline:
                            target.write('\n')
                    else:
                        target.write(line)
            if file_changes:
                os.makedirs(rollout_backup_directory, exist_ok=True)
                backup_name = thread_id + '__' + os.path.basename(normal_path)
                shutil.copy2(normal_path, os.path.join(rollout_backup_directory, backup_name))
                os.replace(temp_path, normal_path)
            else:
                os.unlink(temp_path)
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)
    if file_changes:
        mapped_rollout_files += 1
        mapped_rollout_path_values += file_changes

if not args.report_only:
    atomic_write(args.config, config_text)
    atomic_write(args.global_state, global_text)

missing_mapped_projects = sorted(
    path for path in seen_projects
    if path.lower().startswith(new.lower()) and not os.path.isdir(path)
)

print(json.dumps({
    'report_only': args.report_only,
    'mapped_config_projects': mapped_config_projects,
    'deduplicated_project_entries': deduplicated_projects,
    'mapped_global_state_strings': mapped_global_strings,
    'mapped_thread_cwds': len(old_rows),
    'mapped_rollout_files': mapped_rollout_files,
    'mapped_rollout_path_values': mapped_rollout_path_values,
    'missing_mapped_projects': missing_mapped_projects,
    'resume_cwd': 'current',
}, indent=2))
'@

$arguments = @(
    '-',
    '--old', $OldRoot,
    '--new', $NewRoot,
    '--config', $configPath,
    '--global-state', $globalStatePath,
    '--state-db', $stateDbPath,
    '--backup-directory', $backupDirectory
)
if ($ReportOnly) { $arguments += '--report-only' }

$output = $migrationCode | & $pythonCommand.Source @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Codex path migration helper failed with exit code $LASTEXITCODE."
}

$result = $output | ConvertFrom-Json
[pscustomobject]@{
    ReportOnly = [bool]$result.report_only
    OldRoot = $OldRoot
    NewRoot = $NewRoot
    MappedConfigProjects = [int]$result.mapped_config_projects
    DeduplicatedProjectEntries = [int]$result.deduplicated_project_entries
    MappedGlobalStateStrings = [int]$result.mapped_global_state_strings
    MappedThreadWorkingDirectories = [int]$result.mapped_thread_cwds
    MappedRolloutFiles = [int]$result.mapped_rollout_files
    MappedRolloutPathValues = [int]$result.mapped_rollout_path_values
    ResumeCwd = [string]$result.resume_cwd
    MissingMappedProjects = @($result.missing_mapped_projects)
    BackupDirectory = if ($ReportOnly) { '(not created in report-only mode)' } else { $backupDirectory }
}
