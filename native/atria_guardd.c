/*
 * atriia_guardd v3.4.86 - C 版高速扫描器 (替代 shell 的 scan_procs+scan_fds+scan_io)
 * 编译: aarch64-linux-gnu-gcc -static -O2 -o atriia_guardd atriia_guardd.c
 * 功能: 一次遍历 /proc, 同时完成 cmdline 危险命令检测 + fd 块设备检测 + syscw 采样
 * 输出: 每行一个命中 "PID\tTYPE\tCMDLINE" (TYPE=wipe_cmd|block_fd|io_burst)
 * syscw 采样: 输出所有应用进程的快照到 sidecar 文件, 差分由调用方做
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>
#include <ctype.h>
#include <sys/stat.h>

#define MAX_CMD 512
#define IO_SNAP "/data/local/tmp/atria_io_snap.txt"
#define IO_PREV "/data/local/tmp/atria_io_prev.txt"

static int is_app_uid(int pid) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/status", pid);
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    char line[256];
    int uid = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "Uid:", 4) == 0) {
            uid = atoi(line + 4);
            break;
        }
    }
    fclose(f);
    return uid >= 10000;
}

static int read_cmdline(int pid, char *out, size_t outsz) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/cmdline", pid);
    int fd = open(p, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, out, outsz - 1);
    close(fd);
    if (n <= 0) return 0;
    out[n] = 0;
    for (ssize_t i = 0; i < n; i++) if (!out[i]) out[i] = ' ';
    return 1;
}

/* 危险命令匹配: 返回 1 = 命中 */
static int match_wipe(const char *c) {
    /* find -delete (软格机) */
    if (strstr(c, "find") && (strstr(c, "-delete") || strstr(c, "-exec rm") || strstr(c, "xargs rm"))) {
        if (strstr(c, "/data") || strstr(c, "/system") || strstr(c, "/sdcard") || strstr(c, "/storage"))
            return 1;
    }
    /* rm -rf 整盘: 简化判定 — rm + -rf + 敏感目录且非子路径 */
    if (strstr(c, "rm") && (strstr(c, "-rf") || strstr(c, "-fr"))) {
        const char *dirs[] = {"/data ", "/system ", "/sdcard ", "/storage ", "/data;", "/system;", "/sdcard;", "/storage;",
                              "/data\"", "/system\"", "/sdcard\"", "/storage\"", "/data'", "/system'", "/sdcard'", "/storage'",
                              "/data", NULL};
        /* 必须是整盘不是子路径: /data 后跟非字母数字斜杠 */
        char *p = strstr(c, "rm");
        while (p) {
            char *d = strstr(p, "/data");
            if (d && (d[5] == 0 || !isalnum((unsigned char)d[5]) || d[5] == ';' || d[5] == '"' || d[5] == '\'')) return 1;
            d = strstr(p, "/system");
            if (d && (d[7] == 0 || !isalnum((unsigned char)d[7]) || d[7] == ';' || d[7] == '"' || d[7] == '\'')) return 1;
            d = strstr(p, "/sdcard");
            if (d && (d[7] == 0 || !isalnum((unsigned char)d[7]) || d[7] == ';' || d[7] == '"' || d[7] == '\'')) return 1;
            p = strstr(p + 1, "rm");
        }
    }
    /* mkfs / dd 块设备 */
    if ((strstr(c, "mkfs") || strstr(c, "mke2fs") || strstr(c, "make_ext4fs")) &&
        (strstr(c, "/dev/block") || strstr(c, "/dev/mmcblk") || strstr(c, "/data") || strstr(c, "/system")))
        return 1;
    if (strstr(c, "dd") && (strstr(c, "if=/dev/block") || strstr(c, "of=/dev/block") ||
        strstr(c, "if=/dev/mmcblk") || strstr(c, "of=/dev/mmcblk")))
        return 1;
    return 0;
}

/* fd 块设备检测: 返回 1 = 打开了 /dev/block */
static int check_block_fd(int pid) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/fd", pid);
    DIR *d = opendir(p);
    if (!d) return 0;
    struct dirent *e;
    int hit = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char fp[128], link[256];
        snprintf(fp, sizeof(fp), "%s/%s", p, e->d_name);
        ssize_t n = readlink(fp, link, sizeof(link) - 1);
        if (n > 0) {
            link[n] = 0;
            if (strncmp(link, "/dev/block/", 11) == 0 || strncmp(link, "/dev/block", 10) == 0) {
                hit = 1;
                break;
            }
        }
    }
    closedir(d);
    return hit;
}

static unsigned long read_syscw(int pid) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%d/io", pid);
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    char line[128];
    unsigned long v = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "syscw:", 6) == 0) {
            v = strtoul(line + 6, NULL, 10);
            break;
        }
    }
    fclose(f);
    return v;
}

int main(void) {
    DIR *d = opendir("/proc");
    if (!d) return 1;
    struct dirent *e;
    FILE *snap = fopen(IO_SNAP, "w");
    while ((e = readdir(d))) {
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        int pid = atoi(e->d_name);
        if (pid <= 1) continue;
        if (pid == getpid() || pid == getppid()) continue;
        char cmd[MAX_CMD];
        if (!read_cmdline(pid, cmd, sizeof(cmd))) continue;
        if (!cmd[0]) continue;
        /* 数据载体豁免 */
        if (!strncmp(cmd, "curl ", 5) || !strncmp(cmd, "wget ", 5) ||
            !strncmp(cmd, "python ", 7) || !strncmp(cmd, "python3 ", 8) || !strncmp(cmd, "node ", 5))
            continue;
        int app = is_app_uid(pid);
        /* 1. cmdline 危险命令 (所有进程) */
        if (match_wipe(cmd)) {
            printf("%d\twipe_cmd\t%s\n", pid, cmd);
        }
        /* 2. fd 块设备 (仅应用进程) */
        if (app && check_block_fd(pid)) {
            printf("%d\tblock_fd\t%s\n", pid, cmd);
        }
        /* 3. syscw 采样 (仅应用进程, 写快照) */
        if (app && snap) {
            unsigned long sw = read_syscw(pid);
            if (sw) fprintf(snap, "%d:%lu\n", pid, sw);
        }
    }
    closedir(d);
    if (snap) fclose(snap);
    return 0;
}
