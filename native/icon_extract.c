/* Atria Monitor v3.2.44 - APK icon extractor (part 1: utils, string pool, AXML, zip)
 * Extracts launcher icons from APK (zip) archives.
 *   PNG/WEBP/JPG entries are copied verbatim; VectorDrawable (with gradient
 *   references) is converted to SVG.
 * Build: gcc -static -O2 -o icon_extract_c_arm64 icon_extract.c -lz
 * Usage:
 *   icon_extract <apk> <outdir>                 single APK; writes <stem>_icon.<ext>
 *   icon_extract --whitelist <conf> <outdir>   batch; writes <pkg>.<ext> per package
 * Env: ICON_VERBOSE=1 prints candidate resolutions.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <stdarg.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <zlib.h>

#define MAXPKGS  16
#define MAXCAND  512
#define MAXGRAD  16
#define MAXSTOPS 16
#define MAXPATHS 32

static int g_verbose = 0;

static uint16_t u16(const uint8_t *b, size_t o){ return (uint16_t)(b[o] | ((uint16_t)b[o + 1] << 8)); }
static uint32_t u32(const uint8_t *b, size_t o){
    return (uint32_t)b[o] | ((uint32_t)b[o + 1] << 8) | ((uint32_t)b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24);
}
static float f32v(uint32_t v){ float f; memcpy(&f, &v, sizeof(f)); return f; }

static void *xmalloc(size_t n){ void *p = malloc(n); if (!p){ fprintf(stderr, "[icon] out of memory\n"); exit(1); } return p; }
static void *xcalloc(size_t n, size_t s){ void *p = calloc(n ? n : 1, s); if (!p){ fprintf(stderr, "[icon] out of memory\n"); exit(1); } return p; }
static void *xrealloc(void *p, size_t n){ void *q = realloc(p, n); if (!q){ fprintf(stderr, "[icon] out of memory\n"); exit(1); } return q; }

/* ---------- string pool ---------- */
typedef struct { char **items; int n; } Pool;

static char *utf16_to_utf8(const uint8_t *p, uint32_t n){
    size_t cap = (size_t)n * 3 + 8;
    char *out = xmalloc(cap);
    size_t k = 0;
    for (uint32_t i = 0; i < n; i++){
        uint32_t u = u16(p, (size_t)i * 2);
        if (u >= 0xD800 && u <= 0xDBFF && i + 1 < n){
            uint32_t lo = u16(p, (size_t)(i + 1) * 2);
            if (lo >= 0xDC00 && lo <= 0xDFFF){ u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00); i++; }
        }
        if (k + 5 > cap){ cap *= 2; out = xrealloc(out, cap); }
        if (u < 0x80) out[k++] = (char)u;
        else if (u < 0x800){ out[k++] = (char)(0xC0 | (u >> 6)); out[k++] = (char)(0x80 | (u & 0x3F)); }
        else if (u < 0x10000){ out[k++] = (char)(0xE0 | (u >> 12)); out[k++] = (char)(0x80 | ((u >> 6) & 0x3F)); out[k++] = (char)(0x80 | (u & 0x3F)); }
        else { out[k++] = (char)(0xF0 | (u >> 18)); out[k++] = (char)(0x80 | ((u >> 12) & 0x3F)); out[k++] = (char)(0x80 | ((u >> 6) & 0x3F)); out[k++] = (char)(0x80 | (u & 0x3F)); }
    }
    out[k] = 0;
    return out;
}

/* buf/off: chunk starts at off; blen: total buffer length for bounds */
static void pool_parse(const uint8_t *buf, size_t off, size_t blen, Pool *p){
    memset(p, 0, sizeof(*p));
    if (off + 28 > blen) return;
    uint32_t n = u32(buf, off + 8);
    uint32_t flags = u32(buf, off + 16);
    uint32_t start = u32(buf, off + 20);
    int is8 = (flags & 0x100) != 0;
    size_t base = off + start;
    if (n > 0x1000000) n = 0x1000000; /* sanity cap */
    p->items = xcalloc(n, sizeof(char *));
    p->n = (int)n;
    for (uint32_t i = 0; i < n; i++){
        if (off + 28 + (size_t)i * 4 + 4 > blen){ p->items[i] = strdup("<bad>"); continue; }
        uint32_t spo = u32(buf, off + 28 + (size_t)i * 4);
        size_t pp = base + spo;
        if (pp + 2 >= blen){ p->items[i] = strdup("<bad>"); continue; }
        if (is8){
            uint32_t c = buf[pp]; size_t q = pp + 1;
            if (c & 0x80){
                if (q + 1 > blen){ p->items[i] = strdup("<bad>"); continue; }
                c = ((c & 0x7f) << 8) | buf[q]; q++;
            }
            if (q + 1 > blen){ p->items[i] = strdup("<bad>"); continue; }
            uint32_t bl = buf[q]; q++;
            if (bl & 0x80){
                if (q + 1 > blen){ p->items[i] = strdup("<bad>"); continue; }
                bl = ((bl & 0x7f) << 8) | buf[q]; q++;
            }
            if (q + bl > blen) bl = (uint32_t)(blen - q);
            char *s = xmalloc((size_t)bl + 1);
            memcpy(s, buf + q, bl);
            s[bl] = 0;
            p->items[i] = s;
        } else {
            uint32_t c = u16(buf, pp);
            size_t s0 = pp + 2;
            size_t s1 = s0 + (size_t)c * 2;
            if (s1 > blen) s1 = blen;
            if (s0 > s1) s0 = s1;
            p->items[i] = utf16_to_utf8(buf + s0, (uint32_t)((s1 - s0) / 2));
        }
    }
}

/* ---------- AXML (binary xml) ---------- */
typedef struct { char *name; uint8_t dt; uint32_t data; } Attr;
typedef struct { int end; char *name; Attr *attrs; int na; } Ev;
typedef struct { Pool sp; Ev *ev; int ne; } Axml;

static const Attr *attr_of(const Ev *e, const char *name){
    for (int i = 0; i < e->na; i++)
        if (e->attrs[i].name && !strcmp(e->attrs[i].name, name)) return &e->attrs[i];
    return NULL;
}

static void axml_free(Axml *ax){
    if (ax->ev){
        for (int i = 0; i < ax->ne; i++) free(ax->ev[i].attrs);
        free(ax->ev);
    }
    if (ax->sp.items){
        for (int i = 0; i < ax->sp.n; i++) free(ax->sp.items[i]);
        free(ax->sp.items);
    }
    memset(ax, 0, sizeof(*ax));
}

/* returns 0 if at least one element chunk parsed */
static int axml_parse(const uint8_t *buf, size_t len, Axml *ax){
    memset(ax, 0, sizeof(*ax));
    if (len < 8 || u16(buf, 0) != 0x0003) return -1;
    size_t pos = u16(buf, 2);
    size_t end = len;
    Ev *ev = NULL; int nev = 0, cap = 0;
    Pool sp; memset(&sp, 0, sizeof(sp));
    while (pos + 8 <= end){
        uint16_t ct = u16(buf, pos);
        uint32_t csz = u32(buf, pos + 4);
        if (csz < 8) break;
        if ((size_t)pos + csz > end) break;
        if (ct == 0x0001){
            pool_parse(buf, pos, len, &sp);
        } else if (ct == 0x0102){
            uint32_t ni = u32(buf, pos + 20);
            uint16_t astart = u16(buf, pos + 24);
            uint16_t asize = u16(buf, pos + 26);
            uint16_t acount = u16(buf, pos + 28);
            if (asize < 20) asize = 20;
            if (nev == cap){ cap = cap ? cap * 2 : 64; ev = xrealloc(ev, (size_t)cap * sizeof(Ev)); }
            Ev *e = &ev[nev++];
            e->end = 0;
            e->name = (sp.items && ni < (uint32_t)sp.n) ? sp.items[ni] : "?";
            e->na = acount;
            e->attrs = xcalloc(acount, sizeof(Attr));
            size_t chunkEnd = (size_t)pos + csz;
            int k = 0;
            for (uint16_t i = 0; i < acount; i++){
                size_t a = (size_t)pos + 16 + (size_t)astart + (size_t)i * asize;
                if (a + 20 > chunkEnd) break;
                uint32_t an = u32(buf, a + 4);
                e->attrs[k].name = (sp.items && an < (uint32_t)sp.n) ? sp.items[an] : "?";
                e->attrs[k].dt = buf[a + 15];
                e->attrs[k].data = u32(buf, a + 16);
                k++;
            }
            e->na = k;
        } else if (ct == 0x0103){
            if (nev == cap){ cap = cap ? cap * 2 : 64; ev = xrealloc(ev, (size_t)cap * sizeof(Ev)); }
            Ev *e = &ev[nev++];
            e->end = 1; e->name = NULL; e->attrs = NULL; e->na = 0;
        }
        pos += csz;
    }
    ax->sp = sp; ax->ev = ev; ax->ne = nev;
    return (nev > 0) ? 0 : -1;
}

/* ---------- zip ---------- */
typedef struct { int fd; const uint8_t *base; size_t size; size_t cd; uint32_t count; } Zip;

static void zip_close(Zip *z){
    if (z->base && z->base != MAP_FAILED) munmap((void *)z->base, z->size);
    if (z->fd >= 0) close(z->fd);
    memset(z, 0, sizeof(*z));
    z->fd = -1;
}

static int zip_open(Zip *z, const char *path){
    memset(z, 0, sizeof(*z));
    z->fd = -1;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 22){ close(fd); return -1; }
    size_t size = (size_t)st.st_size;
    const uint8_t *base = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (base == MAP_FAILED){ close(fd); return -1; }
    z->fd = fd; z->base = base; z->size = size;
    size_t lo = (size >= 65558) ? size - 65558 : 0;
    long eocd = -1;
    for (size_t o = lo; o + 22 <= size; o++){
        if (u32(base, o) == 0x06054b50){ eocd = (long)o; break; }
    }
    if (eocd < 0){ zip_close(z); return -1; }
    uint32_t cd_count = u16(base, (size_t)eocd + 8);
    uint32_t cd_off = u32(base, (size_t)eocd + 16);
    if (cd_count == 0xffff || cd_off == 0 || (size_t)cd_off >= size){ zip_close(z); return -1; }
    z->cd = cd_off;
    z->count = cd_count;
    return 0;
}

static int zip_has(Zip *z, const char *name){
    size_t p = z->cd;
    for (uint32_t i = 0; i < z->count; i++){
        if (p + 46 > z->size) return 0;
        if (u32(z->base, p) != 0x02014b50) return 0;
        uint16_t nlen = u16(z->base, p + 28);
        uint16_t elen = u16(z->base, p + 30);
        uint16_t clen = u16(z->base, p + 32);
        if ((size_t)p + 46 + nlen > z->size) return 0;
        if (strlen(name) == nlen && memcmp(name, z->base + p + 46, nlen) == 0) return 1;
        size_t next = p + 46 + nlen + elen + clen;
        if (next <= p) return 0;
        p = next;
    }
    return 0;
}

/* raw deflate inflate; want = expected usize (0 = unknown, grow dynamically) */
static uint8_t *inflate_raw(const uint8_t *src, size_t slen, uint32_t want, uint32_t *got){
    size_t cap = want ? want : 65536;
    if (cap > 256u * 1024u * 1024u) return NULL;
    uint8_t *out = xmalloc(cap);
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, -15) != Z_OK){ free(out); return NULL; }
    zs.next_in = (Bytef *)src;
    zs.avail_in = (uInt)slen;
    zs.next_out = out;
    zs.avail_out = (uInt)cap;
    int rc = Z_OK;
    while (rc != Z_STREAM_END){
        rc = inflate(&zs, Z_NO_FLUSH);
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK && rc != Z_BUF_ERROR){ inflateEnd(&zs); free(out); return NULL; }
        if (zs.avail_out == 0){
            if (cap >= 256u * 1024u * 1024u){ inflateEnd(&zs); free(out); return NULL; }
            cap *= 2;
            out = xrealloc(out, cap);
            zs.next_out = out + zs.total_out;
            zs.avail_out = (uInt)(cap - zs.total_out);
        } else if (rc == Z_BUF_ERROR && zs.avail_in == 0){
            break; /* truncated stream: keep what we got */
        }
    }
    *got = (uint32_t)zs.total_out;
    int ok = (want == 0) || (*got == want);
    inflateEnd(&zs);
    if (!ok){ free(out); return NULL; }
    return out;
}

/* returns malloc'd copy of entry contents, or NULL */
static uint8_t *zip_read(Zip *z, const char *name, uint32_t *outlen){
    size_t p = z->cd;
    for (uint32_t i = 0; i < z->count; i++){
        if (p + 46 > z->size) break;
        if (u32(z->base, p) != 0x02014b50) break;
        uint16_t method = u16(z->base, p + 10);
        /* CD csize/usize are authoritative; local header may be zeroed. */
        uint32_t csize = u32(z->base, p + 20);
        uint32_t usize = u32(z->base, p + 24);
        uint16_t nlen = u16(z->base, p + 28);
        uint16_t elen = u16(z->base, p + 30);
        uint16_t clen = u16(z->base, p + 32);
        uint32_t lho = u32(z->base, p + 42);
        int match = 0;
        if ((size_t)p + 46 + nlen <= z->size && strlen(name) == nlen)
            match = (memcmp(name, z->base + p + 46, nlen) == 0);
        size_t next = p + 46 + nlen + elen + clen;
        if (match){
            if ((size_t)lho + 30 > z->size || u32(z->base, lho) != 0x04034b50) return NULL;
            uint16_t ln = u16(z->base, (size_t)lho + 26);
            uint16_t le = u16(z->base, (size_t)lho + 28);
            size_t dpos = (size_t)lho + 30 + ln + le;
            /* Central-directory csize/usize stay authoritative even when the
             * local header carries zeros (streaming / data-descriptor bit 3).
             * The descriptor block sits after csize bytes of payload, so it
             * never interferes with the deflate stream itself. */
            if ((size_t)dpos + csize > z->size) return NULL;
            if (method == 0){
                if (usize > csize || (size_t)dpos + usize > z->size) return NULL;
                uint8_t *o = xmalloc(usize ? usize : 1);
                memcpy(o, z->base + dpos, usize);
                *outlen = usize;
                return o;
            }
            if (method == 8){
                uint32_t got = 0;
                uint8_t *o = inflate_raw(z->base + dpos, csize, usize, &got);
                if (!o) return NULL;
                *outlen = got;
                return o;
            }
            return NULL;
        }
        if (next <= p) break;
        p = next;
    }
    return NULL;
}

/* ---------- value formatting ---------- */
/* %.17g + trailing zero strip + ensure dot; numerically exact round-trip */
static const char *fmt_f(float fv){
    static char buf[8][64];
    static int bi = 0;
    char *b = buf[bi++ & 7];
    snprintf(b, 64, "%.17g", (double)fv);
    if (!strpbrk(b, "eE")){
        char *dot = strchr(b, '.');
        if (dot){
            char *q = b + strlen(b) - 1;
            while (q > dot && *q == '0') *q-- = 0;
            if (q == dot) q[1] = '0';
        } else {
            strcat(b, ".0");
        }
    }
    return b;
}

static const char *fmt_color(uint8_t dt, uint32_t data){
    static char buf[8][12];
    static int bi = 0;
    char *b = buf[bi++ & 7];
    if (dt != 0x1c && dt != 0x1d) return NULL;
    unsigned a = (data >> 24) & 0xff;
    if (a == 0xff) snprintf(b, 12, "#%06x", data & 0xffffff);
    else snprintf(b, 12, "#%08x", data);
    return b;
}
/* PART1-END */
/* part 2: resources.arsc parsing + value resolution
 * Dual format support (validated by probe8/probe13/probe14):
 *   OFFSET16 (flags & 0x02): u16 offsets, NO_ENTRY 0xffff,
 *      ep = cpos + entriesStart + o16 * 4, entry 8B {key u16@0, const u8@2, dt u8@3, data u32@4}
 *   standard: u32 offsets, NO_ENTRY 0xffffffff, entry 16B
 *      {size u16@0, eflags u16@2, key u32@4, vsize u16@8, dt u8@11, data u32@12}
 * Multi-config semantics: same tid may span several type chunks; a miss in one
 * chunk must continue into the next (entry may only exist in some configs).
 */
typedef struct {
    uint32_t cpos;   /* absolute chunk offset */
    uint16_t chs;    /* chunk header size */
    uint32_t csz;    /* chunk size */
    uint8_t  tid;    /* type id */
    uint8_t  flags;
    uint32_t ec;     /* entry count */
    uint32_t es;     /* entries start (relative to chunk) */
    uint16_t dens;   /* config density field */
} TChunk;

typedef struct {
    uint8_t  pid;
    uint32_t pp, psz;
    uint16_t phs;
    Pool key, type;
    TChunk *tc;
    int ntc;
} PkgInfo;

typedef struct {
    const uint8_t *buf;
    size_t len;
    Pool val;                 /* global value string pool */
    PkgInfo pkgs[MAXPKGS];
    int npkg;
} Arsc;

typedef struct { uint16_t dens; uint8_t dt; uint32_t data; } Cand;

static void arsc_parse(const uint8_t *buf, size_t len, Arsc *a){
    memset(a, 0, sizeof(*a));
    a->buf = buf;
    a->len = len;
    if (len < 12 || u16(buf, 0) != 0x0002) return;
    /* first global string pool = value pool */
    {
        size_t p = u16(buf, 2);
        while (p + 8 <= len){
            uint16_t ct = u16(buf, p);
            uint32_t sz = u32(buf, p + 4);
            if (sz < 8) break;
            if (ct == 0x0001){ pool_parse(buf, p, len, &a->val); break; }
            p += sz;
        }
    }
    /* packages */
    size_t pos = u16(buf, 2);
    while (pos + 8 <= len && a->npkg < MAXPKGS){
        uint16_t ct = u16(buf, pos);
        uint16_t hs = u16(buf, pos + 2);
        uint32_t sz = u32(buf, pos + 4);
        if (sz < 8) break;
        if (ct == 0x0200 && pos + 284 <= len){
            PkgInfo *pk = &a->pkgs[a->npkg++];
            pk->pp = pos; pk->phs = hs; pk->psz = sz;
            pk->pid = u32(buf, pos + 8) & 0xff;
            uint32_t toff = u32(buf, pos + 268);
            uint32_t koff = u32(buf, pos + 276);
            int tcap = 0;
            size_t cpos = pos + hs;
            size_t pend = pos + sz;
            while (cpos + 8 <= pend){
                uint16_t ct2 = u16(buf, cpos);
                uint16_t chs = u16(buf, cpos + 2);
                uint32_t csz = u32(buf, cpos + 4);
                if (csz < 8 || cpos + csz > pend) break;
                if (ct2 == 0x0001){
                    size_t rel = cpos - pos;
                    if (rel == toff) pool_parse(buf, cpos, len, &pk->type);
                    else if (rel == koff) pool_parse(buf, cpos, len, &pk->key);
                } else if (ct2 == 0x0201){
                    if (pk->ntc == tcap){ tcap = tcap ? tcap * 2 : 64; pk->tc = xrealloc(pk->tc, (size_t)tcap * sizeof(TChunk)); }
                    TChunk *t = &pk->tc[pk->ntc++];
                    t->cpos = (uint32_t)cpos;
                    t->chs = chs;
                    t->csz = csz;
                    t->tid = buf[cpos + 8];
                    t->flags = buf[cpos + 9];
                    t->ec = u32(buf, cpos + 12);
                    t->es = u32(buf, cpos + 16);
                    t->dens = (cpos + 36 <= len) ? u16(buf, cpos + 34) : 0;
                }
                if (csz == 0) break;
                cpos += csz;
            }
        }
        if (sz == 0) break;
        pos += sz;
    }
}

/* read one entry; returns 1 and fills outputs on success */
static int read_entry(Arsc *a, const TChunk *t, uint32_t eid,
                      uint32_t *ki, uint8_t *dt, uint32_t *data){
    const uint8_t *buf = a->buf;
    size_t cend = (size_t)t->cpos + t->csz;
    if (eid >= t->ec) return 0;
    size_t ep;
    if (t->flags & 0x02){
        size_t op = (size_t)t->cpos + t->chs + (size_t)eid * 2;
        if (op + 2 > cend) return 0;
        uint32_t o = u16(buf, op);
        if (o == 0xffff) return 0;
        ep = (size_t)t->cpos + t->es + (size_t)o * 4;
        if (ep + 8 > cend) return 0;
        *ki = u16(buf, ep);
        *dt = buf[ep + 3];
        *data = u32(buf, ep + 4);
    } else {
        size_t op = (size_t)t->cpos + t->chs + (size_t)eid * 4;
        if (op + 4 > cend) return 0;
        uint32_t o = u32(buf, op);
        if (o == 0xffffffff) return 0;
        ep = (size_t)t->cpos + t->es + o;
        if (ep + 16 > cend) return 0;
        if (u16(buf, ep + 2) & 1) return 0; /* complex entry */
        if (u16(buf, ep) == 0) return 0;    /* empty entry */
        *ki = u32(buf, ep + 4);
        *dt = buf[ep + 11];
        *data = u32(buf, ep + 12);
    }
    return 1;
}

/* collect every leaf value of resid (expanding references); mirrors the
 * validated prototype: a leaf inherits the density of the top-level chunk */
static int collect_res(Arsc *a, uint32_t resid, int depth, Cand *out, int n, int max){
    if (depth > 8 || n >= max) return n;
    uint8_t pid = (resid >> 24) & 0xff;
    uint8_t tid = (resid >> 16) & 0xff;
    uint32_t eid = resid & 0xffff;
    for (int pi = 0; pi < a->npkg; pi++){
        PkgInfo *pk = &a->pkgs[pi];
        if (pk->pid != pid) continue;
        for (int ci = 0; ci < pk->ntc && n < max; ci++){
            const TChunk *t = &pk->tc[ci];
            if (t->tid != tid) continue;
            uint32_t ki; uint8_t dt; uint32_t data;
            if (!read_entry(a, t, eid, &ki, &dt, &data)) continue;
            if (dt == 0x00) continue; /* null in this config; try next */
            if (dt == 0x03){
                out[n].dens = t->dens; out[n].dt = 0x03; out[n].data = data; n++;
            } else if (dt == 0x01 || dt == 0x07){
                int nb = n;
                n = collect_res(a, data, depth + 1, out, n, max);
                for (int i = nb; i < n; i++) out[i].dens = t->dens;
            }
        }
    }
    return n;
}

/* first hit: string (0x03) or reference (0x01/0x07); mirrors probe13 lookup() */
static int lookup_first(Arsc *a, uint32_t resid, int depth, Cand *out){
    if (depth > 8) return 0;
    uint8_t pid = (resid >> 24) & 0xff;
    uint8_t tid = (resid >> 16) & 0xff;
    uint32_t eid = resid & 0xffff;
    for (int pi = 0; pi < a->npkg; pi++){
        PkgInfo *pk = &a->pkgs[pi];
        if (pk->pid != pid) continue;
        for (int ci = 0; ci < pk->ntc; ci++){
            const TChunk *t = &pk->tc[ci];
            if (t->tid != tid) continue;
            uint32_t ki; uint8_t dt; uint32_t data;
            if (!read_entry(a, t, eid, &ki, &dt, &data)) continue;
            if (dt == 0x00) continue;
            if (dt == 0x03 || dt == 0x01 || dt == 0x07){
                out->dens = t->dens; out->dt = dt; out->data = data;
                return 1;
            }
        }
    }
    return 0;
}

/* resolve resid to a file path string (follows references) */
static int resolve_file(Arsc *a, uint32_t resid, int depth, char *out, size_t outsz){
    Cand c;
    if (!lookup_first(a, resid, depth, &c)) return -1;
    if (c.dt == 0x03){
        if (c.data >= (uint32_t)a->val.n) return -1;
        snprintf(out, outsz, "%s", a->val.items[c.data]);
        return 0;
    }
    if (c.dt == 0x01 || c.dt == 0x07){
        if ((c.data >> 24) != 0x7f) return -1; /* framework ref: not in this arsc */
        return resolve_file(a, c.data, depth + 1, out, outsz);
    }
    return -1;
}
/* PART2-END */
/* part 3: VectorDrawable -> SVG conversion (mirrors probe13 output structure)
 * path fillColor may be a direct color, or a reference to a gradient xml;
 * the gradient xml is resolved through resources.arsc and loaded from the zip.
 */
typedef struct { char *b; size_t len, cap; } SB;

static void sb_init(SB *s){ s->cap = 4096; s->len = 0; s->b = xmalloc(s->cap); s->b[0] = 0; }
static void sb_grow(SB *s, size_t need){
    while (s->len + need + 1 > s->cap){ s->cap *= 2; s->b = xrealloc(s->b, s->cap); }
}
static void sb_puts(SB *s, const char *t){
    size_t n = strlen(t);
    sb_grow(s, n);
    memcpy(s->b + s->len, t, n);
    s->len += n;
    s->b[s->len] = 0;
}
static void sb_printf(SB *s, const char *fmt, ...){
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0){ va_end(ap2); return; }
    sb_grow(s, (size_t)n);
    vsnprintf(s->b + s->len, s->cap - s->len, fmt, ap2);
    va_end(ap2);
    s->len += (size_t)n;
}

typedef struct { char color[12]; float off; } Stop;
typedef struct { float x1, y1, x2, y2; Stop stops[MAXSTOPS]; int ns; int ok; } Grad;
/* fill_kind: 0 none, 1 color string, 2 unresolved reference, 3 url(#gN) */
typedef struct { char *d; int fill_kind; char fill[12]; uint32_t ref; float alpha; int has_alpha; int gidx; } VPath;

static void parse_gradient(const Axml *ax, Grad *g){
    memset(g, 0, sizeof(*g));
    for (int i = 0; i < ax->ne; i++){
        Ev *e = &ax->ev[i];
        if (e->end) continue;
        if (!strcmp(e->name, "gradient")){
            for (int k = 0; k < e->na; k++){
                const Attr *a = &e->attrs[k];
                if (a->dt != 0x04) continue;
                float v = f32v(a->data);
                if (!strcmp(a->name, "startX")) g->x1 = v;
                else if (!strcmp(a->name, "startY")) g->y1 = v;
                else if (!strcmp(a->name, "endX")) g->x2 = v;
                else if (!strcmp(a->name, "endY")) g->y2 = v;
            }
        } else if (!strcmp(e->name, "item")){
            const char *c = NULL;
            float off = 0.0f;
            int have_off = 0;
            for (int k = 0; k < e->na; k++){
                const Attr *a = &e->attrs[k];
                if (!strcmp(a->name, "color")){
                    const char *cc = fmt_color(a->dt, a->data);
                    if (cc) c = cc;
                } else if (!strcmp(a->name, "offset") && a->dt == 0x04){
                    off = f32v(a->data);
                    have_off = 1;
                }
            }
            if (c && g->ns < MAXSTOPS){
                snprintf(g->stops[g->ns].color, sizeof(g->stops[0].color), "%s", c);
                g->stops[g->ns].off = have_off ? off : 0.0f;
                g->ns++;
            }
        }
    }
    g->ok = (g->ns > 0);
}

/* svg: malloc'd string (caller frees); returns 0 on success */
static int convert_vector(Zip *z, Arsc *a, const uint8_t *xml, uint32_t xmllen,
                          char **out, size_t *outlen){
    Axml ax;
    if (axml_parse(xml, xmllen, &ax) != 0) return -1;
    float vw = 720.0f, vh = 720.0f;
    VPath ps[MAXPATHS];
    int np = 0;
    for (int i = 0; i < ax.ne; i++){
        Ev *e = &ax.ev[i];
        if (e->end) continue;
        if (!strcmp(e->name, "vector")){
            const Attr *w = attr_of(e, "viewportWidth");
            const Attr *h = attr_of(e, "viewportHeight");
            if (w && w->dt == 0x04) vw = f32v(w->data);
            if (h && h->dt == 0x04) vh = f32v(h->data);
        } else if (!strcmp(e->name, "path") && np < MAXPATHS){
            const Attr *pd = attr_of(e, "pathData");
            if (!pd || pd->dt != 0x03 || pd->data >= (uint32_t)ax.sp.n) continue;
            VPath *p = &ps[np++];
            memset(p, 0, sizeof(*p));
            p->d = ax.sp.items[pd->data];
            const Attr *fc = attr_of(e, "fillColor");
            if (fc){
                const char *c = fmt_color(fc->dt, fc->data);
                if (c){ p->fill_kind = 1; snprintf(p->fill, sizeof(p->fill), "%s", c); }
                else if (fc->dt == 0x01 || fc->dt == 0x07){ p->fill_kind = 2; p->ref = fc->data; }
            }
            const Attr *fa = attr_of(e, "fillAlpha");
            if (fa && fa->dt == 0x04){ p->alpha = f32v(fa->data); p->has_alpha = 1; }
        }
    }
    /* resolve fill references to gradient xml files */
    Grad grads[MAXGRAD];
    int ng = 0;
    for (int i = 0; i < np; i++){
        VPath *p = &ps[i];
        if (p->fill_kind != 2) continue;
        char gp[512];
        if (resolve_file(a, p->ref, 0, gp, sizeof(gp)) == 0){
            uint32_t gl = 0;
            uint8_t *gd = zip_read(z, gp, &gl);
            if (gd){
                Axml ga;
                if (axml_parse(gd, gl, &ga) == 0){
                    Grad gr;
                    parse_gradient(&ga, &gr);
                    if (gr.ok && ng < MAXGRAD){
                        grads[ng] = gr;
                        p->fill_kind = 3;
                        p->gidx = ng;
                        ng++;
                    }
                    axml_free(&ga);
                }
                free(gd);
            }
        }
        if (p->fill_kind == 2){
            snprintf(p->fill, sizeof(p->fill), "#808080");
            p->fill_kind = 1;
        }
    }
    /* emit */
    SB sb;
    sb_init(&sb);
    sb_printf(&sb, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %s %s\" width=\"48\" height=\"48\">\n",
              fmt_f(vw), fmt_f(vh));
    if (ng > 0){
        sb_puts(&sb, "  <defs>\n");
        for (int i = 0; i < ng; i++){
            Grad *g = &grads[i];
            sb_printf(&sb, "    <linearGradient id=\"g%d\" x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\" gradientUnits=\"userSpaceOnUse\">\n",
                      i, fmt_f(g->x1), fmt_f(g->y1), fmt_f(g->x2), fmt_f(g->y2));
            for (int j = 0; j < g->ns; j++)
                sb_printf(&sb, "      <stop offset=\"%s\" stop-color=\"%s\"/>\n", fmt_f(g->stops[j].off), g->stops[j].color);
            sb_puts(&sb, "    </linearGradient>\n");
        }
        sb_puts(&sb, "  </defs>\n");
    }
    for (int i = 0; i < np; i++){
        VPath *p = &ps[i];
        char style[64] = "";
        if (p->fill_kind == 3) snprintf(style, sizeof(style), " fill=\"url(#g%d)\"", p->gidx);
        else if (p->fill_kind == 1) snprintf(style, sizeof(style), " fill=\"%s\"", p->fill);
        char op[64] = "";
        if (p->has_alpha && p->alpha != 1.0f) snprintf(op, sizeof(op), " fill-opacity=\"%s\"", fmt_f(p->alpha));
        sb_printf(&sb, "  <path d=\"%s\"%s%s/>\n", p->d, style, op);
    }
    sb_puts(&sb, "</svg>\n");
    axml_free(&ax);
    *out = sb.b;
    *outlen = sb.len;
    return 0;
}
/* PART3-END */
/* part 4: manifest icon selection, apk discovery, cli */
typedef struct { uint8_t dt; uint32_t data; int have; } Res;
typedef struct { Res icon, roundIcon, launcher; } ManInfo;

static void manifest_info(const Axml *ax, ManInfo *mi){
    memset(mi, 0, sizeof(*mi));
    char *stack[64];
    int sp = 0;
    int in_if = 0, main = 0, launcher = 0;
    Res li;
    memset(&li, 0, sizeof(li));
    for (int i = 0; i < ax->ne; i++){
        Ev *e = &ax->ev[i];
        if (e->end){
            if (sp > 0){
                sp--;
                if (stack[sp] && !strcmp(stack[sp], "intent-filter")){
                    in_if = 0;
                    if (main && launcher && li.have && !mi->launcher.have) mi->launcher = li;
                }
            }
            continue;
        }
        if (sp < 64) stack[sp] = e->name, sp++;
        if (!strcmp(e->name, "application")){
            for (int k = 0; k < e->na; k++){
                if (!strcmp(e->attrs[k].name, "icon") && !mi->icon.have){
                    mi->icon.dt = e->attrs[k].dt; mi->icon.data = e->attrs[k].data; mi->icon.have = 1;
                } else if (!strcmp(e->attrs[k].name, "roundIcon") && !mi->roundIcon.have){
                    mi->roundIcon.dt = e->attrs[k].dt; mi->roundIcon.data = e->attrs[k].data; mi->roundIcon.have = 1;
                }
            }
        } else if (!strcmp(e->name, "activity") || !strcmp(e->name, "activity-alias")){
            memset(&li, 0, sizeof(li));
            main = 0; launcher = 0;
            for (int k = 0; k < e->na; k++){
                if (!strcmp(e->attrs[k].name, "icon")){
                    li.dt = e->attrs[k].dt; li.data = e->attrs[k].data; li.have = 1;
                }
            }
        } else if (!strcmp(e->name, "intent-filter")){
            in_if = 1; main = 0; launcher = 0;
        } else if (in_if && !strcmp(e->name, "action")){
            const Attr *n = attr_of(e, "name");
            if (n && n->dt == 0x03 && n->data < (uint32_t)ax->sp.n && strstr(ax->sp.items[n->data], "MAIN")) main = 1;
        } else if (in_if && !strcmp(e->name, "category")){
            const Attr *n = attr_of(e, "name");
            if (n && n->dt == 0x03 && n->data < (uint32_t)ax->sp.n && strstr(ax->sp.items[n->data], "LAUNCHER")) launcher = 1;
        }
    }
}

static int is_xml_path(const char *p){
    size_t n = strlen(p);
    return (n > 4 && !strcasecmp(p + n - 4, ".xml"));
}

static int choose_icon(Zip *z, Arsc *a, const ManInfo *mi, char *out, size_t outsz){
    Cand cands[MAXCAND];
    const Res *keys[3] = { &mi->icon, &mi->roundIcon, &mi->launcher };
    const char *kn[3] = { "icon", "roundIcon", "launcher" };
    for (int k = 0; k < 3; k++){
        const Res *r = keys[k];
        if (!r->have || r->dt == 0x03) continue;
        int n = collect_res(a, r->data, 0, cands, 0, MAXCAND);
        int best = -1, best_xml = -1;
        uint32_t bs = 0;
        for (int i = 0; i < n; i++){
            if (cands[i].dt != 0x03 || cands[i].data >= (uint32_t)a->val.n) continue;
            const char *p = a->val.items[cands[i].data];
            if (g_verbose) printf("   cand[%s] dens=%u %s\n", kn[k], cands[i].dens, p);
            if (!zip_has(z, p)) continue;
            if (is_xml_path(p)){
                if (best_xml < 0) best_xml = i;
            } else {
                uint32_t s = cands[i].dens ? cands[i].dens : 1;
                if (best < 0 || s > bs){ best = i; bs = s; }
            }
        }
        int pick = (best >= 0) ? best : best_xml;
        if (pick >= 0){
            snprintf(out, outsz, "%s", a->val.items[cands[pick].data]);
            return 0;
        }
    }
    return -1;
}

static int write_file(const char *path, const void *data, size_t n){
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0){ fprintf(stderr, "[icon] cannot write %s: %s\n", path, strerror(errno)); return -1; }
    fchmod(fd, 0644);
    const uint8_t *p = (const uint8_t *)data;
    size_t off = 0;
    while (off < n){
        ssize_t w = write(fd, p + off, n - off);
        if (w <= 0){ if (errno == EINTR) continue; close(fd); return -1; }
        off += (size_t)w;
    }
    close(fd);
    return 0;
}

static int mkdir_p(const char *path){
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", path);
    size_t ln = strlen(tmp);
    if (ln == 0) return -1;
    if (tmp[ln - 1] == '/') tmp[ln - 1] = 0;
    for (char *q = tmp + 1; *q; q++){
        if (*q == '/'){ *q = 0; mkdir(tmp, 0755); *q = '/'; }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

/* returns 0 = icon written, -1 = failure */
static int extract_apk(const char *apkpath, const char *outdir, const char *basename,
                       char *chosen_out, size_t chosen_sz){
    Zip z;
    uint8_t *mxml = NULL, *arscbuf = NULL, *data = NULL;
    char *svg = NULL;
    Axml ax;
    Arsc a;
    ManInfo mi;
    char chosen[1024], outpath[1024];
    uint32_t ml = 0, al = 0, dl = 0;
    int rc = -1;
    memset(&ax, 0, sizeof(ax));
    memset(&a, 0, sizeof(a));
    memset(&mi, 0, sizeof(mi));
    if (zip_open(&z, apkpath) != 0){
        fprintf(stderr, "[icon] %s: cannot open apk\n", basename);
        return -1;
    }
    do {
        mxml = zip_read(&z, "AndroidManifest.xml", &ml);
        if (!mxml){ fprintf(stderr, "[icon] %s: no AndroidManifest.xml\n", basename); break; }
        if (axml_parse(mxml, ml, &ax) != 0){ fprintf(stderr, "[icon] %s: bad manifest\n", basename); break; }
        manifest_info(&ax, &mi);
        arscbuf = zip_read(&z, "resources.arsc", &al);
        if (!arscbuf){ fprintf(stderr, "[icon] %s: no resources.arsc\n", basename); break; }
        arsc_parse(arscbuf, al, &a);
        if (choose_icon(&z, &a, &mi, chosen, sizeof(chosen)) != 0){
            fprintf(stderr, "[icon] %s: icon not resolvable\n", basename);
            break;
        }
        if (chosen_out) snprintf(chosen_out, chosen_sz, "%s", chosen);
        data = zip_read(&z, chosen, &dl);
        if (!data){ fprintf(stderr, "[icon] %s: cannot read %s\n", basename, chosen); break; }
        if (is_xml_path(chosen)){
            size_t sl = 0;
            if (convert_vector(&z, &a, data, dl, &svg, &sl) != 0 || !svg){
                fprintf(stderr, "[icon] %s: vector conversion failed\n", basename);
                break;
            }
            snprintf(outpath, sizeof(outpath), "%s/%s.svg", outdir, basename);
            if (write_file(outpath, svg, sl) == 0){
                printf("[icon] %s: %s -> %s (%zu bytes SVG)\n", basename, chosen, outpath, sl);
                rc = 0;
            }
        } else {
            /* v3.2.43: detect format by content magic, not file extension (resource-obfuscated APKs have garbled paths) */
            const char *ext = ".bin";
            if (dl >= 8 && data[0]==0x89 && data[1]=='P' && data[2]=='N' && data[3]=='G') ext = ".png";
            else if (dl >= 12 && data[0]=='R' && data[1]=='I' && data[2]=='F' && data[3]=='F' && data[8]=='W' && data[9]=='E' && data[10]=='B' && data[11]=='P') ext = ".webp";
            else if (dl >= 6 && data[0]=='<' && data[1]=='s' && data[2]=='v' && data[3]=='g') ext = ".svg";
            else if (dl >= 3 && data[0]==0xFF && data[1]==0xD8 && data[2]==0xFF) ext = ".png";  /* jpeg -> png ext for compat */
            else { const char *pe = strrchr(chosen, '.'); if (pe && (strcasecmp(pe,".png")==0 || strcasecmp(pe,".webp")==0 || strcasecmp(pe,".svg")==0)) ext = pe; }
            snprintf(outpath, sizeof(outpath), "%s/%s%s", outdir, basename, ext);
            if (write_file(outpath, data, dl) == 0){
                printf("[icon] %s: %s -> %s (%u bytes)\n", basename, chosen, outpath, dl);
                rc = 0;
            }
        }
    } while (0);
    if (svg) free(svg);
    if (data) free(data);
    if (arscbuf) free(arscbuf);
    if (mxml) free(mxml);
    zip_close(&z);
    return rc;
}

/* ---------- apk discovery ---------- */
static int scan_apk_pkg(const char *apk, char *pkg_out, size_t pkg_sz){
    Zip z;
    uint8_t *m = NULL;
    uint32_t ml = 0;
    int rc = -1;
    if (zip_open(&z, apk) != 0) return -1;
    m = zip_read(&z, "AndroidManifest.xml", &ml);
    if (m){
        Axml ax;
        if (axml_parse(m, ml, &ax) == 0){
            for (int i = 0; i < ax.ne; i++){
                Ev *e = &ax.ev[i];
                if (e->end) continue;
                if (!strcmp(e->name, "manifest")){
                    const Attr *pa = attr_of(e, "package");
                    if (pa && pa->dt == 0x03 && pa->data < (uint32_t)ax.sp.n && ax.sp.items[pa->data]){
                        snprintf(pkg_out, pkg_sz, "%s", ax.sp.items[pa->data]);
                        rc = 0;
                    }
                    break;
                }
            }
            axml_free(&ax);
        }
        free(m);
    }
    zip_close(&z);
    return rc;
}

/* /data/app/~~<rand>/<pkg>-<rand>/base.apk */
static int find_data_app(const char *pkg, char *out, size_t outsz){
    char pre[600];
    DIR *d = opendir("/data/app");
    if (!d) return -1;
    snprintf(pre, sizeof(pre), "%s-", pkg);
    size_t plen = strlen(pre);
    struct dirent *e;
    while ((e = readdir(d))){
        if (e->d_name[0] == '.') continue;
        char d1[1024];
        snprintf(d1, sizeof(d1), "/data/app/%s", e->d_name);
        DIR *d2 = opendir(d1);
        if (!d2) continue;
        struct dirent *f;
        while ((f = readdir(d2))){
            if (strncmp(f->d_name, pre, plen) != 0) continue;
            char p[1700];
            snprintf(p, sizeof(p), "%s/%s/base.apk", d1, f->d_name);
            if (access(p, R_OK) == 0){
                closedir(d2);
                closedir(d);
                snprintf(out, outsz, "%s", p);
                return 0;
            }
        }
        closedir(d2);
    }
    closedir(d);
    return -1;
}

typedef struct { char pkg[256]; char path[1024]; } ApkEnt;
static ApkEnt g_syscache[384];
static int g_sysn = 0;

static void sys_scan_dir(const char *dir, int depth){
    if (depth > 4 || g_sysn >= 384) return;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))){
        if (e->d_name[0] == '.') continue;
        char p[1280];
        snprintf(p, sizeof(p), "%s/%s", dir, e->d_name);
        size_t ln = strlen(e->d_name);
        if (ln >= 5 && !strcasecmp(e->d_name + ln - 4, ".apk")){
            char pkg[256];
            if (scan_apk_pkg(p, pkg, sizeof(pkg)) == 0 && pkg[0] && g_sysn < 384){
                snprintf(g_syscache[g_sysn].pkg, 256, "%s", pkg);
                snprintf(g_syscache[g_sysn].path, 1024, "%s", p);
                g_sysn++;
                if (g_verbose) printf("   sys: %s -> %s\n", pkg, p);
            }
        } else {
            sys_scan_dir(p, depth + 1);
        }
    }
    closedir(d);
}

static int find_apk(const char *pkg, char *out, size_t outsz){
    if (find_data_app(pkg, out, outsz) == 0) return 0;
    /* v3.2.43: /data/app may hold APKs whose dir name != pkg name (e.g. /data/app/OppoNote2/OppoNote2.apk).
       Fallback: scan all of /data/app by reading each APK's manifest package. */
    sys_scan_dir("/data/app", 1);
    for (int i = 0; i < g_sysn; i++){
        if (!strcmp(g_syscache[i].pkg, pkg)){
            snprintf(out, outsz, "%s", g_syscache[i].path);
            return 0;
        }
    }
    if (g_sysn == 0){
        const char *roots[5] = { "/system_ext", "/system", "/vendor", "/product", NULL };
        for (int i = 0; roots[i]; i++){
            char p[512];
            snprintf(p, sizeof(p), "%s/app", roots[i]);
            sys_scan_dir(p, 1);
            snprintf(p, sizeof(p), "%s/priv-app", roots[i]);
            sys_scan_dir(p, 1);
        }
    }
    for (int i = 0; i < g_sysn; i++){
        if (!strcmp(g_syscache[i].pkg, pkg)){
            snprintf(out, outsz, "%s", g_syscache[i].path);
            return 0;
        }
    }
    return -1;
}

/* ---------- cli ---------- */
static int cmd_single(const char *apk, const char *outdir){
    if (mkdir_p(outdir) != 0){
        fprintf(stderr, "[icon] cannot create %s\n", outdir);
        return 1;
    }
    const char *b = strrchr(apk, '/');
    b = b ? b + 1 : apk;
    char stem[512];
    snprintf(stem, sizeof(stem), "%s", b);
    char *dot = strrchr(stem, '.');
    if (dot && !strcasecmp(dot, ".apk")) *dot = 0;
    char base[600];
    snprintf(base, sizeof(base), "%s_icon", stem);
    return (extract_apk(apk, outdir, base, NULL, 0) == 0) ? 0 : 1;
}

static int cmd_batch(const char *conf, const char *outdir){
    if (mkdir_p(outdir) != 0){
        fprintf(stderr, "[icon] cannot create %s\n", outdir);
        return 1;
    }
    FILE *f = fopen(conf, "r");
    if (!f){
        fprintf(stderr, "[icon] cannot read whitelist %s\n", conf);
        return 1;
    }
    char line[1024];
    int ok = 0, fail = 0, skip = 0;
    while (fgets(line, sizeof(line), f)){
        char *p = line;
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
        char *q = p + strlen(p);
        while (q > p && (q[-1] == '\n' || q[-1] == '\r' || q[-1] == ' ' || q[-1] == '\t')) *--q = 0;
        if (!*p || *p == '#'){ skip++; continue; }
        char apk[1024];
        if (find_apk(p, apk, sizeof(apk)) != 0){
            fprintf(stderr, "[icon] apk not found for %s\n", p);
            fail++;
            continue;
        }
        if (extract_apk(apk, outdir, p, NULL, 0) == 0) ok++;
        else fail++;
    }
    fclose(f);
    printf("[icon] batch done: %d ok, %d failed, %d skipped\n", ok, fail, skip);
    return fail ? 1 : 0;
}

int main(int argc, char **argv){
    if (getenv("ICON_VERBOSE")) g_verbose = 1;
    if (argc == 4 && !strcmp(argv[1], "--whitelist")) return cmd_batch(argv[2], argv[3]);
    if (argc == 3) return cmd_single(argv[1], argv[2]);
    fprintf(stderr, "usage: icon_extract <apk> <outdir>\n");
    fprintf(stderr, "       icon_extract --whitelist <conf> <outdir>\n");
    return 2;
}
/* PART4-END */