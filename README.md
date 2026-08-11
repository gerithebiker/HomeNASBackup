# Synology → WD Music Backup

Automated and interactive backup system for mirroring a music library from a
Synology NAS to a WD My Cloud NAS.

The system handles the complete backup lifecycle:

- powers on the WD NAS through a Shelly smart plug
- waits for the WD network, system services, and NFS export
- mounts the WD NFS filesystem
- mirrors the music library using `rsync`
- performs a second dry-run verification pass
- safely unmounts the NFS filesystem
- shuts down the WD using its native `shutdown.sh`
- waits until power consumption confirms shutdown
- switches off the Shelly
- logs all operations
- supports both interactive and unattended operation
- sends a concise backup report using Synology Task Scheduler email notifications

The backup destination is normally powered off and is only started when a
backup is required.

---

## Architecture

```text
                         ┌─────────────────────┐
                         │      Synology       │
                         │                     │
                         │   Music Library     │
                         └──────────┬──────────┘
                                    │
                                    │ rsync / NFS
                                    ▼
                         ┌─────────────────────┐
                         │    WD My Cloud      │
                         │                     │
                         │   Backup Storage    │
                         └──────────┬──────────┘
                                    │
                              power control
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │       Shelly        │
                         │    Smart Plug       │
                         └─────────────────────┘
```

The Synology controls the complete lifecycle of the WD backup NAS.

---

## Components

### `musicbackup`

Interactive frontend for manually starting and managing a backup.

Designed for use from a terminal and provides colored status output.

### `musicbackup-auto`

Non-interactive backup orchestrator intended for Synology Task Scheduler.

It performs the complete sequence:

```text
WD start
   ↓
wait for network
   ↓
wait for WD services
   ↓
wait for NFS export
   ↓
backup
   ↓
verification
   ↓
unmount
   ↓
WD shutdown
   ↓
wait for low power state
   ↓
Shelly off
```

Detailed runtime output is redirected to log files. Only a concise final report
is written to stdout so Synology Task Scheduler can send a clean email report.

Example:

```text
================ Backup Report ===============
Status:          SUCCESS
WD startup:      PASSED
Backup:          PASSED
WD shutdown:     PASSED
Backup runtime:  00:04:00
Total runtime:   00:06:15
==============================================
Automatic WD music backup completed successfully.
```

### `synology_to_wd_music_backup.sh`

Performs the actual music-library synchronization.

Features include:

- NFS mount validation
- destination safety marker
- `rsync` mirror synchronization
- configurable excludes
- deletion of files removed from the source
- post-copy verification
- detailed logging
- dry-run mode
- lock directory preventing concurrent backups
- automatic cleanup/unmount

The verification pass runs a second `rsync --dry-run` after synchronization.
A successful backup therefore means that no pending synchronization changes
remain.

### `wd-start`

Starts the WD backup NAS.

It:

1. powers on the Shelly
2. waits for the WD to appear on the network
3. waits for SSH/system services
4. waits for the NFS export to become available

The NFS check is important because the WD may perform filesystem maintenance
during boot even though networking and SSH are already available.

Long waits periodically print status information instead of appearing frozen.

### `wd-stop`

Safely shuts down the WD backup NAS.

It:

1. verifies Shelly state
2. checks WD power consumption
3. unmounts WD NFS filesystems from the Synology
4. executes the WD native `/usr/sbin/shutdown.sh`
5. waits for power consumption to fall below the configured shutdown threshold
6. switches off the Shelly

Using the WD native `shutdown.sh` is intentional. Direct `poweroff` caused the
WD filesystem to require filesystem checks on subsequent boots.

### `wd-ssh`

SSH wrapper used to execute commands on the WD.

It uses a defined `known_hosts` file so it behaves consistently both
interactively and when executed as root by Synology Task Scheduler.

### `bigShelly`

Controls and queries the Shelly smart plug.

Typical commands:

```bash
bigShelly on
bigShelly off
bigShelly status
bigShelly state
```

`state` provides a machine-readable `ON` / `OFF` result for scripts.

### `mbStatus`

Displays backup-system status and information about the most recent backup.

### `musicbackup-lib.sh`

Shared function library used by the backup scripts.

Common functionality lives here rather than being duplicated between scripts.

Terminal colors are automatically enabled only when stdout is connected to a
TTY:

```bash
[[ -t 1 ]]
```

As a result:

```text
interactive terminal → colored output
redirected output    → plain text
log files            → plain text
Task Scheduler       → plain text
email                → plain text
```

No special `--plain` mode is required.

---

## Configuration

System-wide configuration is stored in:

```text
/etc/musicbackup.conf
```

Machine-specific settings belong in this file rather than in the individual
scripts.

Typical configuration includes:

```bash
SOURCE="/volume1/music/"

WD_HOST="192.168.1.210"
WD_EXPORT="/nfs/WDMusic"

MOUNT_POINT="/volume1/WD_NAS/Music"
DEST_SUBDIR="/"

NFS_OPTIONS="vers=3,tcp,nolock,rw,hard,timeo=600,retrans=2"

TARGET_MARKER=".wd_music_backup_target"

LOG_DIR="/volume1/WD_NAS/BackupLogs"
LOCK_DIR="/tmp/wd-music-backup.lock"

WD_START="/var/services/homes/<user>/bin/wd-start"
WD_STOP="/var/services/homes/<user>/bin/wd-stop"
BACKUP_SCRIPT="/var/services/homes/<user>/bin/synology_to_wd_music_backup.sh"
LIB_FILE="/var/services/homes/<user>/bin/musicbackup-lib.sh"

SSH_KNOWN_HOSTS="/var/services/homes/<user>/.ssh/known_hosts"
```

Additional timeout, Shelly, SSH, power-threshold, and exclude settings may also
be defined here.

**Do not commit a real configuration file containing passwords, tokens, IP
addresses, or other private credentials.**

A sanitized example such as `musicbackup.conf.example` is recommended.

---

## Backup Excludes

The backup supports configurable rsync exclusions.

Example:

```bash
EXCLUDES=(
    "@eaDir/"
    "#recycle/"
    ".DS_Store"
    "Thumbs.db"
    ".rsync-partial/"
)
```

Site-specific patterns can be added as required.

---

## Safety

Several protections are built into the system.

### Destination marker

The WD backup export must contain:

```text
.wd_music_backup_target
```

Before synchronization begins, the script verifies that this marker exists.

This prevents an `rsync --delete` operation from accidentally targeting the
wrong filesystem.

### Mount validation

The script verifies that the expected NFS export is actually mounted at the
configured mount point.

### Backup lock

A lock directory prevents two backup jobs from running simultaneously.

### Graceful shutdown

The WD is never intentionally disconnected from power while still running.

The shutdown sequence waits until Shelly power monitoring indicates that the WD
has reached its powered-down state before cutting AC power.

---

## Manual Usage

Interactive backup:

```bash
musicbackup
```

Direct backup script:

```bash
sudo synology_to_wd_music_backup.sh
```

Preview without modifying the destination:

```bash
sudo synology_to_wd_music_backup.sh --dry-run
```

Automatic wrapper test:

```bash
sudo musicbackup-auto
```

---

## Scheduled Backups

The unattended backup is designed for Synology DSM Task Scheduler.

Create a **Scheduled Task → User-defined script** and run it as:

```text
root
```

Command:

```bash
/var/services/homes/<user>/bin/musicbackup-auto
```

Root execution is required for operations such as NFS mounting and Shelly power
control.

Enable:

```text
Send run details by email
```

Because `musicbackup-auto` sends detailed output to log files and writes only
its final report to stdout, the resulting Task Scheduler email remains concise
and useful.

---

## Logging

Detailed backup logs are stored under the configured `LOG_DIR`.

Typical files:

```text
wd_music_backup_YYYY-MM-DD_HH-MM-SS.log
wd_music_verify_YYYY-MM-DD_HH-MM-SS.txt
musicbackup_auto_YYYY-MM-DD_HH-MM-SS.log
```

The files serve different purposes:

- `wd_music_backup_*` — detailed synchronization log
- `wd_music_verify_*` — post-backup verification result
- `musicbackup_auto_*` — WD startup/shutdown and orchestration log

Old logs can be removed automatically according to the configured retention
period.

---

## Exit Codes

The backup script uses meaningful exit codes.

```text
0   Backup completed successfully and verification passed
1   Setup, mount, rsync, shutdown, or other operational error
2   Post-copy verification detected pending differences
```

The automatic wrapper reports individual startup, backup, and shutdown status
and returns a non-zero result if the complete backup lifecycle was not
successful.

---

## Troubleshooting

### WD is reachable but backup waits during startup

This may be normal.

The WD can respond to the network and SSH before its NFS filesystem is ready,
especially while performing a filesystem check.

`wd-start` therefore waits separately for:

```text
network → services → NFS export
```

### Stale NFS mount / Input/output error

If the WD is powered down while an NFS filesystem remains mounted, the Synology
may show entries such as:

```text
d?????????? Music
```

or:

```text
Input/output error
```

Check existing WD mounts:

```bash
mount | grep '/volume1/WD_NAS'
```

Unmount stale filesystems before attempting to reuse the mount point.

### SSH works as a normal user but fails from Task Scheduler

Task Scheduler runs the automatic backup as root.

Root normally uses a different SSH `known_hosts` database. The `wd-ssh`
wrapper therefore explicitly specifies the configured known-hosts file.

### WD performs filesystem checks after every backup

Do not replace the WD native shutdown mechanism with a raw `poweroff`.

The working shutdown sequence uses:

```text
sync
/usr/sbin/shutdown.sh
```

and waits for the measured power consumption to indicate completion before the
Shelly cuts power.

---

## Design Philosophy

The system intentionally separates responsibilities:

```text
configuration       → /etc/musicbackup.conf
shared functions    → musicbackup-lib.sh
power-up            → wd-start
synchronization     → synology_to_wd_music_backup.sh
power-down          → wd-stop
interactive control → musicbackup
automation          → musicbackup-auto
status              → mbStatus
```

Scripts do not need to know whether they are being run interactively, redirected
to a file, or executed by Task Scheduler. Shared functionality determines the
appropriate behavior automatically wherever possible.

The WD backup NAS remains offline when it is not needed and is powered only for
the duration of a backup.

---

## License

Free to use and modify with attribution.
