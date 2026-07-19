// lmw_root_daemon.c — root-started local daemon that performs the privileged
// operations the media-wall player needs on QZX_C1 / YunOS 4.4.2 boxes:
//   * RESTART_APP: force-stop + relaunch ONLY the Player app (the normal
//     controller "restart" — preserves Wi-Fi + device uptime; see WHY below)
//   * INSTALL a downloaded+verified APK via the PackageManager (`pm install -r`)
//     then RESTART_APP so the new version is live WITHOUT a whole-device reboot
//     (self-update). See WHY PM-INSTALL (not /data/app overwrite) below.
//   * REBOOT the whole device — a separate HIGH-RISK advanced action only, never
//     the normal restart (on QZX_C1 a warm reboot loses Wi-Fi until a cold power
//     cycle: the SDIO WCN card fails to re-init — see §restart-semantics)
//
// WHY APP-ONLY RESTART (not whole-device reboot) IS THE NORMAL PATH:
//   Field ground truth on QZX_C1: a warm reboot leaves the SDIO Wi-Fi card
//   un-init'd ("mmc1: error -110 whilst initialising SDIO card"); wlan0 never
//   appears and only a COLD power cycle recovers it. So rebooting to restart the
//   app strands the box off-network. Restarting just the app preserves the live
//   Wi-Fi + uptime. The old app-restart-via-AlarmManager was unreliable (process
//   exit killed the pending relaunch), which is exactly why this runs in the
//   daemon: the daemon is a SEPARATE root process (not the app's uid / process
//   group), so `am force-stop`-ing the caller cannot stop the relaunch it forked.
//
// WHY A DAEMON (not the old setuid helper):
//   These boxes expose root to adb, but zygote sets no_new_privs, so a setuid
//   bit on an app-exec'd binary is IGNORED — the app keeps euid=10020. The only
//   reliable design is a process that is ALREADY root (started by provisioning /
//   a ROM init hook) and stays root, exposing a restricted local socket the
//   unprivileged Player app connects to. No su, no setuid, no shell exec.
//
// SECURITY MODEL:
//   * Listens on an ABSTRACT AF_UNIX socket (LMW_SOCKET_NAME). Abstract sockets
//     have no filesystem entry, so there is no path mode/owner to get wrong and
//     it maps cleanly to Kotlin LocalSocket(ABSTRACT). Authorization is done
//     purely by kernel-verified peer credentials, never by request text.
//   * Every connection is authenticated with SO_PEERCRED: the peer uid MUST
//     equal the configured Player uid read from a ROOT-OWNED uid file
//     (LMW_UID_FILE). A uid supplied in the request is never trusted.
//   * Protocol is a single line: "PROBE" | "RESTART_APP" | "REBOOT" |
//     "INSTALL <abs-path>". Extra args, unknown verbs, oversized input rejected.
//   * RESTART_APP and REBOOT take NO argument — the app package/component is a
//     compile-time constant (LMW_PKG / LMW_COMPONENT), never request-supplied, so
//     there is no shell-injection / arbitrary-launch surface. RESTART_APP forks a
//     detached root worker that force-stops then relaunches only LMW_COMPONENT.
//   * INSTALL only accepts EXACTLY the one canonical cache/update path
//     (LMW_CANONICAL_APK). That single-string policy makes traversal, wrong
//     directory and wrong filename all rejections by construction; the open is
//     additionally O_NOFOLLOW + regular-file + non-empty checked at runtime.
//   * INSTALL copies the verified APK to a WORLD-READABLE stage (LMW_STAGED_APK,
//     0644 so system_server/installd uid 1000 can read it — the app's own
//     cache/update dir is 0700 app-private and PM cannot read it), then runs
//     an ordered `pm install` (plain `-r`, then `-r -f` force-internal — see
//     LMW_PM_INSTALL_CMDS) and, only on a "Success" reply, RESTART_APP. No
//     whole-device reboot (see WHY PM-INSTALL below). Only if every pm attempt
//     fails with INSTALL_FAILED_INVALID_INSTALL_LOCATION is the legacy scanner
//     stage + delayed reboot used as a last resort.
//
// WHY PM-INSTALL (not the old /data/app overwrite + whole-device reboot):
//   The old path copied the APK straight into /data/app/<pkg>-1.apk and rebooted
//   so the boot package scanner would adopt it. But (a) a warm reboot bricks Wi-Fi
//   on QZX_C1 (SDIO -110, see §restart-semantics) and (b) overwriting the file
//   without going through PackageManager leaves PM's recorded versionCode stale
//   until a scan — the running dex may be new while the platform still reports the
//   OLD version, which is NOT a verified update contract. `pm install -r` is the
//   platform-blessed atomic activation: it re-dexopts, swaps, refreshes the
//   recorded versionCode, and force-stops the app — no device reboot needed. If pm
//   fails the daemon reports the failure and does NOT reboot (a broken update must
//   never strand the box off-network). Real-device acceptance: scripts/qzx_verify_update.sh.
//
// Build (cloud CI, armv7, inside the NDK) — FULLY STATIC, NON-PIE:
//   "$NDK/.../armv7a-linux-androideabi21-clang" -Os -static -fno-PIE -s
//     -o scripts/lmw_root_daemon scripts/lmw_root_daemon.c
// WHY static+non-PIE (v1.14.1 root fix): the daemon runs on API19 bionic. A
//   DYNAMIC build resolves libc symbols against the DEVICE bionic at exec time,
//   and API19 does not export some symbols modern NDK headers reference (e.g.
//   `signal`) → "cannot locate symbol" and the daemon never starts. A static
//   binary carries its own libc, so there is nothing to resolve on-device: it
//   runs identically on API19..current. Non-PIE avoids the static-PIE loader
//   path (unreliable on 4.4 kernels): on the NDK `-static` already produces a
//   classic non-PIE ET_EXEC (static-PIE needs an explicit `-static-pie`) and
//   `-fno-PIE` fixes codegen to match. `-no-pie` is intentionally NOT passed —
//   with `-static` it is a link-only no-op the clang driver flags as "argument
//   unused during compilation", failing the `-Werror` build. The ELF ship gate
//   (scripts/check_daemon_elf.sh) is what actually proves the output is static.
//   (The NDK's min API is 21, so we compile with the api21 clang but link
//   static — the API level only picks headers; static linking makes it moot.)
//
// Host unit tests: scripts/tests/test_lmw_root_daemon.c (see LMW_DAEMON_TEST).

// _GNU_SOURCE: glibc gates struct ucred (SO_PEERCRED) + dprintf behind it. On
// bionic (the real target) these are always visible, so this is a host-test
// no-op that keeps the same source compiling with the distro gcc.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define LMW_PKG           "com.jieoz.lanmediawall.player"
// Explicit launch component for RESTART_APP. Hardcoded (not request-supplied) so
// the daemon can only ever relaunch THIS one allowlisted activity — no arbitrary
// component/shell surface. Matches AndroidManifest .MainActivity (HOME/LAUNCHER).
#define LMW_COMPONENT     "com.jieoz.lanmediawall.player/.MainActivity"
#define LMW_CACHE_PREFIX  "/data/data/com.jieoz.lanmediawall.player/cache/update/"
// ONE fixed canonical update filename below cache/update (matches AppUpdater).
#define LMW_CANONICAL_APK LMW_CACHE_PREFIX "com.jieoz.lanmediawall.player-update.apk"
// World-readable staging path for `pm install -r`. The verified APK is copied
// here (0644) because system_server/installd (uid 1000) cannot read the app's
// 0700-private cache/update dir. NOT /data/app — we no longer hand-place the APK
// there; PackageManager owns activation now.
#define LMW_STAGED_APK    "/data/local/tmp/lmw_update_staged.apk"
// YunOS 4.4.2-only activation target. Package name and slot are compile-time
// constants, matching the field-validated deploy_player.sh scanner path.
#ifndef LMW_LEGACY_APK
#define LMW_LEGACY_APK        "/data/app/" LMW_PKG "-1.apk"
#endif
#ifndef LMW_LEGACY_BACKUP_APK
#define LMW_LEGACY_BACKUP_APK LMW_LEGACY_APK ".lmw-backup"
#endif
#ifndef LMW_LEGACY_TMP_APK
#define LMW_LEGACY_TMP_APK    LMW_LEGACY_APK ".lmw-new"
#endif
// Root-owned file holding the single authorized Player uid (written by setup).
#define LMW_UID_FILE      "/data/local/tmp/lmw_root_daemon.uid"
// Abstract socket name (leading NUL added at bind time). Kotlin connects with
// LocalSocketAddress(LMW_SOCKET_NAME, Namespace.ABSTRACT).
#define LMW_SOCKET_NAME   "lmw_root_daemon"

// Persistent restart-execution evidence log (see §restart-state-machine). Bounded:
// rotated to .1 at LMW_RESTART_LOG_MAX so a long-lived box can't fill the tmpfs.
// Records only package name / pids / am-output tokens — never any secret.
#define LMW_RESTART_LOG      "/data/local/tmp/lmw_restart.log"
#define LMW_RESTART_LOG_MAX  65536L
// Deterministic restart budget: how many explicit relaunch attempts, how long to
// wait for the process to appear before verifying, and the pre-force-stop settle.
#define LMW_RESTART_MAX_ATTEMPTS  3
#define LMW_RESTART_VERIFY_WAIT_S 3
#define LMW_RESTART_SETTLE_MS     300

#define LMW_MAX_PATH      512
#define LMW_MAX_LINE      1024

typedef enum {
    CMD_INVALID = 0,
    CMD_PROBE,
    CMD_REBOOT,       // whole-device reboot (HIGH-RISK advanced action only)
    CMD_INSTALL,      // stage APK then RESTART_APP (no whole-device reboot)
    CMD_RESTART_APP,  // force-stop + relaunch ONLY the Player app (normal restart)
} lmw_cmd;

typedef struct {
    char arg[LMW_MAX_PATH];
} lmw_request;

typedef enum {
    PATH_OK = 0,
    PATH_ERR_EMPTY,
    PATH_ERR_TOO_LONG,
    PATH_ERR_NOT_ABSOLUTE,
    PATH_ERR_OUTSIDE_CACHE,
    PATH_ERR_TRAVERSAL,
    PATH_ERR_NOT_CANONICAL,
} lmw_path_status;

// ---- pure, host-testable helpers ------------------------------------------

static int lmw_str_eq(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

static int lmw_starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

// Strip a single trailing CR/LF pair from a mutable buffer.
static void lmw_chomp(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) {
        s[--n] = '\0';
    }
}

// Classify a proposed INSTALL source path. Pure: no filesystem access, so the
// runtime open() still enforces O_NOFOLLOW + regular-file + non-empty.
static lmw_path_status lmw_install_path_status(const char *path) {
    if (path == NULL || path[0] == '\0') return PATH_ERR_EMPTY;
    if (strlen(path) >= LMW_MAX_PATH) return PATH_ERR_TOO_LONG;
    if (path[0] != '/') return PATH_ERR_NOT_ABSOLUTE;
    if (!lmw_starts_with(path, LMW_CACHE_PREFIX)) return PATH_ERR_OUTSIDE_CACHE;
    if (strstr(path, "..") != NULL) return PATH_ERR_TRAVERSAL;
    // Only the single canonical filename is accepted (defense in depth: this
    // also forbids any subdirectory under the cache prefix).
    if (!lmw_str_eq(path, LMW_CANONICAL_APK)) return PATH_ERR_NOT_CANONICAL;
    return PATH_OK;
}

// Parse one request line into a command + optional single arg. Rejects extra
// args, unknown verbs, and missing INSTALL arg. Copies (does not mutate caller).
static lmw_cmd lmw_parse_request(const char *line_in, lmw_request *out) {
    char line[LMW_MAX_LINE];
    if (line_in == NULL) return CMD_INVALID;
    if (strlen(line_in) >= sizeof(line)) return CMD_INVALID;
    strcpy(line, line_in);
    lmw_chomp(line);
    out->arg[0] = '\0';

    if (lmw_str_eq(line, "PROBE")) return CMD_PROBE;
    if (lmw_str_eq(line, "REBOOT")) return CMD_REBOOT;
    if (lmw_str_eq(line, "RESTART_APP")) return CMD_RESTART_APP;

    const char *prefix = "INSTALL ";
    size_t plen = strlen(prefix);
    if (strncmp(line, prefix, plen) == 0) {
        const char *arg = line + plen;
        if (arg[0] == '\0') return CMD_INVALID;
        if (strchr(arg, ' ') != NULL) return CMD_INVALID; // exactly one arg
        if (strlen(arg) >= sizeof(out->arg)) return CMD_INVALID;
        strcpy(out->arg, arg);
        return CMD_INSTALL;
    }
    return CMD_INVALID;
}

// Authorize a peer: the SO_PEERCRED uid must equal the configured Player uid,
// which must be a real, positive uid. A supplied uid is never trusted here.
static int lmw_peer_authorized(int peer_uid, int allowed_uid) {
    if (allowed_uid <= 0) return 0;
    if (peer_uid < 0) return 0;
    return peer_uid == allowed_uid;
}

// Does a command require the authenticated Player uid? PROBE is a read-only
// identity/diagnostic reply (daemon euid + peer uid), so it is answerable by any
// peer — that lets provisioning/ADB verify the daemon as root without pretending
// to be the app uid. Everything else (privileged actions + unknown verbs) fails
// closed and requires the SO_PEERCRED-authenticated player uid.
static int lmw_command_requires_auth(lmw_cmd cmd) {
    return cmd != CMD_PROBE;
}

// Read the single authorized Player uid from a root-owned file. -1 on any error.
static int lmw_read_allowed_uid(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int uid = -1;
    if (fscanf(f, "%d", &uid) != 1) uid = -1;
    fclose(f);
    return uid;
}

static int lmw_pm_has_exact_line(const char *out, const char *expected) {
    if (!out || !expected) return 0;
    size_t expected_len = strlen(expected);
    const char *p = out;
    while (*p) {
        const char *line_end = strchr(p, '\n');
        const char *next = line_end ? line_end + 1 : p + strlen(p);
        const char *end = line_end ? line_end : next;
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\r')) p++;
        while (end > p && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r')) end--;
        if ((size_t)(end - p) == expected_len && memcmp(p, expected, expected_len) == 0) return 1;
        p = next;
    }
    return 0;
}

static int lmw_pm_has_success_line(const char *out) {
    return lmw_pm_has_exact_line(out, "Success");
}

static int lmw_pm_is_invalid_install_location(const char *out) {
    return lmw_pm_has_exact_line(out,
        "Failure [INSTALL_FAILED_INVALID_INSTALL_LOCATION]");
}

// YunOS 4.4's PM parses the APK path (and prints its `pkg:` diagnostic) but then
// rejects the request with this exact message instead of the standard location
// failure. This is the same ROM-level activation limitation: pm cannot install,
// while the boot package scanner can. Require both exact lines so unrelated PM
// errors, including signing/version failures, cannot reach the legacy path.
static int lmw_pm_is_no_package_specified(const char *out) {
    return lmw_pm_has_exact_line(out, "pkg: " LMW_STAGED_APK) &&
           lmw_pm_has_exact_line(out, "Error: no package specified");
}

typedef enum { INSTALL_FAIL = 0, INSTALL_PM_SUCCESS = 1, INSTALL_LEGACY_STAGE = 2 } lmw_install_action;
static lmw_install_action lmw_install_decision(const char *out) {
    if (lmw_pm_has_success_line(out)) return INSTALL_PM_SUCCESS;
    if (lmw_pm_is_invalid_install_location(out) || lmw_pm_is_no_package_specified(out))
        return INSTALL_LEGACY_STAGE;
    return INSTALL_FAIL;
}

// Collapse pm's multi-line output to a single greppable token for the reply line.
// Prefer a real Failure/Error line; skip unhelpful "pkg: ..." path-only lines that
// PackageManager prints even when the real reason is on a later line
// (§field-and-8b0677b40b truncated field detail to just the stage path).
// Pure: host-tested via test_lmw_root_daemon.
static void lmw_pm_summary(const char *out, char *summary, size_t sz) {
    const char *src = NULL;
    const char *f = strstr(out, "Failure");
    if (f) {
        src = f;
    } else {
        const char *e = strstr(out, "Error");
        if (e) src = e;
    }
    if (!src) {
        // Walk lines; skip blank / pkg: path-only diagnostics.
        const char *p = out;
        while (*p) {
            const char *line_end = strchr(p, '\n');
            const char *next = line_end ? line_end + 1 : p + strlen(p);
            const char *s = p;
            const char *end = line_end ? line_end : next;
            while (s < end && (*s == ' ' || *s == '\t' || *s == '\r')) s++;
            while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r')) end--;
            if (s < end) {
                size_t len = (size_t)(end - s);
                if (!(len >= 4 && memcmp(s, "pkg:", 4) == 0)) {
                    src = s;
                    break;
                }
            }
            p = next;
        }
    }
    if (!src) src = out;
    // Trim leading whitespace on the chosen line (out may start with '\t').
    while (*src == ' ' || *src == '\t' || *src == '\r') src++;
    size_t j = 0;
    for (size_t i = 0; src[i] && j < sz - 1; i++) {
        char c = src[i];
        if (c == '\n' || c == '\r') break;
        summary[j++] = c;
    }
    summary[j] = '\0';
    if (j == 0) snprintf(summary, sz, "no-pm-output");
}

// Ordered `pm install` attempts, tried in sequence before any whole-device
// reboot is even considered (§field-and-6037055a3d: a warm reboot drops Wi-Fi on
// QZX_C1). Every entry is a COMPILE-TIME CONSTANT command string — LMW_STAGED_APK
// is our own fixed stage (the request path is validated == LMW_CANONICAL_APK and
// copied THERE), so these popen lines carry NO external/request bytes.
//   1. `pm install -r`      — normal reinstall (keeps existing install location).
//   2. `pm install -r -f`   — force-install to INTERNAL storage. On boxes whose
//      default install location is a flaky/absent SD (the source of
//      INSTALL_FAILED_INVALID_INSTALL_LOCATION) this succeeds where (1) failed,
//      activating the APK via PackageManager with only an app restart — NO
//      whole-device reboot. We deliberately do NOT add `-d` (allow-downgrade):
//      downgrades are blocked by policy (UpdateGuard already requires a strictly
//      newer versionCode) and enabling it here would weaken that guarantee.
// Kept in the pure region so test_lmw_root_daemon can lock the ordering/force flag
// without a device.
static const char *const LMW_PM_INSTALL_CMDS[] = {
    "pm install -r " LMW_STAGED_APK " 2>&1",
    "pm install -r -f " LMW_STAGED_APK " 2>&1",
};
#define LMW_PM_INSTALL_CMD_COUNT \
    (sizeof(LMW_PM_INSTALL_CMDS) / sizeof(LMW_PM_INSTALL_CMDS[0]))
static const char *lmw_legacy_target_path(void) { return LMW_LEGACY_APK; }
static const char *lmw_legacy_temp_path(void) { return LMW_LEGACY_TMP_APK; }
static const char *lmw_legacy_backup_path(void) { return LMW_LEGACY_BACKUP_APK; }
static mode_t lmw_legacy_target_mode(void) { return 0644; }

typedef enum { BACKUP_ABSENT = 0, BACKUP_PENDING_COMMIT = 1 } lmw_backup_state;
// Pure: should a leftover backup from a previous COMPLETED stage be deleted
// before starting a new stage? target+backup both present means the new APK is
// already live and the backup is only the pre-upgrade copy waiting for commit.
// Blocking here permanently bricks the second OTA on legacy-path boxes
// (§field-and-b2b90f28f7: 1174→1175 → legacy_activation_failed).
static int lmw_legacy_should_commit_stale_backup(int target_exists, int backup_exists) {
    return target_exists && backup_exists;
}
// Pure: target missing but backup present means a prior stage crashed after
// target→backup and before temp→target; restore first.
static int lmw_legacy_should_restore_orphan_backup(int target_exists, int backup_exists) {
    return !target_exists && backup_exists;
}
#ifdef LMW_DAEMON_TEST
static lmw_backup_state lmw_legacy_backup_state(int backup_exists) {
    return backup_exists ? BACKUP_PENDING_COMMIT : BACKUP_ABSENT;
}

// Separate startup commit hook: only after real package/version verification.
static int lmw_legacy_commit_verified(const char *backup, int version_verified) {
    if (!version_verified) return 0;
    return unlink(backup) == 0 || errno == ENOENT;
}
#endif

#if !defined(LMW_DAEMON_TEST) || defined(LMW_DAEMON_INTEGRATION_TEST)
static int lmw_copy_regular(const char *src, const char *dst);

// Stage for the boot package scanner without ever uninstalling. The existing APK
// is moved to a fixed backup first; every later failure restores it. The new APK
// is copied/chmodded under a temporary name and atomically renamed into place.
//
// Field reality (§field-and-b2b90f28f7): a successful legacy stage leaves
// `.lmw-backup` until an explicit commit. The daemon historically never auto-
// committed after reboot, so the SECOND remote OTA hit "stale backup → fail
// closed" and returned legacy_activation_failed even though the first OTA had
// worked. Heal that before staging again.
static int lmw_legacy_stage(const char *verified_apk) {
    struct stat oldst;
    // Incomplete prior transaction: backup without target → restore first.
    if (lmw_legacy_should_restore_orphan_backup(
            lstat(lmw_legacy_target_path(), &oldst) == 0,
            access(lmw_legacy_backup_path(), F_OK) == 0)) {
        if (rename(lmw_legacy_backup_path(), lmw_legacy_target_path()) != 0) return 0;
    }
    int had_old = lstat(lmw_legacy_target_path(), &oldst) == 0;
    if (had_old && (!S_ISREG(oldst.st_mode) || S_ISLNK(oldst.st_mode))) return 0;
    if (unlink(lmw_legacy_temp_path()) != 0 && errno != ENOENT) return 0;
    if (lmw_copy_regular(verified_apk, lmw_legacy_temp_path()) != 0) goto fail;
    if (chmod(lmw_legacy_temp_path(), lmw_legacy_target_mode()) != 0) goto fail;
    // Previous successful stage left a backup. Commit it so this new stage can
    // take a fresh backup of the currently-live APK. Do NOT fail-closed forever.
    if (lmw_legacy_should_commit_stale_backup(
            had_old, access(lmw_legacy_backup_path(), F_OK) == 0)) {
        if (unlink(lmw_legacy_backup_path()) != 0) goto fail;
    }
    if (had_old && rename(lmw_legacy_target_path(), lmw_legacy_backup_path()) != 0) goto fail;
    if (rename(lmw_legacy_temp_path(), lmw_legacy_target_path()) != 0) goto restore;
    sync();
    return 1;
restore:
    if (had_old) rename(lmw_legacy_backup_path(), lmw_legacy_target_path());
fail:
    unlink(LMW_LEGACY_TMP_APK);
    return 0;
}

static int lmw_legacy_rollback(void) {
    if (access(lmw_legacy_backup_path(), F_OK) != 0) return 1;
    if (unlink(lmw_legacy_target_path()) != 0 && errno != ENOENT) return 0;
    if (rename(lmw_legacy_backup_path(), lmw_legacy_target_path()) != 0) return 0;
    sync();
    return 1;
}
#endif

// ---- §restart-state-machine: pure decision helpers ------------------------
// The v1.14.3 restart was a BLIND one-shot shell chain (force-stop; sleep; am
// start) whose only proof of success was "the fork happened" — on the real
// QZX_C1 the app force-stopped but the relaunch did not reliably take, leaving a
// black kiosk (see field log 16:10). These pure helpers turn the worker into a
// deterministic verify-and-retry state machine, and are host-tested so the
// decision logic can never silently regress to "dispatch == done".

// Did an `am start` invocation FAIL? Toolbox `am` prints "Starting: Intent {..}"
// on success and is otherwise noisy; the reliable failure signals on 4.4 are an
// "Error:" / "Error type" line or a thrown exception. The benign
// "Warning: Activity not started, its current task has been brought to the front"
// means the activity is ALREADY frontmost — success, not failure. No output at
// all (sh/am missing) is treated as failure so we never count a silent no-op as a
// launch. NULL/empty => failed.
static int lmw_am_start_failed(const char *am_output) {
    if (am_output == NULL || am_output[0] == '\0') return 1;
    if (strstr(am_output, "Error:") != NULL) return 1;
    if (strstr(am_output, "Error type") != NULL) return 1;
    if (strstr(am_output, "Exception") != NULL) return 1;
    return 0;
}

// Extract the pid of the MAIN process whose `ps` NAME column is EXACTLY pkg (not a
// ":subprocess", not a substring). Toolbox `ps` lines are whitespace-columned with
// PID in column 2 and the process NAME as the last token. Returns the pid or -1 if
// pkg is not running. Pure: operates only on the captured text.
static int lmw_extract_pid(const char *ps_output, const char *pkg) {
    if (ps_output == NULL || pkg == NULL || pkg[0] == '\0') return -1;
    size_t pkglen = strlen(pkg);
    const char *p = ps_output;
    while (*p) {
        const char *nl = strchr(p, '\n');
        const char *end = nl ? nl : p + strlen(p);
        // Find the last whitespace-delimited token on the line (the process NAME),
        // trimming a trailing CR from adb line endings.
        const char *lineend = end;
        while (lineend > p && (lineend[-1] == '\r' || lineend[-1] == ' ' ||
                               lineend[-1] == '\t')) lineend--;
        const char *namestart = lineend;
        while (namestart > p && namestart[-1] != ' ' && namestart[-1] != '\t')
            namestart--;
        size_t namelen = (size_t)(lineend - namestart);
        if (namelen == pkglen && memcmp(namestart, pkg, pkglen) == 0) {
            // Matched the main process name exactly — read column 2 (the pid).
            const char *q = p;
            while (q < lineend && (*q == ' ' || *q == '\t')) q++; // col1 (USER) start
            while (q < lineend && *q != ' ' && *q != '\t') q++;   // skip USER
            while (q < lineend && (*q == ' ' || *q == '\t')) q++; // pid start
            int pid = 0, any = 0;
            while (q < lineend && *q >= '0' && *q <= '9') { pid = pid * 10 + (*q - '0'); q++; any = 1; }
            if (any) return pid;
        }
        if (!nl) break;
        p = nl + 1;
    }
    return -1;
}

// Should the worker attempt another restart? Retry ONLY when the app is not yet
// verified running AND we have not exhausted the bounded attempt budget. Once the
// process is verified up we never restart again (idempotent), and we never loop
// past max_attempts (deterministic termination — no reboot fallback).
static int lmw_should_retry_restart(int verified_running, int attempts_made, int max_attempts) {
    if (verified_running) return 0;
    return attempts_made < max_attempts;
}

// Bound the persistent evidence log: rotate (to .1) once it reaches the cap so a
// long-lived box cannot fill /data/local/tmp. Pure size comparison.
static int lmw_restart_log_should_rotate(long size, long max_size) {
    return size >= max_size;
}

// ---- §restart-state-machine: ACTIVITY_RESUMED vs PROCESS_UP (E0001) ----------
// PID/process return alone is NOT full recovery (E0001): the box can have the
// Player PROCESS up while a DIFFERENT activity (e.g. the launcher) is frontmost —
// the kiosk is still black. So the worker also asks whether OUR component is the
// resumed/focused activity, using API19-available `dumpsys activity activities`
// (mResumedActivity / mFocusedActivity) with a `dumpsys window windows`
// mCurrentFocus fallback. This tri-state keeps the daemon HONEST on old ROMs:
// UNSUPPORTED means "device didn't report a resumed/focus line", never a fake pass.
typedef enum {
    ACT_UNSUPPORTED = -1, // no resumed/focus indicator in the output (can't prove)
    ACT_OTHER       = 0,  // an indicator exists but frontmost is NOT our component
    ACT_RESUMED     = 1,  // our component is the resumed/focused (frontmost) activity
} lmw_activity_state;

// Is char c a package-name character ([A-Za-z0-9_.])? Used to enforce a token
// boundary so a look-alike package (…playerx/…) can't match "…player/…".
static int lmw_is_pkgchar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '.';
}

// Is our component named on an activity/window line? dumpsys prints the launched
// component as "<pkg>/<class>" where <class> is either short (".Class") or fully
// qualified ("pkg.Class"). Both forms share the "<pkg>/" prefix, so we match that
// prefix with a clean LEFT boundary (start-of-line or a non-package char) — that
// way a look-alike package ("…playerx/…") cannot match "…player/…". Matching on
// "<pkg>/" (not the full component) is deliberate: the exact class spelling varies
// by ROM (short vs fully-qualified) and any activity of OUR package being frontmost
// is the recovery signal we want. Pure string scan; `component` is a constant.
static int lmw_line_names_component(const char *line, const char *component) {
    const char *slash = strchr(component, '/');
    if (slash == NULL) return 0;
    size_t pfxlen = (size_t)(slash - component) + 1; // "<pkg>/" including the slash
    char pfx[256];
    if (pfxlen >= sizeof(pfx)) return 0;
    memcpy(pfx, component, pfxlen);
    pfx[pfxlen] = '\0';
    const char *q = line;
    while ((q = strstr(q, pfx)) != NULL) {
        char before = (q == line) ? ' ' : q[-1];
        if (!lmw_is_pkgchar(before)) return 1; // clean left boundary => real match
        q += 1;
    }
    return 0;
}

// Classify whether OUR component is frontmost from a captured dumpsys blob. Scans
// only the resumed/focus indicator lines; if none is present the box can't prove
// activity state and we return ACT_UNSUPPORTED (never a fake pass). Pure.
static lmw_activity_state lmw_activity_resumed(const char *dumpsys_out,
                                               const char *component) {
    if (dumpsys_out == NULL || dumpsys_out[0] == '\0') return ACT_UNSUPPORTED;
    static const char *const indicators[] = {
        "mResumedActivity", "mFocusedActivity", "ResumedActivity", "mCurrentFocus",
    };
    int saw_indicator = 0;
    const char *p = dumpsys_out;
    while (*p) {
        const char *nl = strchr(p, '\n');
        const char *end = nl ? nl : p + strlen(p);
        size_t linelen = (size_t)(end - p);
        char line[1024];
        if (linelen >= sizeof(line)) linelen = sizeof(line) - 1;
        memcpy(line, p, linelen);
        line[linelen] = '\0';
        int is_indicator = 0;
        for (size_t i = 0; i < sizeof(indicators) / sizeof(indicators[0]); i++) {
            if (strstr(line, indicators[i]) != NULL) { is_indicator = 1; break; }
        }
        if (is_indicator) {
            saw_indicator = 1;
            if (lmw_line_names_component(line, component)) return ACT_RESUMED;
        }
        if (!nl) break;
        p = nl + 1;
    }
    return saw_indicator ? ACT_OTHER : ACT_UNSUPPORTED;
}

// Human token for the evidence log / ACK (never a secret).
static const char *lmw_activity_str(lmw_activity_state s) {
    switch (s) {
        case ACT_RESUMED:     return "yes";
        case ACT_OTHER:       return "no";
        case ACT_UNSUPPORTED: return "unsupported";
    }
    return "unsupported";
}

// The two-signal full-recovery verdict (E0001). Full recovery requires the process
// up AND our activity frontmost. An unreportable activity state is evidence we
// could not complete verification, never permission to turn process-only into a
// pass. This fail-closed rule prevents the original black-kiosk failure from being
// mislabeled as recovered when dumpsys is unavailable or truncated.
static int lmw_restart_fully_recovered(int process_up, lmw_activity_state act) {
    if (!process_up) return 0;
    return act == ACT_RESUMED;
}

// A successful post-state is not enough: prove that this invocation actually
// transitioned the app. Force-stop must succeed and the observed PID must change.
static int lmw_restart_transition_proven(int force_stop_ok, int before_pid, int after_pid) {
    return force_stop_ok && before_pid > 0 && after_pid > 0 && before_pid != after_pid;
}

// ---- CLI dispatch policy (pure): -restart auth + no-REBOOT-reach proof --------
// Extracted so the security guarantees E0001 demands are HOST-TESTED, not just
// asserted in comments: root-only `-restart`, shared worker with socket
// RESTART_APP, and NO cli entrypoint that can reach the whole-device reboot.
typedef enum {
    CLI_SERVE = 0,   // no/unknown arg: bind socket + daemonize
    CLI_SERVE_FG,    // -f: bind socket, stay foreground
    CLI_PROBE,       // -probe: connect to running daemon, print identity (no root)
    CLI_RESTART,     // -restart: run the SAME restart worker inline (root-only)
} lmw_cli_mode_t;

// Map argv[1] to a CLI mode. Unknown/NULL => CLI_SERVE (there is deliberately NO
// reboot flag: the ONLY reboot path is the authenticated socket REBOOT verb).
static lmw_cli_mode_t lmw_cli_mode(const char *arg) {
    if (arg == NULL) return CLI_SERVE;
    if (lmw_str_eq(arg, "-probe")) return CLI_PROBE;
    if (lmw_str_eq(arg, "-restart")) return CLI_RESTART;
    if (lmw_str_eq(arg, "-f")) return CLI_SERVE_FG;
    return CLI_SERVE;
}

// Does a CLI mode require euid==0? Everything privileged does; -probe is the only
// read-only mode (it just talks to the socket and needs no root).
static int lmw_mode_requires_root(lmw_cli_mode_t m) {
    return m != CLI_PROBE;
}

// Can a CLI mode reach the whole-device REBOOT? NEVER — reboot is reachable ONLY as
// an authenticated socket verb (CMD_REBOOT), so every CLI mode returns 0. This is
// the static proof the harness/CLI can't strand a box off Wi-Fi with a warm reboot.
static int lmw_mode_can_reboot(lmw_cli_mode_t m) {
    (void)m;
    return 0;
}

#if !defined(LMW_DAEMON_TEST) || defined(LMW_DAEMON_INTEGRATION_TEST)

// ---- device-only side-effecting daemon ------------------------------------

#include <signal.h>
#include <stdarg.h>
#include <sys/reboot.h>
#include <sys/wait.h>
#include <time.h>

static int lmw_copy_regular(const char *src, const char *dst) {
    // O_NOFOLLOW: refuse if src is a symlink (defense against a swapped path).
    int in = open(src, O_RDONLY | O_NOFOLLOW);
    if (in < 0) return -1;
    struct stat st;
    if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) {
        close(in);
        return -1;
    }
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644);
    if (out < 0) { close(in); return -1; }
    char buf[262144];
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n == 0) break;
        if (n < 0) { close(in); close(out); return -1; }
        char *p = buf;
        while (n > 0) {
            ssize_t w = write(out, p, (size_t)n);
            if (w < 0) { close(in); close(out); return -1; }
            p += w; n -= w;
        }
    }
    if (fsync(out) != 0) { close(in); close(out); return -1; }
    close(in);
    close(out);
    return 0;
}

static void lmw_do_reboot(void) {
    sync();
    // Prefer the toolbox binary (respects vendor reboot hooks); fall back to the
    // raw syscall so a stripped /system still restarts.
    execl("/system/bin/reboot", "reboot", (char *)NULL);
    execl("/sbin/reboot", "reboot", (char *)NULL);
    reboot(RB_AUTOBOOT);
}

typedef struct { int gate_fd; } lmw_reboot_gate;

// Two-phase dispatch: detached child reports ready, then blocks on a parent gate.
static int lmw_prepare_delayed_reboot(lmw_reboot_gate *gate) {
    int ready[2], go[2];
    if (pipe(ready) != 0) return 0;
    if (pipe(go) != 0) { close(ready[0]); close(ready[1]); return 0; }
    pid_t pid = fork();
    if (pid < 0) { close(ready[0]); close(ready[1]); close(go[0]); close(go[1]); return 0; }
    if (pid == 0) {
        close(ready[0]); close(go[1]);
        if (setsid() < 0) _exit(1);
        pid_t g = fork();
        if (g < 0) _exit(1);
        if (g > 0) _exit(0);
        if (write(ready[1], "R", 1) != 1) _exit(1);
        close(ready[1]);
        char token;
        if (read(go[0], &token, 1) != 1) _exit(1);
        close(go[0]);
        sleep(1);
        lmw_do_reboot();
        _exit(1);
    }
    close(ready[1]); close(go[0]);
    int status = 0; char token = 0;
    int child_ok = waitpid(pid, &status, 0) >= 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    int ready_ok = read(ready[0], &token, 1) == 1 && token == 'R';
    close(ready[0]);
    if (!child_ok || !ready_ok) { close(go[1]); return 0; }
    gate->gate_fd = go[1];
    return 1;
}
static int lmw_release_reboot(lmw_reboot_gate *gate) {
    int ok = write(gate->gate_fd, "G", 1) == 1;
    close(gate->gate_fd); gate->gate_fd = -1;
    return ok;
}

// ---- §restart-state-machine: side-effecting worker ------------------------
//
// The v1.14.3 restart was a single blind `sh -c "am force-stop; sleep 1; am start
// -n COMPONENT -a MAIN -c HOME -f 0x10200000"`, exec'd once with NO check that the
// process actually came back. On the real QZX_C1 the force-stop landed but the
// relaunch did not reliably take, leaving a black kiosk until a manual explicit
// `am start` (field log 16:10). This worker replaces that with a deterministic
// state machine: force-stop once, then explicit-launch → wait → verify the process
// via `ps` → retry up to LMW_RESTART_MAX_ATTEMPTS ONLY while unverified. Every step
// is appended to a bounded evidence log so the eventual outcome is durable even
// though the socket caller (the force-stopped app) never sees it. No reboot path.

// Append one line to the bounded restart evidence log (rotates to .1 at the cap).
// Best-effort: a logging failure never changes restart behavior.
static void lmw_restart_log(const char *fmt, ...) {
    struct stat st;
    if (stat(LMW_RESTART_LOG, &st) == 0 &&
        lmw_restart_log_should_rotate((long)st.st_size, LMW_RESTART_LOG_MAX)) {
        rename(LMW_RESTART_LOG, LMW_RESTART_LOG ".1"); // keep exactly one old file
    }
    FILE *f = fopen(LMW_RESTART_LOG, "a");
    if (!f) return;
    fprintf(f, "%ld ", (long)time(NULL)); // epoch seconds — no locale/secret dep
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// Run a fixed shell command and capture up to outsz-1 bytes of combined output.
// The command string is a COMPILE-TIME CONSTANT (never request-derived), so this
// popen carries no external bytes — same guarantee as lmw_pm_install. `am`/`ps` are
// run via sh so they inherit init's framework env (BOOTCLASSPATH) the toolbox
// wrappers need. Returns 1 iff the shell/child exited cleanly.
static int lmw_capture_cmd(const char *cmd, char *out, size_t outsz) {
    out[0] = '\0';
    FILE *p = popen(cmd, "r");
    if (!p) return 0;
    size_t used = 0;
    char buf[256];
    while (fgets(buf, sizeof(buf), p) != NULL) {
        size_t len = strlen(buf);
        if (used + len < outsz - 1) { memcpy(out + used, buf, len); used += len; }
    }
    out[used] = '\0';
    int status = pclose(p);
    return status != -1 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// Is the Player process running right now? Verified by parsing `ps` for the exact
// package process NAME (lmw_extract_pid), not by "am didn't error". Returns pid or
// -1. On 4.4 toolbox `ps` with no filter lists everything; we scan for our name.
static int lmw_player_pid(void) {
    // Busy vendor ROMs can emit more than 8 KiB from toolbox ps. Truncating the
    // snapshot before the Player row turns a healthy relaunch into a false timeout.
    char ps_out[65536];
    if (!lmw_capture_cmd("ps", ps_out, sizeof(ps_out))) return -1;
    return lmw_extract_pid(ps_out, LMW_PKG);
}

// Is OUR component the resumed/focused (frontmost) activity right now? Reads
// API19-available `dumpsys activity activities` (mResumedActivity/mFocusedActivity),
// falling back to `dumpsys window windows` mCurrentFocus, and classifies via the
// pure lmw_activity_resumed. Returns ACT_RESUMED/ACT_OTHER/ACT_UNSUPPORTED — the
// UNSUPPORTED branch is what keeps process-only honest on ROMs that don't report it.
static lmw_activity_state lmw_player_activity_state(void) {
    char out[16384];
    if (lmw_capture_cmd("dumpsys activity activities 2>/dev/null", out, sizeof(out))) {
        lmw_activity_state s = lmw_activity_resumed(out, LMW_COMPONENT);
        if (s != ACT_UNSUPPORTED) return s;
    }
    // Fallback: the window manager's current focus (present on more 4.4 builds).
    if (lmw_capture_cmd("dumpsys window windows 2>/dev/null", out, sizeof(out)))
        return lmw_activity_resumed(out, LMW_COMPONENT);
    return ACT_UNSUPPORTED;
}

// Perform the full deterministic restart and return 1 iff the Player process is
// verified running afterward. Runs SYNCHRONOUSLY in the caller — the socket path
// wraps it in a detached grandchild (so it survives force-stopping the app), while
// the root-only `-restart` CLI runs it inline and maps the result to its exit code.
//
// `am start` uses the EXPLICIT allowlisted component first (LMW_COMPONENT) — the
// simplest API19-compatible launch — and does NOT rely on HOME implicit resolution
// (the old chain's `-a MAIN -c HOME` is dropped: the field failure showed implicit
// resolution to a force-stopped package was the unreliable part; an explicit
// component start is what the manual recovery used).
static int lmw_restart_app_run(void) {
    lmw_restart_log("restart begin pkg=%s component=%s max_attempts=%d",
                    LMW_PKG, LMW_COMPONENT, LMW_RESTART_MAX_ATTEMPTS);
    // Settle so the daemon's ACK flushes to the caller BEFORE we force-stop it.
    usleep(LMW_RESTART_SETTLE_MS * 1000);
    sync();

    int before_pid = lmw_player_pid();
    char amout[1024];
    int fs_ok = lmw_capture_cmd("am force-stop " LMW_PKG, amout, sizeof(amout));
    lmw_restart_log("force_stop clean_exit=%d", fs_ok);

    int process_up = 0, pid = -1, attempts = 0;
    lmw_activity_state act = ACT_UNSUPPORTED;
    // Retry while NOT fully recovered (process up AND our activity frontmost) and
    // the attempt budget remains. Retrying on unsupported activity evidence or
    // ACT_OTHER (process up, wrong activity frontmost) is deliberate: another
    // explicit `am start` is exactly the manual recovery that worked in the field.
    while (lmw_should_retry_restart(lmw_restart_fully_recovered(process_up, act),
                                    attempts, LMW_RESTART_MAX_ATTEMPTS)) {
        attempts++;
        // Explicit component launch (simplest API19 form). NEW_TASK|RESET keeps a
        // clean relaunch of the kiosk task.
        int launch_ok = lmw_capture_cmd(
            "am start -n " LMW_COMPONENT " -f 0x10200000 2>&1",
            amout, sizeof(amout));
        // Copy the first output line into a short token for the evidence log.
        char tok[128];
        size_t tj = 0;
        for (size_t ti = 0; amout[ti] && amout[ti] != '\n' && amout[ti] != '\r' &&
                            tj < sizeof(tok) - 1; ti++) tok[tj++] = amout[ti];
        tok[tj] = '\0';
        int am_failed = lmw_am_start_failed(amout);
        lmw_restart_log("launch attempt=%d clean_exit=%d am_failed=%d out=%s",
                        attempts, launch_ok, am_failed, tok);
        // Give the framework a moment to fork the app process, then VERIFY BOTH
        // signals: PROCESS_UP (ps) and ACTIVITY_RESUMED (dumpsys), per E0001.
        sleep(LMW_RESTART_VERIFY_WAIT_S);
        pid = lmw_player_pid();
        process_up = (pid > 0);
        act = process_up ? lmw_player_activity_state() : ACT_UNSUPPORTED;
        lmw_restart_log("verify attempt=%d process_up=%d player_pid=%d activity_resumed=%s",
                        attempts, process_up, pid, lmw_activity_str(act));
    }
    // Terminal outcome: explicit tokens so a log reader (and the field harnesses)
    // never has to infer success. `restart_verified` == full recovery per E0001
    // (process up AND activity resumed); unsupported activity evidence is failure;
    // otherwise `restart_failed`. Both PROCESS_UP and ACTIVITY_RESUMED are recorded.
    int transitioned = lmw_restart_transition_proven(fs_ok, before_pid, pid);
    int recovered = transitioned && lmw_restart_fully_recovered(process_up, act);
    lmw_restart_log("%s attempts=%d force_stop_ok=%d before_pid=%d process_up=%d activity_resumed=%s player_pid=%d",
                    recovered ? "restart_verified" : "restart_failed",
                    attempts, fs_ok, before_pid, process_up, lmw_activity_str(act), pid);
    return recovered;
}

// Fork a detached grandchild to run the restart state machine, so the daemon
// neither blocks nor accumulates a zombie (double-fork → grandchild reparents to
// init) and the worker outlives force-stopping the calling app. Returns 1 iff the
// worker was successfully DISPATCHED (the fork chain started) — NOT that the app is
// verified up: the caller is about to be force-stopped and cannot observe the
// eventual result, which is instead recorded in LMW_RESTART_LOG. This keeps the
// socket ACK semantically honest (accepted/dispatched), per §restart-semantics.
static int lmw_restart_app(void) {
    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        setsid();               // leave the daemon's session/process group
        pid_t g = fork();
        if (g < 0) _exit(1);
        if (g > 0) _exit(0);    // intermediate child exits → grandchild to init
        lmw_restart_app_run();  // verify-and-retry; result durably logged, not acked
        _exit(0);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 0;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// Run one pm command, capturing stdout+stderr into out. Returns 1 iff an exact
// independently trimmed "Success" line was printed. On Android 4.4 / YunOS, pm
// can print Success while the shell/popen exit status is non-zero (or pclose
// fails to report a clean exit); the Success line is the only reliable signal
// (§field-and-8b0677b40b: exit-gated success produced false pm_failed with
// detail="pkg: /data/local/tmp/..."). Still drain the pipe and call pclose so
// we don't leave zombies.
static int lmw_pm_run_one(const char *cmd, char *out, size_t outsz) {
    out[0] = '\0';
    FILE *p = popen(cmd, "r");
    if (!p) return 0;
    size_t used = 0;
    char buf[256];
    while (fgets(buf, sizeof(buf), p) != NULL) {
        size_t len = strlen(buf);
        if (used + len < outsz - 1) { memcpy(out + used, buf, len); used += len; }
    }
    out[used] = '\0';
    (void)pclose(p);
    return lmw_pm_has_success_line(out);
}

// Try each ordered pm command until one reports Success. Returns 1 on the first
// success (out holds that attempt's output). We only advance to the next command
// when the current attempt failed with INSTALL_FAILED_INVALID_INSTALL_LOCATION —
// the one failure `-f` (force internal) is meant to fix; any OTHER failure won't
// be helped by re-trying and is returned as-is so lmw_install_decision reports the
// real reason. On return-0, out holds the LAST attempt's output. `pm` is invoked
// via the shell so it inherits init's framework env (BOOTCLASSPATH etc.).
static int lmw_pm_install(char *out, size_t outsz) {
    out[0] = '\0';
    for (size_t i = 0; i < LMW_PM_INSTALL_CMD_COUNT; i++) {
        if (lmw_pm_run_one(LMW_PM_INSTALL_CMDS[i], out, outsz)) return 1;
        // Stop early unless this is the invalid-install-location failure that a
        // later force-internal attempt can actually address.
        if (!lmw_pm_is_invalid_install_location(out)) break;
    }
    return 0;
}

// Perform INSTALL: validate + copy to a world-readable stage + `pm install -r` +
// (on success) RESTART_APP. NO whole-device reboot. On any failure writes a terse
// reason to the client and returns without installing or rebooting.
static void lmw_handle_install(int fd, const char *path) {
    lmw_path_status ps = lmw_install_path_status(path);
    if (ps != PATH_OK) {
        dprintf(fd, "error install path rejected code=%d\n", (int)ps);
        return;
    }
    // Copy the verified canonical APK to the world-readable stage (0644) so
    // system_server/installd can read it during `pm install`.
    const char *tmp = LMW_STAGED_APK ".tmp";
    unlink(tmp);
    if (lmw_copy_regular(path, tmp) != 0) {
        dprintf(fd, "error install copy failed errno=%d\n", errno);
        return;
    }
    if (chmod(tmp, 0644) != 0) {
        dprintf(fd, "error install chmod failed errno=%d\n", errno);
        unlink(tmp);
        return;
    }
    if (rename(tmp, LMW_STAGED_APK) != 0) {
        dprintf(fd, "error install rename failed errno=%d\n", errno);
        unlink(tmp);
        return;
    }
    sync();
    // Atomic activation via PackageManager (refreshes the recorded versionCode and
    // force-stops the app). This blocks for the install; updates are rare so a few
    // seconds on the daemon is acceptable and lets us report the real outcome.
    char pmout[1024];
    int ok = lmw_pm_install(pmout, sizeof(pmout));
    lmw_install_action action = lmw_install_decision(pmout);
    // Prefer text-based decision: Success line alone is enough on 4.4 boxes
    // even when popen/exit status is noisy (§field-and-8b0677b40b).
    if (!(ok || action == INSTALL_PM_SUCCESS)) {
        if (action == INSTALL_LEGACY_STAGE) {
            if (!lmw_legacy_stage(path)) {
                unlink(LMW_STAGED_APK);
                // Keep a greppable reason — field logs previously only saw the
                // bare token, which hid stale-backup vs copy/chmod failures.
                dprintf(fd, "error install legacy_activation_failed detail=stage\n");
                return;
            }
            unlink(LMW_STAGED_APK);
            lmw_reboot_gate gate = { .gate_fd = -1 };
            if (!lmw_prepare_delayed_reboot(&gate)) {
                int restored = lmw_legacy_rollback();
                dprintf(fd, "error install legacy_reboot_dispatch_failed rollback=%s\n",
                        restored ? "restored" : "failed");
                fsync(fd);
                return;
            }
            // Child is ready but gated: deliver and half-close the reply first.
            // Canonical reply — matches RootDaemonProtocol.parseInstall's primary
            // token spelling (state=legacy_activation_dispatched + reboot_required).
            // The player also still accepts the older legacy_staged/reboot_pending
            // spelling from daemons already in the field.
            dprintf(fd, "ok install state=legacy_activation_dispatched reboot_required via=data_app_scanner\n");
            fsync(fd);
            shutdown(fd, SHUT_WR);
            if (!lmw_release_reboot(&gate)) (void)lmw_legacy_rollback();
            return;
        }
        unlink(LMW_STAGED_APK);
        char summary[128];
        lmw_pm_summary(pmout, summary, sizeof(summary));
        dprintf(fd, "error install pm_failed detail=%s\n", summary);
        return;
    }
    unlink(LMW_STAGED_APK); // never leave a world-readable PM stage lying around
    // Relaunch the freshly-installed app (pm force-stopped it). App-only; no reboot.
    if (lmw_restart_app())
        dprintf(fd, "ok install state=pm_success activated via=pm_install restart_dispatched\n");
    else
        dprintf(fd, "error install activated_but_restart_dispatch_failed\n");
    fsync(fd);
}

static int lmw_get_peer_uid(int fd) {
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
    return (int)cred.uid;
}

// Bind an abstract AF_UNIX listening socket. Returns fd or -1.
static int lmw_bind_abstract(const char *name) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    // Abstract namespace: leading NUL, name follows.
    size_t nlen = strlen(name);
    if (nlen + 1 >= sizeof(addr.sun_path)) { close(fd); return -1; }
    addr.sun_path[0] = '\0';
    memcpy(addr.sun_path + 1, name, nlen);
    socklen_t alen = offsetof(struct sockaddr_un, sun_path) + 1 + nlen;
    if (bind(fd, (struct sockaddr *)&addr, alen) != 0) { close(fd); return -1; }
    if (listen(fd, 4) != 0) { close(fd); return -1; }
    return fd;
}

static void lmw_serve(int listen_fd) {
    for (;;) {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            continue;
        }
        int allowed = lmw_read_allowed_uid(LMW_UID_FILE);
        int peer = lmw_get_peer_uid(fd);
        char line[LMW_MAX_LINE];
        ssize_t n = read(fd, line, sizeof(line) - 1);
        if (n <= 0) { close(fd); continue; }
        line[n] = '\0';
        lmw_request req;
        lmw_cmd cmd = lmw_parse_request(line, &req);
        // Privileged verbs require the SO_PEERCRED-authenticated player uid; PROBE
        // is answerable by anyone (read-only identity), so setup/ADB can verify.
        if (lmw_command_requires_auth(cmd) && !lmw_peer_authorized(peer, allowed)) {
            dprintf(fd, "error unauthorized peer_uid=%d\n", peer);
            close(fd);
            continue;
        }
        switch (cmd) {
            case CMD_PROBE:
                dprintf(fd, "ready daemon_euid=%d peer_uid=%d allowed_uid=%d pkg=%s\n",
                        (int)geteuid(), peer, allowed, LMW_PKG);
                close(fd);
                break;
            case CMD_RESTART_APP:
                // Normal controller restart: app-only, preserves Wi-Fi + uptime.
                // Dispatches the detached verify-and-retry worker (lmw_restart_app →
                // lmw_restart_app_run) — the EXACT SAME worker the root-only `-restart`
                // CLI runs inline, so both paths share one implementation. Then ACK.
                // The ACK is honest: it reports the worker was ACCEPTED/DISPATCHED, NOT
                // that the app is verified up — the caller (this very app) is about to
                // be force-stopped and cannot observe the eventual result, which is
                // recorded in the durable restart log instead (§restart-semantics).
                if (lmw_restart_app())
                    dprintf(fd, "ok restart_app accepted dispatched log=%s\n",
                            LMW_RESTART_LOG);
                else
                    dprintf(fd, "error restart_app dispatch_failed\n");
                fsync(fd);
                close(fd);
                break;
            case CMD_REBOOT:
                dprintf(fd, "ok reboot rebooting\n");
                fsync(fd);
                close(fd);
                lmw_do_reboot();
                break;
            case CMD_INSTALL:
                lmw_handle_install(fd, req.arg);
                close(fd);
                break;
            default:
                dprintf(fd, "error invalid request\n");
                close(fd);
                break;
        }
    }
}

// Connect to the running daemon over its abstract socket, send PROBE, print the
// reply, and exit 0 iff it is a genuine root-daemon "ready ... daemon_euid=0"
// line. This is what lmw_setup / ADB call to VERIFY the daemon is actually up and
// root before writing any completion marker — an out-of-process protocol probe,
// not a mere "is the process alive" pgrep.
static int lmw_probe_client(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { fprintf(stderr, "probe: socket errno=%d\n", errno); return 2; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    size_t nlen = strlen(LMW_SOCKET_NAME);
    addr.sun_path[0] = '\0';
    memcpy(addr.sun_path + 1, LMW_SOCKET_NAME, nlen);
    socklen_t alen = offsetof(struct sockaddr_un, sun_path) + 1 + nlen;
    if (connect(fd, (struct sockaddr *)&addr, alen) != 0) {
        fprintf(stderr, "probe: connect @%s failed errno=%d (daemon not running?)\n",
                LMW_SOCKET_NAME, errno);
        close(fd);
        return 2;
    }
    if (write(fd, "PROBE\n", 6) != 6) { close(fd); return 2; }
    char buf[LMW_MAX_LINE];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) { fprintf(stderr, "probe: empty reply\n"); return 2; }
    buf[n] = '\0';
    printf("%s", buf);
    // ready iff the reply proves the peer is genuinely root (matches Kotlin
    // RootDaemonProtocol.parseProbe: "ready " prefix AND daemon_euid=0).
    if (strncmp(buf, "ready ", 6) == 0 && strstr(buf, "daemon_euid=0") != NULL) return 0;
    return 3;
}

// Ignore SIGPIPE so a client that hangs up mid-reply cannot kill the daemon.
// Uses sigaction (a real exported bionic symbol since API1), NOT signal(): on
// old bionic <signal.h> made signal() a static-inline shim over bsd_signal, so
// API19 libc.so never exported `signal` — a dynamic daemon that referenced it
// died at exec with `cannot locate symbol "signal"` (the v1.14.0 field failure).
static void lmw_ignore_sigpipe(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_IGN;
    sigaction(SIGPIPE, &sa, NULL);
}

#if !defined(LMW_DAEMON_TEST) && !defined(LMW_DAEMON_INTEGRATION_TEST)
int main(int argc, char **argv) {
    lmw_ignore_sigpipe();

    // Dispatch on the pure CLI-mode policy (host-tested): this is the SINGLE place
    // that decides root requirement and proves — by construction — that NO cli mode
    // can reach the whole-device REBOOT (lmw_mode_can_reboot is always 0; reboot is
    // reachable only as the authenticated socket verb inside lmw_serve).
    lmw_cli_mode_t mode = lmw_cli_mode(argc > 1 ? argv[1] : NULL);

    // Defense-in-depth invariant (also host-tested): NO cli mode may reach the
    // whole-device reboot. If this ever became true it would be a code bug that
    // could strand a box off Wi-Fi, so we refuse to run rather than proceed.
    if (lmw_mode_can_reboot(mode)) {
        fprintf(stderr, "lmw_root_daemon: refusing — cli mode must never reboot\n");
        return 1;
    }

    // -probe: verify a running daemon over the protocol. Read-only, needs no root
    // (lmw_mode_requires_root(CLI_PROBE)==0), so ADB/setup can call it directly.
    if (mode == CLI_PROBE) {
        return lmw_probe_client();
    }

    // Every remaining mode is privileged and requires euid==0 — refuse otherwise so
    // a mis-provisioned start (or a non-root `-restart` attempt) fails loudly rather
    // than pretending to serve/restart. This is the runtime enforcement of E0001's
    // "root-only -restart rejects non-root".
    if (lmw_mode_requires_root(mode) && geteuid() != 0) {
        fprintf(stderr, "lmw_root_daemon: not root (euid=%d); mode %d refused.\n",
                (int)geteuid(), (int)mode);
        return 1;
    }

    // -restart: run the SAME deterministic worker (lmw_restart_app_run) the socket
    // RESTART_APP path forks, but INLINE (synchronously) so a real-device harness can
    // read a truthful full-recovery pass/fail from the exit code. It is reachable
    // only by a caller already root (checked above) — like -probe over `su 0` — so
    // the socket's SO_PEERCRED player-uid authorization is NOT weakened, and this
    // path never touches REBOOT (lmw_mode_can_reboot(CLI_RESTART)==0).
    if (mode == CLI_RESTART) {
        int ok = lmw_restart_app_run();
        fprintf(stderr, "lmw_root_daemon: -restart fully_recovered=%d (see %s)\n",
                ok, LMW_RESTART_LOG);
        return ok ? 0 : 1;
    }

    int listen_fd = lmw_bind_abstract(LMW_SOCKET_NAME);
    if (listen_fd < 0) {
        fprintf(stderr, "lmw_root_daemon: bind @%s failed errno=%d\n", LMW_SOCKET_NAME, errno);
        return 1;
    }

    if (mode != CLI_SERVE_FG) {
        // Detach: double-fork so the daemon survives its starting shell exiting.
        pid_t pid = fork();
        if (pid < 0) { fprintf(stderr, "lmw_root_daemon: fork failed\n"); return 1; }
        if (pid > 0) return 0;
        setsid();
        pid = fork();
        if (pid < 0) return 1;
        if (pid > 0) _exit(0);
    }

    lmw_serve(listen_fd);
    return 0;
}
#endif

#endif // LMW_DAEMON_TEST
