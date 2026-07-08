// lmw_root_helper.c — setuid-root installer bridge for QZX_C1/YunOS 4.4 boxes.
//
// Why this exists:
//   These boxes expose root to adb/shell but their stock `su` rejects normal app
//   UIDs (`su: uid 10023 not allowed to su`). The PC provisioner can still place
//   a tiny setuid helper owned by root and executable only by the Player app's
//   Linux uid. Future in-app push updates call this helper instead of `su`.
//
// Security model:
//   * chmod 6750 + chown root:<playerUid> in lmw_provision.sh limits execution to
//     the Player app uid at the filesystem layer.
//   * /data/local/tmp/lmw_root_helper.uid is root-owned and must match getuid().
//   * only com.jieoz.lanmediawall.player is accepted.
//   * source APK must live in the Player app's own update cache.
//   * destination is fixed to /data/app/com.jieoz.lanmediawall.player-1.apk.
//
// Build (inside android-builder):
//   $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang \
//     -Os -fPIE -pie -static -s -o scripts/lmw_root_helper scripts/lmw_root_helper.c

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define PKG "com.jieoz.lanmediawall.player"
#define UID_FILE "/data/local/tmp/lmw_root_helper.uid"
#define DST "/data/app/com.jieoz.lanmediawall.player-1.apk"
#define CACHE_PREFIX "/data/data/com.jieoz.lanmediawall.player/cache/update/"

static int fail(const char *msg) {
    fprintf(stderr, "lmw_root_helper: %s: %s\n", msg, strerror(errno));
    return 1;
}

static int fail_msg(const char *msg) {
    fprintf(stderr, "lmw_root_helper: %s\n", msg);
    return 1;
}

static int read_allowed_uid(void) {
    FILE *f = fopen(UID_FILE, "r");
    if (!f) return -1;
    int uid = -1;
    if (fscanf(f, "%d", &uid) != 1) uid = -1;
    fclose(f);
    return uid;
}

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int copy_file(const char *src, const char *dst) {
    int in = open(src, O_RDONLY);
    if (in < 0) return fail("open source apk");

    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        close(in);
        return fail("open destination apk");
    }

    char buf[262144];
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n == 0) break;
        if (n < 0) {
            close(in); close(out);
            return fail("read source apk");
        }
        char *p = buf;
        while (n > 0) {
            ssize_t w = write(out, p, (size_t)n);
            if (w < 0) {
                close(in); close(out);
                return fail("write destination apk");
            }
            p += w;
            n -= w;
        }
    }

    if (fsync(out) != 0) {
        close(in); close(out);
        return fail("fsync destination apk");
    }
    close(in);
    close(out);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        return fail_msg("usage: lmw_root_helper <package> <source-apk>");
    }

    const char *pkg = argv[1];
    const char *src = argv[2];

    if (strcmp(pkg, PKG) != 0) return fail_msg("refusing unknown package");
    if (!starts_with(src, CACHE_PREFIX)) return fail_msg("source apk outside player update cache");

    uid_t ruid = getuid();
    uid_t euid = geteuid();
    int allowed = read_allowed_uid();
    if (allowed <= 0) return fail_msg("missing allowed uid file; reprovision with lmw_update.bat");
    if ((int)ruid != allowed) return fail_msg("caller uid not allowed");
    if (euid != 0) return fail_msg("helper is not setuid root; reprovision with lmw_update.bat");

    struct stat st;
    if (stat(src, &st) != 0) return fail("stat source apk");
    if (!S_ISREG(st.st_mode) || st.st_size <= 0) return fail_msg("source apk missing/empty");

    const char *tmp = DST ".tmp";
    unlink(tmp);
    if (copy_file(src, tmp) != 0) return 1;
    if (chown(tmp, 1000, 1000) != 0) return fail("chown destination apk");
    if (chmod(tmp, 0644) != 0) return fail("chmod destination apk");
    if (rename(tmp, DST) != 0) return fail("rename destination apk");

    sync();
    execl("/system/bin/reboot", "reboot", (char *)NULL);
    execl("/sbin/reboot", "reboot", (char *)NULL);
    return fail("exec reboot");
}
