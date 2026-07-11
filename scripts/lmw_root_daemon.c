// lmw_root_daemon.c — root-started local daemon that performs the two privileged
// operations the media-wall player needs on QZX_C1 / YunOS 4.4.2 boxes:
//   * INSTALL a downloaded+verified APK into /data/app and reboot (self-update)
//   * REBOOT the whole device (controller-triggered restart)
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
//   * Protocol is a single line: "PROBE" | "REBOOT" | "INSTALL <abs-path>".
//     Extra args, unknown verbs, and oversized input are rejected.
//   * INSTALL only accepts EXACTLY the one canonical cache/update path
//     (LMW_CANONICAL_APK). That single-string policy makes traversal, wrong
//     directory and wrong filename all rejections by construction; the open is
//     additionally O_NOFOLLOW + regular-file + non-empty checked at runtime.
//   * INSTALL copies atomically (temp + rename) to LMW_DST, chown system:system,
//     chmod 0644, fsync + sync, then reboots so the boot package scanner adopts
//     it (the proven path on these boxes; PackageInstaller is broken here).
//
// Build (cloud CI, armv7, inside the NDK):
//   "$NDK/.../armv7a-linux-androideabi19-clang" -Os -fPIE -pie -static -s
//     -o scripts/lmw_root_daemon scripts/lmw_root_daemon.c
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
#define LMW_CACHE_PREFIX  "/data/data/com.jieoz.lanmediawall.player/cache/update/"
// ONE fixed canonical update filename below cache/update (matches AppUpdater).
#define LMW_CANONICAL_APK LMW_CACHE_PREFIX "com.jieoz.lanmediawall.player-update.apk"
#define LMW_DST           "/data/app/com.jieoz.lanmediawall.player-1.apk"
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
    CMD_REBOOT,
    CMD_INSTALL,
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

// Perform INSTALL: validate + atomic copy + chown/chmod + reboot. On any failure
// writes a terse reason to the client and returns without rebooting.
static void lmw_handle_install(int fd, const char *path) {
    lmw_path_status ps = lmw_install_path_status(path);
    if (ps != PATH_OK) {
        dprintf(fd, "error install path rejected code=%d\n", (int)ps);
        return;
    }
    const char *tmp = LMW_DST ".tmp";
    unlink(tmp);
    if (lmw_copy_regular(path, tmp) != 0) {
        dprintf(fd, "error install copy failed errno=%d\n", errno);
        return;
    }
    if (chown(tmp, 1000, 1000) != 0) { // system:system
        dprintf(fd, "error install chown failed errno=%d\n", errno);
        unlink(tmp);
        return;
    }
    if (chmod(tmp, 0644) != 0) {
        dprintf(fd, "error install chmod failed errno=%d\n", errno);
        unlink(tmp);
        return;
    }
    if (rename(tmp, LMW_DST) != 0) {
        dprintf(fd, "error install rename failed errno=%d\n", errno);
        unlink(tmp);
        return;
    }
    sync();
    dprintf(fd, "ok install staged dst=%s rebooting\n", LMW_DST);
    // Give the socket a moment to flush before the process is replaced.
    fsync(fd);
    lmw_do_reboot();
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

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);

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
