/* Atria Monitor v3.2.97 - C 采集端原型
 * 替代 collect.sh 的核心指标采集: mem/cpu/thermal/battery/storage/net/processes
 * 输出与 shell 版完全兼容的 JSON
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>
#include <ctype.h>
#include <sys/statfs.h>
#include <sys/stat.h>

/* ---- 工具: 读文件第一行 / 数字 ---- */
static long read_num_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long v = 0; int n = fscanf(f, "%ld", &v);
    fclose(f);
    return (n == 1) ? v : -1;
}

static int read_line(const char *path, char *buf, size_t sz) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    buf[0] = 0;
    char *r = fgets(buf, sz, f);
    fclose(f);
    return r ? 0 : -1;
}

/* ---- 内存: /proc/meminfo ---- */
static int collect_mem(long *total_mb, long *avail_mb) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return -1;
    char line[256];
    long t = -1, a = -1;
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "MemTotal:", 9)) t = atol(line + 9) / 1024;
        else if (!strncmp(line, "MemAvailable:", 13)) a = atol(line + 13) / 1024;
    }
    fclose(f);
    if (t < 0 || a < 0) return -1;
    *total_mb = t; *avail_mb = a;
    return 0;
}

/* v3.2.29: 移除死代码 cpu_jiffies() (返回 0 且未被调用, main 内自带两段采样) */

/* ---- 温度: /sys/class/thermal/thermal_zoneN/{temp,type} 聚合 ---- */
typedef struct { char label[32]; long max; long min; int count; } therm_t;

static int collect_thermal(therm_t *out, int max_out) {
    DIR *d = opendir("/sys/class/thermal");
    if (!d) return 0;
    struct dirent *e;
    int n = 0;
    char path[256], type[64];
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "thermal_zone", 12) != 0) continue;
        snprintf(path, sizeof(path), "/sys/class/thermal/%s/type", e->d_name);
        if (read_line(path, type, sizeof(type)) != 0) continue;
        /* 去尾部换行 */
        for (char *p = type; *p; p++) if (*p == '\n') *p = 0;
        snprintf(path, sizeof(path), "/sys/class/thermal/%s/temp", e->d_name);
        long t = read_num_file(path);
        /* v3.2.27: 温度有效范围 0.1°C~150°C (100~150000 millicelsius), 过滤坏传感器 (0/超低值) */
        if (t <= 1000 || t > 150000) continue;   /* v3.2.27: <1°C 或 >150°C 视为坏传感器 */
        /* 归类 */
        /* v3.2.18: 归类规则与 shell 版 awk 完全对齐 */
        const char *grp = "other";
        const char *low = type;
        /* v3.2.20: cpu 归类大小写不敏感 + 常见内核名称 */
        if (strncasecmp(type, "cpu", 3) == 0 || strncmp(type, "silver", 6) == 0 ||
            strncmp(type, "gold", 4) == 0 || strncmp(type, "prime", 5) == 0 ||
            strncmp(type, "bronze", 6) == 0 || strncmp(type, "big", 3) == 0 ||
            strncmp(type, "little", 6) == 0 || strncmp(type, "core", 4) == 0 ||
            strncmp(type, "soc", 3) == 0 || strncmp(type, "apc", 3) == 0 ||
            strncmp(type, "denve", 5) == 0) grp = "cpu";
        else if (strncmp(type, "gpu", 3) == 0 || strcasestr(low, "gpu")) grp = "gpu";
        else if (strstr(type, "modem") || strstr(type, "mdm")) grp = "modem";
        else if (strstr(type, "skin") || strstr(type, "surface") ||
                 strcmp(type, "xd") == 0 || strncmp(type, "xo-", 3) == 0) grp = "skin";
        else if (strstr(type, "batt") || strcasestr(low, "battery")) grp = "batt";
        else if (strstr(type, "charge") || strstr(type, "usb") || strncmp(type, "pa_", 3) == 0) grp = "charger";
        else if (strstr(type, "wifi") || strstr(type, "wlan")) grp = "wifi";
        else if (strstr(type, "dsp") || strstr(type, "nsp") || strstr(type, "adsp")) grp = "dsp";
        /* v3.3.4: 高通平台扩展类 (与 shell awk 版同步) */
        else if (strncmp(type, "aoss", 4) == 0 || strncmp(type, "cpuss", 5) == 0 ||
                 strncmp(type, "socd", 4) == 0) grp = "cpu";
        else if (strncmp(type, "shell_", 6) == 0 || strncmp(type, "shell-", 6) == 0) grp = "skin";
        else if (strncmp(type, "camera", 6) == 0 || strncmp(type, "cam-", 4) == 0) grp = "camera";
        else if (strncmp(type, "video", 5) == 0 || strncmp(type, "ddr", 3) == 0) grp = "chipset";
        /* 已存在的类别累积 */
        int i;
        for (i = 0; i < n; i++) {
            if (strcmp(out[i].label, grp) == 0) {
                if (t > out[i].max) out[i].max = t;
                if (t < out[i].min) out[i].min = t;
                out[i].count++;
                break;
            }
        }
        if (i == n && n < max_out) {
            strncpy(out[n].label, grp, sizeof(out[n].label) - 1);
            out[n].max = out[n].min = t;
            out[n].count = 1;
            n++;
        }
    }
    closedir(d);
    return n;
}

/* ---- 电池: /sys/class/power_supply/battery/uevent ---- */
static int collect_battery(long *cap, char *status, size_t ssz, long *temp) {
    FILE *f = fopen("/sys/class/power_supply/battery/uevent", "r");
    if (!f) f = fopen("/sys/class/power_supply/bms/uevent", "r");
    if (!f) return -1;
    char line[256];
    *cap = -1; *temp = -1; status[0] = 0;
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "POWER_SUPPLY_CAPACITY=", 22)) *cap = atol(line + 22);
        else if (!strncmp(line, "POWER_SUPPLY_STATUS=", 20)) {
            char *s = line + 20;
            for (char *p = s; *p; p++) if (*p == '\n') *p = 0;
            strncpy(status, s, ssz - 1);
        }
        else if (!strncmp(line, "POWER_SUPPLY_TEMP=", 18)) {
            *temp = atol(line + 18) / 10;
            /* v3.2.22: 部分内核驱动 TEMP 是 millicelsius, 标准是 1/10 度; >200 判定为 millicelsius */
            if (*temp > 200) *temp = *temp / 100;
        }
    }
    fclose(f);
    return (*cap >= 0) ? 0 : -1;
}

/* v3.2.29: CPU 单次采样 (busy/total), 供两次差值计算 */
static void cpu_sample(long *busy, long *total) {
    long u = 0, n_ = 0, sy = 0, id_ = 0, io = 0, iq = 0, si = 0, st = 0;
    FILE *f = fopen("/proc/stat", "r");
    if (f) {
        char ln[512];
        if (fgets(ln, sizeof(ln), f)) sscanf(ln, "cpu %ld %ld %ld %ld %ld %ld %ld %ld", &u, &n_, &sy, &id_, &io, &iq, &si, &st);
        fclose(f);
    }
    *busy = u + n_ + sy + iq + si + st;
    *total = *busy + id_ + io;
}

/* v3.3.4: GPU (Adreno/标准 devfreq) - clock/busy, 无则跳过 */
/* v3.3.5: GPU 多平台通用探测
 * 高通 Adreno: /sys/class/kgsl/kgsl-3d0/clock_mhz (MHz)
 * 联发科 Mali: /sys/class/misc/mali0/device/clock 或 devfreq 的 cur_freq (Hz)
 * 三星:        /sys/kernel/gpu/gpu_clock (MHz)
 * 通用 devfreq: /sys/class/devfreq 下 gpu/mali/g3d 节点的 cur_freq (Hz)
 * busy: Adreno gpu_busy_percentage / Mali gpu_utilisation / 通用 gpu_load
 * 单位统一为 MHz; 探测失败返回 -1, 调用方不输出 gpu 字段 */
static int collect_gpu(long *clock_mhz, long *busy_pct) {
    *clock_mhz = -1; *busy_pct = -1;
    /* ---- 时钟: 4 级 fallback ---- */
    /* 1) 高通 Adreno (已是 MHz) */
    FILE *f = fopen("/sys/class/kgsl/kgsl-3d0/clock_mhz", "r");
    if (!f) f = fopen("/sys/class/kgsl/kgsl-3d0/gpuclk", "r");
    if (f) { if (fscanf(f, "%ld", clock_mhz) != 1) *clock_mhz = -1; fclose(f); }
    /* 2) 三星 Exynos (/sys/kernel/gpu/, 已是 MHz) */
    if (*clock_mhz < 0) {
        f = fopen("/sys/kernel/gpu/gpu_clock", "r");
        if (f) { if (fscanf(f, "%ld", clock_mhz) != 1) *clock_mhz = -1; fclose(f); }
    }
    /* 3) 联发科 Mali (/sys/class/misc/mali0/device/, Hz -> MHz) */
    if (*clock_mhz < 0) {
        f = fopen("/sys/class/misc/mali0/device/clock", "r");
        if (!f) f = fopen("/sys/class/misc/mali0/device/freq", "r");
        if (f) {
            long hz = -1;
            if (fscanf(f, "%ld", &hz) == 1 && hz > 100000) *clock_mhz = hz / 1000000;
            fclose(f);
        }
    }
    /* 4) 通用 devfreq (扫描 /sys/class/devfreq/, 找 gpu/mali/g3d 节点, Hz -> MHz) */
    if (*clock_mhz < 0) {
        DIR *d = opendir("/sys/class/devfreq");
        if (d) {
            struct dirent *e;
            char path[256];
            while ((e = readdir(d)) != NULL) {
                const char *nm = e->d_name;
                if (nm[0] == '.') continue;
                /* 联发科: 11280000.mali / 三星: g3d / 高通: kgsl-3d0 */
                if (!strstr(nm, "mali") && !strstr(nm, "g3d") && !strstr(nm, "kgsl") && !strstr(nm, "gpu")) continue;
                snprintf(path, sizeof(path), "/sys/class/devfreq/%s/cur_freq", nm);
                f = fopen(path, "r");
                if (f) {
                    long hz = -1;
                    if (fscanf(f, "%ld", &hz) == 1 && hz > 100000) *clock_mhz = hz / 1000000;
                    fclose(f);
                    if (*clock_mhz >= 0) break;
                }
            }
            closedir(d);
        }
    }
    /* ---- busy: 3 级 fallback ---- */
    f = fopen("/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage", "r");
    if (!f) {
        /* 联发科 Mali: gpu_utilisation (0-100 或 0-256) */
        f = fopen("/sys/class/misc/mali0/device/gpu_utilisation", "r");
    }
    if (!f) {
        /* 通用 devfreq gpu_load 或三星 gpu_busy */
        f = fopen("/sys/class/devfreq/3d00000.qcom,kgsl-3d0/gpu_load", "r");
        if (!f) f = fopen("/sys/kernel/gpu/gpu_busy", "r");
    }
    if (f) {
        if (fscanf(f, "%ld", busy_pct) != 1) *busy_pct = -1;
        fclose(f);
        if (*busy_pct > 1000) *busy_pct = *busy_pct * 100 / 256;  /* Mali 0-256 归一化 */
        if (*busy_pct > 100) *busy_pct = 100;
    }
    return (*clock_mhz >= 0) ? 0 : -1;
}
/* v3.3.4: CPU 多集群频率 (大中小核各自当前/最大频率, 最多 4 集群) */
typedef struct { int cpu; long cur, max_; } cfreq_t;
static int collect_cpu_clusters(cfreq_t *out, int max_out) {
    int n = 0;
    for (int c = 0; c < 16 && n < max_out; c++) {
        char p[192];
        snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", c);
        long cur = read_num_file(p);
        if (cur <= 0) continue;
        snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_max_freq", c);
        long mx = read_num_file(p);
        out[n].cpu = c; out[n].cur = cur; out[n].max_ = (mx > 0) ? mx : cur;
        n++;
    }
    return n;
}
/* v3.2.21: JSON 字符串转义 - 进程名含 " \ 控制字符时必须转义, 否则整个 JSON 破损 */
static void json_escape(char *dst, size_t sz, const char *src) {
    size_t o = 0;
    for (size_t i = 0; src[i] && o + 6 < sz; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '"') { dst[o++] = '\\'; dst[o++] = '"'; }
        else if (c == '\\') { dst[o++] = '\\'; dst[o++] = '\\'; }
        else if (c == '\n') { dst[o++] = '\\'; dst[o++] = 'n'; }
        else if (c == '\r') { dst[o++] = '\\'; dst[o++] = 'r'; }
        else if (c == '\t') { dst[o++] = '\\'; dst[o++] = 't'; }
        else if (c < 0x20) { continue; }   /* 其他控制字符丢弃 */
        else dst[o++] = c;
    }
    dst[o] = 0;
}

/* ---- storage: statfs("/data") ---- */
static double pct_of(double used, double total) { return total > 0 ? used * 100.0 / total : 0; }

/* ---- net: /proc/net/dev ---- */
typedef struct { char dev[16]; long rx, tx; } net_t;

static int collect_net(net_t *out, int max_out) {
    FILE *f = fopen("/proc/net/dev", "r");
    if (!f) return 0;
    char line[512];
    int n = 0;
    fgets(line, sizeof(line), f); fgets(line, sizeof(line), f);
    while (fgets(line, sizeof(line), f) && n < max_out) {
        char *colon = strchr(line, ':');
        if (!colon) continue;
        *colon = 0;
        char *d = line; while (*d == ' ') d++;
        char *e = d + strlen(d) - 1; while (e > d && *e == ' ') *e-- = 0;
        long rx = 0, tx = 0;
        sscanf(colon + 1, "%ld %*ld %*ld %*ld %*ld %*ld %*ld %*ld %ld", &rx, &tx);
        if (strncmp(d, "lo", 2) == 0) continue;   /* 回环口跳过 */
        /* v3.2.27: 排除内核虚拟接口 (dummy/tunl/gre/erspan/sit/ip_vti/ip6tnl/ip6gre/ifb/ovnet), 只留真实网卡 */
        if (strncmp(d, "dummy", 5) == 0 || strncmp(d, "tunl", 4) == 0 || strncmp(d, "gre", 3) == 0 ||
            strncmp(d, "erspan", 6) == 0 || strncmp(d, "ip6tnl", 6) == 0 || strncmp(d, "sit", 3) == 0 ||
            strncmp(d, "ip_vti", 6) == 0 || strncmp(d, "ip6_vti", 7) == 0 || strncmp(d, "ip6gre", 6) == 0 ||
            strncmp(d, "ifb", 3) == 0 || strncmp(d, "ovnet", 5) == 0) continue;
        strncpy(out[n].dev, d, sizeof(out[n].dev) - 1);
        out[n].rx = rx; out[n].tx = tx;
        n++;
    }
    fclose(f);
    return n;
}

/* ---- processes: /proc/<pid>/ ---- */
typedef struct { int pid; char name[64]; long rss_kb; char stat; } proc_t;

static int cmp_proc(const void *a, const void *b) {
    return ((const proc_t *)b)->rss_kb - ((const proc_t *)a)->rss_kb;
}

static int collect_procs(proc_t *out, int max_out) {
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        int pid = atoi(e->d_name);
        char path[128], line[512];
        snprintf(path, sizeof(path), "/proc/%d/status", pid);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char name[64] = ""; long rss = 0;
        while (fgets(line, sizeof(line), f)) {
            if (!strncmp(line, "Name:", 5)) {
                char *v = line + 5; while (*v == ' ' || *v == '\t') v++;
                char *p = v; while (*p && *p != '\n') p++; *p = 0;
                strncpy(name, v, sizeof(name) - 1);
            } else if (!strncmp(line, "VmRSS:", 6)) {
                rss = atol(line + 6);
            }
        }
        fclose(f);
        if (rss < 10240) continue;
        /* v3.2.27: 优先用 /proc/pid/cmdline 取完整包名 (comm 只有 15 字符, 会截断) */
        char cpath[128], cline[256];
        snprintf(cpath, sizeof(cpath), "/proc/%d/cmdline", pid);
        FILE *cf = fopen(cpath, "r");
        if (cf) {
            size_t cn = fread(cline, 1, sizeof(cline) - 1, cf);
            fclose(cf);
            cline[cn] = 0;
            /* cmdline 参数以 \0 分隔, 取第一段; 为空则退回 comm */
            char *sp = strchr(cline, '\\0');
            if (sp) *sp = 0;
            if (cline[0]) strncpy(name, cline, sizeof(name) - 1);
        }
        char st = 'S';
        snprintf(path, sizeof(path), "/proc/%d/stat", pid);
        f = fopen(path, "r");
        if (f) {
            if (fgets(line, sizeof(line), f)) {
                char *lp = strrchr(line, ')');
                if (lp && lp[1] == ' ') st = lp[2];
            }
            fclose(f);
        }
        if (n < max_out) {
            out[n].pid = pid; strncpy(out[n].name, name, sizeof(out[n].name) - 1);
            out[n].rss_kb = rss; out[n].stat = st;
            n++;
        }
    }
    closedir(d);
    qsort(out, n, sizeof(proc_t), cmp_proc);
    return n;
}

/* ---- 主: 输出 JSON ---- */
int main(void) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    long total_mb = 0, avail_mb = 0;
    int has_mem = (collect_mem(&total_mb, &avail_mb) == 0);
    long used_mb = has_mem ? (total_mb - avail_mb) : 0;
    int mem_pct = has_mem ? (int)(used_mb * 100 / total_mb) : 0;

    therm_t th[16];
    int nth = collect_thermal(th, 16);

    long cap = -1, btemp = -1; char bstat[32] = "";
    int has_batt = (collect_battery(&cap, bstat, sizeof(bstat), &btemp) == 0);

    struct statfs sf;
    int has_st = (statfs("/data", &sf) == 0);
    double st_total_gb = 0, st_free_gb = 0, st_pct = 0;
    if (has_st && sf.f_blocks > 0) {
        st_total_gb = (double)sf.f_blocks * sf.f_bsize / 1073741824.0;
        st_free_gb = (double)sf.f_bfree * sf.f_bsize / 1073741824.0;
        st_pct = pct_of(st_total_gb - st_free_gb, st_total_gb);
    }
    net_t nets[16];
    int nnets = collect_net(nets, 16);
    proc_t procs[80];
    int nprocs = collect_procs(procs, 80);

    /* v3.2.29: CPU 采样提取为函数, 间隔 100ms->60ms (更跟手, 总采集耗时再降 40ms) */
    long b1 = 0, t1_ = 0, b2 = 0, t2_ = 0;
    cpu_sample(&b1, &t1_);
    usleep(60000);
    cpu_sample(&b2, &t2_);
    int cpu_pct = (t2_ > t1_) ? (int)((b2 - b1) * 100 / (t2_ - t1_)) : 0;   /* v3.2.21: 去除冗余条件 */
    /* v3.3.4: GPU + CPU 集群 (机型适配: 无对应 sysfs 时字段不存在, 前端自动跳过) */
    long gpu_clk = -1, gpu_busy = -1;
    int has_gpu = (collect_gpu(&gpu_clk, &gpu_busy) == 0);
    cfreq_t cf[4];
    int ncf = collect_cpu_clusters(cf, 4);
    if (cpu_pct < 0) cpu_pct = 0;
    if (cpu_pct > 100) cpu_pct = 100;

    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;

    char *buf = malloc(16384);   /* v3.2.27: 4096 会溢出截断 (真机 60 进程+16 网卡) */
    int off = 0;
    off += sprintf(buf + off, "{");
    off += sprintf(buf + off, "\"device_id\":\"C-collector\",");
    off += sprintf(buf + off, "\"timestamp\":%ld,", time(NULL));
    off += sprintf(buf + off, "\"mem\":{\"total_mb\":%ld,\"used_mb\":%ld,\"percent\":%d},", total_mb, used_mb, mem_pct);
    off += sprintf(buf + off, "\"cpu\":{\"percent\":%d},", cpu_pct);
    if (has_gpu) {
        off += sprintf(buf + off, "\"gpu\":{\"clock_mhz\":%ld,\"busy_pct\":%ld},", gpu_clk, gpu_busy);
    }
    if (ncf > 0) {
        off += sprintf(buf + off, "\"cpu_clusters\":[");
        for (int i = 0; i < ncf; i++) {
            off += sprintf(buf + off, "%s{\"cpu\":%d,\"cur_khz\":%ld,\"max_khz\":%ld}",
                           i ? "," : "", cf[i].cpu, cf[i].cur, cf[i].max_);
        }
        off += sprintf(buf + off, "],");
    }
    off += sprintf(buf + off, "\"thermal\":[");
    for (int i = 0; i < nth; i++) {
        off += sprintf(buf + off, "%s{\"label\":\"%s\",\"temp\":%.1f,\"min\":%.1f,\"count\":%d}",
                       i ? "," : "", th[i].label, th[i].max / 1000.0, th[i].min / 1000.0, th[i].count);
    }
    off += sprintf(buf + off, "],");
    if (has_batt) {
        off += sprintf(buf + off, "\"battery\":{\"capacity\":%ld,\"status\":\"%s\",\"temperature\":%.1f},",
                       cap, bstat, (double)btemp);
    } else {
        off += sprintf(buf + off, "\"battery\":{},");
    }
    if (has_st) {
        off += sprintf(buf + off, "\"storage\":[{\"mount\":\"/data\",\"total_gb\":%.2f,\"used_gb\":%.2f,\"free_gb\":%.2f,\"percent\":%.1f}],",
                       st_total_gb, st_total_gb - st_free_gb, st_free_gb, st_pct);
    } else off += sprintf(buf + off, "\"storage\":[],");
    off += sprintf(buf + off, "\"net\":[");
    for (int i = 0; i < nnets; i++) {
        off += sprintf(buf + off, "%s{\"dev\":\"%s\",\"rx_bytes\":%ld,\"tx_bytes\":%ld}",
                       i ? "," : "", nets[i].dev, nets[i].rx, nets[i].tx);
    }
    off += sprintf(buf + off, "],\"processes\":[");
    for (int i = 0; i < nprocs && i < 60; i++) {
        char esc_name[128];
        json_escape(esc_name, sizeof(esc_name), procs[i].name);
        /* v3.2.27: 缓冲区边界检查, 剩余 < 200 字节时停止 (防溢出截断) */
        if (off > 16000) break;
        off += sprintf(buf + off, "%s{\"pid\":%d,\"name\":\"%s\",\"rss_mb\":%ld,\"stat\":\"%c\"}",
                       i ? "," : "", procs[i].pid, esc_name, procs[i].rss_kb / 1024, procs[i].stat);
    }
    off += sprintf(buf + off, "],\"logcat\":[],\"modules\":[]");
    off += sprintf(buf + off, "}");
    puts(buf);
    fprintf(stderr, "[atria] 采集耗时 %ld ms\n", ms);
    free(buf);
    return 0;
}
