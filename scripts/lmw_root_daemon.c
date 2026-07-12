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
//     `pm install -r <stage>` and, only on a "Success" reply, RESTART_APP. No
//     whole-device reboot (see WHY PM-INSTALL below).
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
// Root-owned file holding the single authorized Player uid (written by setup).
#define LMW_UID_FILE      "/data/local/tmp/lmw_root_daemon.uid"
// Abstract socket name (leading NUL added at bind time). Kotlin connects with
// LocalSocketAddress(LMW_SOCKET_NAME, Namespace.ABSTRACT).
#define LMW_SOCKET_NAME   "lmw_root_daemon"

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

#ifndef LMW_DAEMON_TEST

// ---- device-only side-effecting daemon ------------------------------------

#include <signal.h>
#include <sys/reboot.h>
#include <sys/wait.h>

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

// Force-stop + relaunch ONLY the Player app (the normal controller restart).
//
// Runs in a DETACHED root grandchild so it survives the very force-stop it issues
// against the caller: the caller (the Player app, uid 10020) is what triggers the
// restart, and `am force-stop LMW_PKG` kills that app's process — but this worker
// is a root process in its own session, NOT in the app's uid/process-group, so it
// keeps running and completes the relaunch. This is the whole reason the restart
// lives in the daemon rather than the app (the app cannot reliably relaunch after
// killing itself; AlarmManager self-relaunch was the unreliable old path).
//
// The command string is a COMPILE-TIME CONSTANT (LMW_PKG / LMW_COMPONENT) — no
// byte of it comes from the request (RESTART_APP takes no arg), so `sh -c` here is
// not an arbitrary-shell surface: the daemon can only ever force-stop + relaunch
// this one allowlisted component. `am` is invoked via sh so it inherits the
// framework env (BOOTCLASSPATH etc.) the toolbox `am` wrapper needs.
static void lmw_restart_app_worker(void) {
    // small settle so the daemon's "ok ... restarting_app" reply flushes to the
    // caller BEFORE we force-stop it (the reply socket is the caller's process).
    usleep(300 * 1000);
    sync();
    // force-stop then relaunch. `am start` on a force-stopped package still works
    // with an explicit component; the MainActivity re-starts PlayerService.
    execl("/system/bin/sh", "sh", "-c",
          "am force-stop " LMW_PKG " ; sleep 1 ; "
          "am start -n " LMW_COMPONENT
          " -a android.intent.action.MAIN -c android.intent.category.HOME"
          " -f 0x10200000",  // NEW_TASK | RESET_TASK_IF_NEEDED: clean relaunch
          (char *)NULL);
    // If sh is missing the app just stays stopped; the caller already got its ack
    // and this worker exits. (No reboot fallback — normal restart must not reboot.)
    _exit(0);
}

// Fork a detached grandchild to run the restart worker, so the daemon neither
// blocks nor accumulates a zombie (double-fork → grandchild reparents to init).
static void lmw_restart_app(void) {
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        setsid();               // leave the daemon's session/process group
        pid_t g = fork();
        if (g < 0) _exit(1);
        if (g > 0) _exit(0);    // intermediate child exits → grandchild to init
        lmw_restart_app_worker();
        _exit(0);
    }
    waitpid(pid, NULL, 0);      // reap the intermediate child immediately
}

// Run `pm install -r <stage>` and return 1 iff PackageManager reports success.
// On 4.4 `pm` prints "Success" / "Failure [reason]" to stdout and its exit code
// is unreliable, so we scan the captured output for "Success" (the authoritative
// signal). The command is built from COMPILE-TIME CONSTANTS only (LMW_STAGED_APK
// is not request-derived — the request path is validated == LMW_CANONICAL_APK and
// we copy THAT to our own fixed stage), so this popen carries no external bytes.
// `pm` is invoked via the shell so it inherits init's framework env (BOOTCLASSPATH
// etc.) the toolbox `pm` wrapper needs.
static int lmw_pm_install(char *out, size_t outsz) {
    out[0] = '\0';
    FILE *p = popen("pm install -r " LMW_STAGED_APK " 2>&1", "r");
    if (!p) return 0;
    size_t used = 0;
    char buf[256];
    while (fgets(buf, sizeof(buf), p) != NULL) {
        size_t len = strlen(buf);
        if (used + len < outsz - 1) { memcpy(out + used, buf, len); used += len; }
    }
    out[used] = '\0';
    pclose(p);
    // "Success" is the only affirmative PM reply; anything else (incl. "Failure",
    // empty output when pm is missing, or INSTALL_FAILED_*) is treated as failure.
    return strstr(out, "Success") != NULL ? 1 : 0;
}

// Collapse pm's multi-line output to a single greppable token for the reply line.
static void lmw_pm_summary(const char *out, char *summary, size_t sz) {
    const char *f = strstr(out, "Failure");
    const char *src = f ? f : out;
    size_t j = 0;
    for (size_t i = 0; src[i] && j < sz - 1; i++) {
        char c = src[i];
        if (c == '\n' || c == '\r') break;
        summary[j++] = c;
    }
    summary[j] = '\0';
    if (j == 0) snprintf(summary, sz, "no-pm-output");
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
    unlink(LMW_STAGED_APK); // never leave a world-readable APK lying around
    if (!ok) {
        char summary[128];
        lmw_pm_summary(pmout, summary, sizeof(summary));
        dprintf(fd, "error install pm_failed detail=%s\n", summary);
        return; // NO reboot fallback — a failed update must not strand the box.
    }
    dprintf(fd, "ok install activated via=pm_install restarting_app\n");
    fsync(fd);
    // Relaunch the freshly-installed app (pm force-stopped it). App-only; no reboot.
    lmw_restart_app();
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
                // Reply first, then fork the detached worker that force-stops +
                // relaunches ONLY the allowlisted component (never reboots).
                dprintf(fd, "ok restart_app restarting_app\n");
                fsync(fd);
                close(fd);
                lmw_restart_app();
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

int main(int argc, char **argv) {
    lmw_ignore_sigpipe();

    // Client mode: verify a running daemon over the protocol. Runs as any uid
    // (PROBE needs no auth), so ADB/setup can call it directly.
    if (argc > 1 && lmw_str_eq(argv[1], "-probe")) {
        return lmw_probe_client();
    }

    // Server mode must run as root; refuse otherwise so a mis-provisioned start
    // fails loudly instead of pretending to serve.
    if (geteuid() != 0) {
        fprintf(stderr, "lmw_root_daemon: not root (euid=%d); cannot serve.\n", (int)geteuid());
        return 1;
    }

    int foreground = (argc > 1 && lmw_str_eq(argv[1], "-f"));
    int listen_fd = lmw_bind_abstract(LMW_SOCKET_NAME);
    if (listen_fd < 0) {
        fprintf(stderr, "lmw_root_daemon: bind @%s failed errno=%d\n", LMW_SOCKET_NAME, errno);
        return 1;
    }

    if (!foreground) {
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

#endif // LMW_DAEMON_TEST
