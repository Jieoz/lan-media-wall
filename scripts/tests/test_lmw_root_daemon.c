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

static void test_ota_rootfix_contract(void) {
    lmw_request r;
    const char *sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    char req[96], digest[65], sock[64];
    snprintf(req, sizeof(req), "UPDATE_DAEMON %s\n", sha);
    CHECK(lmw_parse_request(req, &r) == CMD_UPDATE_DAEMON, "daemon update parses");
    CHECK(lmw_command_requires_auth(CMD_UPDATE_DAEMON), "daemon update authenticated");
    lmw_sha256_hex("abc", 3, digest);
    CHECK(lmw_hex_eq_ci(digest, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"), "sha256 vector");
    lmw_candidate_probe p = lmw_parse_candidate_probe(
        "ready daemon_euid=0 peer_uid=-1 allowed_uid=-1 pkg=" LMW_PKG "\n");
    CHECK(lmw_selfupdate_decide(1, 1, p) == SELFUPDATE_APPLY, "candidate proof applies");
    CHECK(lmw_candidate_probe_sockname(42, sock, sizeof(sock)) > 0, "isolated socket name");
    CHECK(lmw_legacy_reconcile_decide(1, 1, 1) == RECONCILE_COMMIT_BACKUP, "stale backup commit decision");
    CHECK(lmw_pm_path_names_target("package:/data/app/x.apk\n", "/data/app/x.apk"), "pm path adoption proof");
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

static void test_pm_success_line(void) {
    CHECK(lmw_pm_has_success_line("Success\n") == 1, "exact Success line accepted");
    CHECK(lmw_pm_has_success_line("  Success  \r\n") == 1, "trimmed Success line accepted");
    CHECK(lmw_pm_has_success_line("note\nSuccess\n") == 1, "Success line accepted after diagnostics");
    CHECK(lmw_pm_has_success_line("Successfully installed\n") == 0, "Success substring rejected");
    CHECK(lmw_pm_has_success_line("Failure [mentions Success]\n") == 0, "Success in failure rejected");
    CHECK(lmw_pm_has_success_line("") == 0, "empty output rejected");
}

// §field-and-8b0677b40b: pm_failed detail must surface Failure/Error lines, not
// the leading "pkg: /path" diagnostic that PackageManager often prints first.
static void test_pm_summary_prefers_failure(void) {
    char summary[128];
    lmw_pm_summary("\tpkg: /data/local/tmp/lmw_update_staged.apk\n"
                   "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]\n",
                   summary, sizeof(summary));
    CHECK(strstr(summary, "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]") == summary,
          "Failure line wins over pkg: path line");

    lmw_pm_summary("\tpkg: /data/local/tmp/lmw_update_staged.apk\n"
                   "Error: java.lang.Exception\n",
                   summary, sizeof(summary));
    CHECK(strstr(summary, "Error:") == summary, "Error line wins over pkg: path line");

    lmw_pm_summary("\tpkg: /data/local/tmp/lmw_update_staged.apk\nSuccess\n",
                   summary, sizeof(summary));
    CHECK(strcmp(summary, "Success") == 0, "pkg-only first line is skipped for Success");

    lmw_pm_summary("\tpkg: /data/local/tmp/lmw_update_staged.apk\n",
                   summary, sizeof(summary));
    CHECK(strstr(summary, "pkg:") == summary, "pkg-only output still reported when alone");
}

static void test_legacy_install_contract(void) {
    CHECK(lmw_pm_is_invalid_install_location("Failure [INSTALL_FAILED_INVALID_INSTALL_LOCATION]\n") == 1,
          "exact invalid install location classified");
    CHECK(lmw_pm_is_invalid_install_location("Failure [INSTALL_FAILED_INVALID_INSTALL_LOCATION_EXTRA]\n") == 0,
          "lookalike invalid location rejected");
    CHECK(lmw_install_decision("Success\n") == INSTALL_PM_SUCCESS, "pm success stays primary path");
    CHECK(lmw_install_decision("Failure [INSTALL_FAILED_INVALID_INSTALL_LOCATION]\n") == INSTALL_LEGACY_STAGE,
          "only exact invalid location selects legacy stage");
    CHECK(lmw_install_decision("pkg: " LMW_STAGED_APK "\nError: no package specified\n") == INSTALL_LEGACY_STAGE,
          "YunOS pkg diagnostic plus exact no-package error selects legacy stage");
    CHECK(lmw_install_decision("Error: no package specified\n") == INSTALL_FAIL,
          "no-package error without the staged path does not select legacy stage");
    CHECK(lmw_install_decision("pkg: /tmp/other.apk\nError: no package specified\n") == INSTALL_FAIL,
          "no-package error for an unrelated path does not select legacy stage");
    CHECK(lmw_install_decision("pkg: " LMW_STAGED_APK "\nError: no package specified extra\n") == INSTALL_FAIL,
          "lookalike no-package error does not select legacy stage");
    CHECK(lmw_install_decision("Failure [INSTALL_FAILED_VERSION_DOWNGRADE]\n") == INSTALL_FAIL,
          "ordinary install failure does not enter legacy stage");
    CHECK(strcmp(lmw_legacy_target_path(), "/data/app/com.jieoz.lanmediawall.player-1.apk") == 0,
          "legacy target fixed");
    CHECK(strcmp(lmw_legacy_temp_path(), "/data/app/com.jieoz.lanmediawall.player-1.apk.lmw-new") == 0,
          "legacy temp is independent");
    CHECK(strcmp(lmw_legacy_backup_path(), "/data/app/com.jieoz.lanmediawall.player-1.apk.lmw-backup") == 0,
          "legacy backup is independent");
    CHECK(lmw_legacy_target_mode() == 0644, "legacy target mode is 0644");
    CHECK(lmw_legacy_backup_state(0) == BACKUP_ABSENT, "missing backup is clean state");
    CHECK(lmw_legacy_backup_state(1) == BACKUP_PENDING_COMMIT, "existing backup remains pending commit");
    // §field-and-b2b90f28f7: second OTA after a successful legacy stage must
    // auto-commit the leftover backup (target+backup both present), not fail.
    CHECK(lmw_legacy_should_commit_stale_backup(1, 1) == 1,
          "live target + leftover backup → commit before re-stage");
    CHECK(lmw_legacy_should_commit_stale_backup(1, 0) == 0,
          "clean live target needs no commit");
    CHECK(lmw_legacy_should_commit_stale_backup(0, 1) == 0,
          "orphan backup is restore, not commit");
    CHECK(lmw_legacy_should_restore_orphan_backup(0, 1) == 1,
          "backup without target → restore first");
    CHECK(lmw_legacy_should_restore_orphan_backup(1, 1) == 0,
          "both present is not an orphan restore");
    CHECK(lmw_legacy_should_restore_orphan_backup(0, 0) == 0,
          "nothing to restore");

    char tmpl[] = "/tmp/lmw_backup_XXXXXX";
    int fd = mkstemp(tmpl);
    CHECK(fd >= 0, "temporary backup fixture created");
    if (fd >= 0) close(fd);
    CHECK(lmw_legacy_commit_verified(tmpl, 0) == 0 && access(tmpl, F_OK) == 0,
          "unverified startup cannot delete backup");
    CHECK(lmw_legacy_commit_verified(tmpl, 1) == 1 && access(tmpl, F_OK) != 0,
          "verified startup commits by deleting backup");
}

// §field-and-6037055a3d: before any whole-device reboot the daemon must try a
// force-INTERNAL pm install. Lock the ordered command list: first a plain
// `pm install -r`, then a `-f` (force internal) attempt, and never a downgrade.
static void test_pm_install_cmd_order(void) {
    CHECK(LMW_PM_INSTALL_CMD_COUNT == 2, "exactly two ordered pm attempts");
    CHECK(strstr(LMW_PM_INSTALL_CMDS[0], "pm install -r ") == LMW_PM_INSTALL_CMDS[0],
          "first attempt is a plain reinstall");
    CHECK(strstr(LMW_PM_INSTALL_CMDS[0], " -f ") == NULL,
          "first attempt does not force internal");
    CHECK(strstr(LMW_PM_INSTALL_CMDS[1], "pm install -r ") == LMW_PM_INSTALL_CMDS[1] &&
          strstr(LMW_PM_INSTALL_CMDS[1], " -f ") != NULL,
          "second attempt forces install to internal storage before any reboot");
    for (size_t i = 0; i < LMW_PM_INSTALL_CMD_COUNT; i++) {
        CHECK(strstr(LMW_PM_INSTALL_CMDS[i], " -d ") == NULL,
              "no attempt enables downgrade (policy: strictly-newer only)");
        CHECK(strstr(LMW_PM_INSTALL_CMDS[i], LMW_STAGED_APK) != NULL,
              "every attempt installs only our fixed world-readable stage");
    }
}

// ---- §restart-state-machine: pure helpers driving the deterministic restart ----
// These lock the decision logic of the RESTART_APP worker so the "force-stop but
// never came back" field failure is caught by construction, not by a blind chain.

static void test_am_start_failed(void) {
    // Toolbox `am start` prints "Starting: Intent {...}" on success.
    CHECK(lmw_am_start_failed("Starting: Intent { cmp=com.jieoz.lanmediawall.player/.MainActivity }\n") == 0,
          "normal Starting line is success");
    // "Warning: Activity not started, its current task has been brought to the front"
    // means the activity is already frontmost — that is SUCCESS, not failure.
    CHECK(lmw_am_start_failed("Starting: Intent {...}\nWarning: Activity not started, its current task has been brought to the front\n") == 0,
          "already-frontmost Warning is success");
    // Real failures the box prints:
    CHECK(lmw_am_start_failed("Starting: Intent {...}\nError: Activity class {..} does not exist.\n") == 1,
          "Error: line is failure");
    CHECK(lmw_am_start_failed("Error type 3\nError: Activity class does not exist\n") == 1,
          "Error type is failure");
    CHECK(lmw_am_start_failed("java.lang.SecurityException: Permission Denial\n") == 1,
          "Exception is failure");
    // No output at all (e.g. sh/am missing) is a failure, not a silent success.
    CHECK(lmw_am_start_failed("") == 1, "empty am output is failure");
    CHECK(lmw_am_start_failed(NULL) == 1, "NULL am output is failure");
}

static void test_extract_pid(void) {
    const char *pkg = "com.jieoz.lanmediawall.player";
    // Toolbox `ps` columns: USER PID PPID VSIZE RSS WCHAN PC NAME
    const char *ps_running =
        "USER     PID   PPID  VSIZE  RSS   WCHAN    PC         NAME\n"
        "u0_a20   3054  1234  912345 45678 ffffffff 00000000 S com.jieoz.lanmediawall.player\n";
    CHECK(lmw_extract_pid(ps_running, pkg) == 3054, "pid extracted for exact package match");
    // A different package on the box must NOT match.
    const char *ps_other =
        "USER     PID   PPID  VSIZE  RSS   WCHAN    PC         NAME\n"
        "system   777   1     11111  222   ffffffff 00000000 S system_server\n";
    CHECK(lmw_extract_pid(ps_other, pkg) == -1, "no match -> -1");
    // A subprocess (:remote) is a DIFFERENT process name and must not be taken as the app.
    const char *ps_sub =
        "u0_a20   4001  1234  1000 20 ffffffff 0 S com.jieoz.lanmediawall.player:remote\n";
    CHECK(lmw_extract_pid(ps_sub, pkg) == -1, "subprocess name is not the main process");
    CHECK(lmw_extract_pid("", pkg) == -1, "empty ps -> -1");
    CHECK(lmw_extract_pid(NULL, pkg) == -1, "NULL ps -> -1");
    // Trailing CR (adb line endings) must not defeat the match.
    const char *ps_cr =
        "u0_a20   3055 1234 900 44 ffffffff 0 S com.jieoz.lanmediawall.player\r\n";
    CHECK(lmw_extract_pid(ps_cr, pkg) == 3055, "trailing CR tolerated");
}

static void test_should_retry_restart(void) {
    // verified_running, attempt(1-based attempts already made), max_attempts
    CHECK(lmw_should_retry_restart(0, 1, 3) == 1, "not verified, attempts left -> retry");
    CHECK(lmw_should_retry_restart(0, 3, 3) == 0, "not verified, attempts exhausted -> stop");
    CHECK(lmw_should_retry_restart(1, 1, 3) == 0, "verified running -> never retry");
    CHECK(lmw_should_retry_restart(0, 2, 3) == 1, "not verified, still under max -> retry");
}

static void test_restart_log_should_rotate(void) {
    CHECK(lmw_restart_log_should_rotate(0, 65536) == 0, "empty log does not rotate");
    CHECK(lmw_restart_log_should_rotate(65535, 65536) == 0, "under cap does not rotate");
    CHECK(lmw_restart_log_should_rotate(65536, 65536) == 1, "at cap rotates");
    CHECK(lmw_restart_log_should_rotate(70000, 65536) == 1, "over cap rotates");
}

// ---- §restart-state-machine: ACTIVITY_RESUMED distinct from PROCESS_UP -------
// E0001: PID/process return alone is NOT full recovery. The worker must also read
// whether OUR component is the resumed/focused (frontmost) activity via API19
// `dumpsys activity activities` (or the mCurrentFocus fallback), and record
// UNSUPPORTED honestly on boxes that don't report it — never a fake "resumed".
static void test_activity_resumed(void) {
    const char *comp = "com.jieoz.lanmediawall.player/.MainActivity";
    // API19 `dumpsys activity activities` short form (pkg/.Class).
    const char *ours_short =
        "  Running activities (most recent first):\n"
        "  mResumedActivity: ActivityRecord{40d1 u0 com.jieoz.lanmediawall.player/.MainActivity t7}\n";
    CHECK(lmw_activity_resumed(ours_short, comp) == ACT_RESUMED,
          "our component resumed (short form) -> RESUMED");
    // Fully-qualified class form some ROMs print.
    const char *ours_full =
        "  mFocusedActivity: ActivityRecord{x u0 "
        "com.jieoz.lanmediawall.player/com.jieoz.lanmediawall.player.MainActivity t7}\n";
    CHECK(lmw_activity_resumed(ours_full, comp) == ACT_RESUMED,
          "our component resumed (fully-qualified) -> RESUMED");
    // mCurrentFocus window fallback naming our activity.
    const char *ours_focus =
        "  mCurrentFocus=Window{ab u0 com.jieoz.lanmediawall.player/"
        "com.jieoz.lanmediawall.player.MainActivity}\n";
    CHECK(lmw_activity_resumed(ours_focus, comp) == ACT_RESUMED,
          "mCurrentFocus on our activity -> RESUMED");
    // A DIFFERENT app is frontmost (e.g. the launcher) — process may be up but NOT
    // resumed: this must be OTHER (partial), never a pass.
    const char *launcher =
        "  mResumedActivity: ActivityRecord{9 u0 com.yunos.tv.homeshell/.HomeShellActivity t1}\n";
    CHECK(lmw_activity_resumed(launcher, comp) == ACT_OTHER,
          "launcher resumed, not us -> OTHER");
    // dumpsys present but with NO resumed/focus indicator line at all -> UNSUPPORTED.
    const char *no_indicator =
        "  Stack #0:\n  TaskRecord{...}\n  Hist #0: ActivityRecord{...}\n";
    CHECK(lmw_activity_resumed(no_indicator, comp) == ACT_UNSUPPORTED,
          "no resumed/focus line -> UNSUPPORTED (not a fake pass)");
    CHECK(lmw_activity_resumed("", comp) == ACT_UNSUPPORTED, "empty dumpsys -> UNSUPPORTED");
    CHECK(lmw_activity_resumed(NULL, comp) == ACT_UNSUPPORTED, "NULL dumpsys -> UNSUPPORTED");
    // A resumed line that mentions our PACKAGE only inside another token must not
    // false-positive: a different activity of a look-alike package.
    const char *lookalike =
        "  mResumedActivity: ActivityRecord{1 u0 com.jieoz.lanmediawall.playerx/.Other t2}\n";
    CHECK(lmw_activity_resumed(lookalike, comp) == ACT_OTHER,
          "look-alike package is not our component -> OTHER");
}

static void test_activity_str(void) {
    CHECK(strcmp(lmw_activity_str(ACT_RESUMED), "yes") == 0, "ACT_RESUMED -> yes");
    CHECK(strcmp(lmw_activity_str(ACT_OTHER), "no") == 0, "ACT_OTHER -> no");
    CHECK(strcmp(lmw_activity_str(ACT_UNSUPPORTED), "unsupported") == 0,
          "ACT_UNSUPPORTED -> unsupported");
}

// ---- §restart-state-machine: full-recovery verdict (PROCESS_UP + ACTIVITY) ---
// Locks the two-signal contract: full recovery requires the process up AND the
// activity resumed. If the box cannot report activity state, verification is
// incomplete and must fail closed rather than relabel process-only as recovery.
static void test_restart_fully_recovered(void) {
    CHECK(lmw_restart_fully_recovered(1, ACT_RESUMED) == 1,
          "process up + our activity resumed -> full recovery");
    CHECK(lmw_restart_fully_recovered(1, ACT_UNSUPPORTED) == 0,
          "process up + activity unreportable -> unverified, fail closed");
    CHECK(lmw_restart_fully_recovered(1, ACT_OTHER) == 0,
          "process up but another activity frontmost -> PARTIAL, not recovered");
    CHECK(lmw_restart_fully_recovered(0, ACT_RESUMED) == 0,
          "process NOT up -> never recovered regardless of activity");
    CHECK(lmw_restart_fully_recovered(0, ACT_UNSUPPORTED) == 0,
          "process NOT up + unsupported -> never recovered");
}

static void test_restart_transition_proven(void) {
    CHECK(lmw_restart_transition_proven(1, 100, 200) == 1,
          "clean force-stop plus changed pid proves a restart transition");
    CHECK(lmw_restart_transition_proven(0, 100, 200) == 0,
          "failed force-stop can never be reported as a restart");
    CHECK(lmw_restart_transition_proven(1, 100, 100) == 0,
          "unchanged old pid means no restart occurred");
    CHECK(lmw_restart_transition_proven(1, -1, 200) == 0,
          "missing pre-restart pid cannot prove a restart transition");
}

// ---- CLI mode policy: -restart auth + shared worker + no REBOOT reach ---------
// E0001 gate 1: root-only `-restart` must reject non-root, run the SAME worker as
// socket RESTART_APP, and NO CLI mode may reach the whole-device REBOOT path.
static void test_cli_mode(void) {
    CHECK(lmw_cli_mode("-probe") == CLI_PROBE, "-probe recognized");
    CHECK(lmw_cli_mode("-restart") == CLI_RESTART, "-restart recognized");
    CHECK(lmw_cli_mode("-f") == CLI_SERVE_FG, "-f is foreground serve");
    CHECK(lmw_cli_mode(NULL) == CLI_SERVE, "no arg -> serve (daemonize)");
    CHECK(lmw_cli_mode("-reboot") == CLI_SERVE, "there is NO -reboot cli mode (unknown -> serve)");
    CHECK(lmw_cli_mode("REBOOT") == CLI_SERVE, "REBOOT is a SOCKET verb, not a CLI mode");
}

static void test_cli_mode_requires_root(void) {
    // -restart and both serve modes need root; -probe does not (read-only over socket).
    CHECK(lmw_mode_requires_root(CLI_RESTART) == 1, "-restart requires root");
    CHECK(lmw_mode_requires_root(CLI_SERVE) == 1, "serve requires root");
    CHECK(lmw_mode_requires_root(CLI_SERVE_FG) == 1, "serve -f requires root");
    CHECK(lmw_mode_requires_root(CLI_PROBE) == 0, "-probe does not require root");
}

static void test_cli_mode_no_reboot_reach(void) {
    // Whole-device reboot must be reachable ONLY as an authenticated SOCKET verb,
    // NEVER from any CLI entrypoint. This is the static proof there is no
    // `-reboot`-style flag that could strand a box off Wi-Fi.
    CHECK(lmw_mode_can_reboot(CLI_PROBE) == 0, "-probe cannot reboot");
    CHECK(lmw_mode_can_reboot(CLI_RESTART) == 0, "-restart cannot reboot (app-only)");
    CHECK(lmw_mode_can_reboot(CLI_SERVE) == 0, "serve cli entry cannot itself reboot");
    CHECK(lmw_mode_can_reboot(CLI_SERVE_FG) == 0, "serve -f cannot reboot");
}

int main(void) {
    test_parse_probe();
    test_parse_reboot();
    test_parse_restart_app();
    test_parse_install();
    test_ota_rootfix_contract();
    test_install_path_policy();
    test_peer_authorized();
    test_command_requires_auth();
    test_read_allowed_uid();
    test_pm_success_line();
    test_pm_summary_prefers_failure();
    test_legacy_install_contract();
    test_pm_install_cmd_order();
    test_am_start_failed();
    test_extract_pid();
    test_should_retry_restart();
    test_restart_log_should_rotate();
    test_activity_resumed();
    test_activity_str();
    test_restart_fully_recovered();
    test_restart_transition_proven();
    test_cli_mode();
    test_cli_mode_requires_root();
    test_cli_mode_no_reboot_reach();
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
