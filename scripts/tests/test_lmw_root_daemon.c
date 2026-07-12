// Host-testable unit tests for the lmw_root_daemon command parser + security
// policy. Compiled with the distro gcc on the CI/dev host (the daemon itself is
// cross-compiled for armv7 by cloud CI). We #include the daemon source with
// LMW_DAEMON_TEST defined so main() is elided and only the pure functions link.
//
// Build + run (host):
//   gcc -DLMW_DAEMON_TEST -o /tmp/tdaemon scripts/tests/test_lmw_root_daemon.c && /tmp/tdaemon
//
// These lock the §root-daemon security guardrails so a regression can never
// reopen a "root-install any path over the socket" hole:
//   1. command parsing: only PROBE / REBOOT / INSTALL <path>, no extra args
//   2. install path policy: exactly the one canonical cache/update file,
//      traversal / wrong-dir / wrong-name rejected
//   3. peer authorization: only the configured Player uid, from a root file

#include "../lmw_root_daemon.c"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { \
    checks++; \
    if (!(cond)) { failures++; printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
} while (0)

static void test_parse_probe(void) {
    lmw_request r;
    CHECK(lmw_parse_request("PROBE", &r) == CMD_PROBE, "PROBE parses");
    CHECK(lmw_parse_request("PROBE\n", &r) == CMD_PROBE, "PROBE with newline parses");
    CHECK(lmw_parse_request("PROBE\r\n", &r) == CMD_PROBE, "PROBE with crlf parses");
    CHECK(lmw_parse_request("PROBE extra", &r) == CMD_INVALID, "PROBE rejects extra args");
    CHECK(lmw_parse_request("probe", &r) == CMD_INVALID, "lowercase probe rejected");
}

static void test_parse_reboot(void) {
    lmw_request r;
    CHECK(lmw_parse_request("REBOOT", &r) == CMD_REBOOT, "REBOOT parses");
    CHECK(lmw_parse_request("REBOOT\n", &r) == CMD_REBOOT, "REBOOT newline parses");
    CHECK(lmw_parse_request("REBOOT now", &r) == CMD_INVALID, "REBOOT rejects extra args");
}

static void test_parse_restart_app(void) {
    lmw_request r;
    CHECK(lmw_parse_request("RESTART_APP", &r) == CMD_RESTART_APP, "RESTART_APP parses");
    CHECK(lmw_parse_request("RESTART_APP\n", &r) == CMD_RESTART_APP, "RESTART_APP newline parses");
    CHECK(lmw_parse_request("RESTART_APP now", &r) == CMD_INVALID, "RESTART_APP rejects extra args");
    CHECK(lmw_parse_request("restart_app", &r) == CMD_INVALID, "lowercase restart_app rejected");
}

static void test_parse_install(void) {
    lmw_request r;
    CHECK(lmw_parse_request("INSTALL " LMW_CANONICAL_APK, &r) == CMD_INSTALL, "INSTALL canonical parses");
    CHECK(strcmp(r.arg, LMW_CANONICAL_APK) == 0, "INSTALL arg captured");
    CHECK(lmw_parse_request("INSTALL", &r) == CMD_INVALID, "INSTALL without arg rejected");
    CHECK(lmw_parse_request("INSTALL a b", &r) == CMD_INVALID, "INSTALL rejects two args");
    CHECK(lmw_parse_request("", &r) == CMD_INVALID, "empty line rejected");
    CHECK(lmw_parse_request("FOO /x", &r) == CMD_INVALID, "unknown command rejected");
}

static void test_install_path_policy(void) {
    CHECK(lmw_install_path_status(LMW_CANONICAL_APK) == PATH_OK, "canonical path ok");
    CHECK(lmw_install_path_status("") == PATH_ERR_EMPTY, "empty rejected");
    CHECK(lmw_install_path_status("relative/x.apk") == PATH_ERR_NOT_ABSOLUTE, "relative rejected");
    CHECK(lmw_install_path_status("/etc/passwd") == PATH_ERR_OUTSIDE_CACHE, "outside cache rejected");
    CHECK(lmw_install_path_status(LMW_CACHE_PREFIX "../../../system/x") == PATH_ERR_TRAVERSAL,
          "traversal rejected");
    CHECK(lmw_install_path_status(LMW_CACHE_PREFIX "other.apk") == PATH_ERR_NOT_CANONICAL,
          "wrong filename in cache rejected");
    CHECK(lmw_install_path_status(LMW_CACHE_PREFIX "sub/lmw-update.apk") == PATH_ERR_NOT_CANONICAL,
          "nested filename rejected");
    // oversized
    char big[LMW_MAX_PATH + 64];
    memset(big, 'a', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    CHECK(lmw_install_path_status(big) == PATH_ERR_TOO_LONG, "oversized path rejected");
}

static void test_peer_authorized(void) {
    CHECK(lmw_peer_authorized(10020, 10020) == 1, "matching uid authorized");
    CHECK(lmw_peer_authorized(0, 10020) == 0, "root peer not the player uid rejected");
    CHECK(lmw_peer_authorized(10021, 10020) == 0, "different uid rejected");
    CHECK(lmw_peer_authorized(10020, -1) == 0, "no allowed uid configured rejects");
    CHECK(lmw_peer_authorized(-1, 10020) == 0, "unknown peer rejected");
}

static void test_command_requires_auth(void) {
    // PROBE is a read-only identity/diagnostic reply — answerable by any peer so
    // setup/ADB (running as root) can verify the daemon without impersonating the
    // player uid. REBOOT/INSTALL perform privileged actions and MUST require the
    // authenticated player uid.
    CHECK(lmw_command_requires_auth(CMD_PROBE) == 0, "PROBE does not require peer auth");
    CHECK(lmw_command_requires_auth(CMD_RESTART_APP) == 1, "RESTART_APP requires peer auth");
    CHECK(lmw_command_requires_auth(CMD_REBOOT) == 1, "REBOOT requires peer auth");
    CHECK(lmw_command_requires_auth(CMD_INSTALL) == 1, "INSTALL requires peer auth");
    CHECK(lmw_command_requires_auth(CMD_INVALID) == 1, "invalid command requires auth (fail closed)");
}

static void test_read_allowed_uid(void) {
    char tmpl[] = "/tmp/lmw_uid_XXXXXX";
    int fd = mkstemp(tmpl);
    CHECK(fd >= 0, "temp uid file created");
    dprintf(fd, "10020\n");
    close(fd);
    CHECK(lmw_read_allowed_uid(tmpl) == 10020, "reads uid from file");
    unlink(tmpl);
    CHECK(lmw_read_allowed_uid("/nonexistent/lmw.uid") == -1, "missing uid file -> -1");
}

int main(void) {
    test_parse_probe();
    test_parse_reboot();
    test_parse_restart_app();
    test_parse_install();
    test_install_path_policy();
    test_peer_authorized();
    test_command_requires_auth();
    test_read_allowed_uid();
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
