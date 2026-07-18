// Executes the production daemon's legacy file transaction in a host sandbox.
// This is a deterministic supplement to, not a substitute for, on-device PM.

#define _GNU_SOURCE
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char target[PATH_MAX];
static char backup[PATH_MAX];
static char temporary[PATH_MAX];
static char incoming[PATH_MAX];

#define LMW_DAEMON_TEST
#define LMW_DAEMON_INTEGRATION_TEST
#define LMW_LEGACY_APK target
#define LMW_LEGACY_BACKUP_APK backup
#define LMW_LEGACY_TMP_APK temporary
#include "../lmw_root_daemon.c"

static int checks;
static int failures;
#define CHECK(condition, text) do { \
    checks++; if (!(condition)) { failures++; printf("FAIL: %s\n", text); } \
} while (0)

static void write_text(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || write(fd, text, strlen(text)) != (ssize_t)strlen(text)) { perror(path); exit(2); }
    close(fd);
}

static int contains(const char *path, const char *expected) {
    char text[64] = {0};
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t size = read(fd, text, sizeof(text) - 1);
    close(fd);
    return size >= 0 && strcmp(text, expected) == 0;
}

static void clear(void) {
    unlink(target); unlink(backup); unlink(temporary); unlink(incoming);
}

int main(void) {
    char root[] = "/tmp/android-ota-sim-XXXXXX";
    char *dir = mkdtemp(root);
    if (!dir) { perror("mkdtemp"); return 2; }
    snprintf(target, sizeof(target), "%s/live.apk", dir);
    snprintf(backup, sizeof(backup), "%s/live.apk.lmw-backup", dir);
    snprintf(temporary, sizeof(temporary), "%s/live.apk.lmw-new", dir);
    snprintf(incoming, sizeof(incoming), "%s/verified.apk", dir);

    // QZX profile behavior: existing target + stale backup is a completed prior
    // activation, so a new stage must commit it and establish a fresh rollback.
    write_text(target, "live-1176"); write_text(backup, "old-67"); write_text(incoming, "next-1177");
    CHECK(lmw_legacy_stage(incoming) == 1, "stale backup cannot block second OTA");
    CHECK(contains(target, "next-1177"), "new APK is atomically promoted");
    CHECK(contains(backup, "live-1176"), "current APK remains rollback backup");
    CHECK(access(temporary, F_OK) != 0, "temporary APK is not left behind");

    // Interrupted old transaction: target vanished after target->backup. Restore
    // it before staging so a subsequent failure cannot erase the last good APK.
    clear(); write_text(backup, "recoverable-live"); write_text(incoming, "next-1177");
    CHECK(lmw_legacy_stage(incoming) == 1, "orphan backup is restored before next stage");
    CHECK(contains(target, "next-1177"), "orphan scenario promotes requested APK");
    CHECK(contains(backup, "recoverable-live"), "orphan scenario keeps rollback bytes");

    clear(); rmdir(dir);
    printf("android_ota_simulator: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}