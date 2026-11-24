// movie library host side (hle_movie.c with media/movie_av.m), called the way Unity's VideoPlayer calls it for manosaba's clips (MP4 with H.264
// and AAC): t_movie_clip.m writes a clip with AVAssetWriter (12 uniform frames of 320 x 240 at 24 per second, a key frame at least every 6, and a
// 440 Hz sine at half scale, 48 kHz stereo); the Extractor reads it through a ClientStreamReader and by path; the Decoders give NV12 frames and
// PCM16 (values, times, events, end of stream, output format, a loop, Flush). Expected values come from what was encoded, not from the code under
// test. -DDM_TEST_EVENTS_COPIED (the DecoderEvents copied when they are registered, plan item 64k): 3 fail.
// t_movie <file>: a real movie through the same path (every video frame and audio chunk: counts, times, decode time).
#include "../hle/hle_movie.c"
#include <dirent.h>
#include <math.h>
#include <time.h>

struct dm_flags g_flag;
uint64_t g_t0_ns;
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static char t_dir[512]; static const char *t_probe;
int dm_fs_host_file(const char *path, char *out, size_t n) {
    if (strncmp(path, "content:/", 9)) return 0;
    if (t_probe) snprintf(out, n, "%s", t_probe); else snprintf(out, n, "%s/%s", t_dir, path + 9);
    return access(out, R_OK) == 0;
}
enum { EV_INPUT, EV_OUTPUT, EV_FORMAT, EV_ERROR };   // DecoderEvents order
static int t_events[4]; static int t_event_obj[4];   // the test's EventType objects are these ints
static void t_signal(void *ev) { for (int i = 0; i < 4; i++) if (ev == &t_event_obj[i]) t_events[i]++; }
static void t_delete(void *p) { free(p); }
void *guest_sym(const char *name) {
    if (!strcmp(name, "_ZdlPv")) return (void *)t_delete;
    if (!strcmp(name, "_ZN2nn2os11SignalEventEPNS0_9EventTypeE")) return (void *)t_signal;
    return NULL;
}

static int g_fail, g_n;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); g_n++; \
    printf("%-60s expected %-10lld got %-10lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); if (w_ != g_) g_fail++; } while (0)

// ---- the clip ----
enum { W = 320, H = 240, FPS = 24, N = 12, KEY = 6, HZ = 440, TOL = 4 };
int t_movie_clip(const char *file, int w, int h, int fps, int nframes, int key_every, void (*ycbcr)(int frame, uint8_t out[3]), int tone_hz);
static void colour(int i, uint8_t c[3]) { c[0] = (uint8_t)(40 + 12 * i); c[1] = (uint8_t)(90 + 6 * i); c[2] = (uint8_t)(170 - 6 * i); }   // Y, Cb, Cr of frame i
static int64_t pts_us(int i) { return (int64_t)i * 1000000 / FPS; }

// ---- the game's movie::ClientStreamReader: slot 2 Open(path, &handle), 3 ReadAt(handle, offset, buffer, size), 4 Close(handle) ----
typedef struct { void **vt; int opens, closes; } t_reader;
static uint32_t rd_open(void *self, const char *path, void **h) {
    char f[700]; if (strncmp(path, "content:/", 9)) return 0;
    snprintf(f, sizeof f, "%s/%s", t_dir, path + 9); FILE *fp = fopen(f, "rb"); if (!fp) return 0;
    *h = fp; ((t_reader *)self)->opens++; return 1;
}
static size_t rd_read(void *self, void *h, int64_t off, void *buf, size_t n) { (void)self; fseeko(h, off, SEEK_SET); return fread(buf, 1, n, h); }
static void rd_close(void *self, void *h) { ((t_reader *)self)->closes++; fclose(h); }
static void *t_reader_vt[5] = {NULL, NULL, rd_open, rd_read, rd_close};

// ---- calls through the objects' vtables, as the game makes them ----
typedef struct { void *vt; void *impl; } obj;   // movie::Extractor / Decoder: vtable + host state
#define VCALL(o, slot, T, ...) ((T)((void **)(o)->vt)[slot])((void **)(o), ##__VA_ARGS__)
typedef int (*f_ptr)(void **, const char *); typedef int (*f_i)(void **, int32_t *); typedef int (*f_imd)(void **, int, void **); typedef int (*f_int)(void **, int);
typedef int (*f_64)(void **, int64_t); typedef int (*f_buf)(void **, mvbuf *); typedef int (*f_p64)(void **, int64_t *); typedef int (*f_md)(void **, void **);
typedef int (*f_v)(void **); typedef int (*f_ii)(void **, int32_t *, int32_t *); typedef int (*f_ib)(void **, int32_t, mvbuf *);
typedef int (*f_send)(void **, int32_t, int32_t, int32_t, int64_t, uint32_t); typedef int (*f_acq)(void **, int32_t *, int64_t *, uint32_t *, int32_t *);
typedef int (*f_rel)(void **, int32_t); typedef int (*f_rdr)(void **, void *, const char *); typedef int (*f_pu64)(void **, uint64_t *); typedef void (*f_dtor)(void **);
enum { E_DTOR = 0, E_SETPATH = 2, E_COUNT = 4, E_CONFIG = 5, E_SELECT = 6, E_UNSELECT = 7, E_SEEK = 8, E_TRACK = 9, E_READ = 10, E_ADVANCE = 11, E_TIME = 12, E_META = 13, E_SETREADER = 15 };
enum { D_CONFIGURE = 2, D_EVENTS = 3, D_OUTFMT = 4, D_START = 5, D_FLUSH = 8, D_ACQIN = 9, D_GETIN = 10, D_SEND = 11, D_ACQOUT = 12, D_GETOUT = 13, D_OUTSIZE = 14, D_RELEASE = 15 };

typedef struct {
    int n, eos, order_ok, values_ok, sizes_ok, format_first; int64_t pts[64], last_pts;   // outputs: video frames or audio chunks
    int pic[64];                                                                            // video: which frame's picture each output holds (-1 none of them)
    long bytes, nsamp; double sumsq; int sign, turns;                                       // audio: PCM bytes, left samples, their squares, sign changes past ±1000
} outlog;
#define OUTLOG {.order_ok = 1, .values_ok = 1, .sizes_ok = 1, .format_first = 1, .last_pts = -1}
static int g_maxdiff;
static int frame_diff(const uint8_t *f, int i) {   // the largest difference of an NV12 frame from frame i as it was encoded
    uint8_t c[3]; colour(i, c); int worst = 0;
    for (int p = 0; p < W * H + W * H / 2; p++) { int d = abs(f[p] - (p < W * H ? c[0] : ((p - W * H) & 1) ? c[2] : c[1])); if (d > worst) worst = d; }
    return worst;
}
static void check_frame(const uint8_t *f, int size, int64_t pts, outlog *L) {   // (the output is entry L->n)
    int i = -1, pic = -1; for (int k = 0; k < N; k++) if (llabs(pts - pts_us(k)) <= 1) i = k;
    if (size != W * H * 3 / 2) { L->sizes_ok = L->values_ok = 0; if (L->n < 64) L->pic[L->n] = -1; return; }
    for (int k = 0; k < N && pic < 0; k++) if (frame_diff(f, k) <= TOL) pic = k;
    if (L->n < 64) L->pic[L->n] = pic;
    if (i < 0) { L->values_ok = 0; return; }
    int d = frame_diff(f, i); if (d > TOL) L->values_ok = 0; else if (d > g_maxdiff) g_maxdiff = d;
}
static void check_pcm(const uint8_t *f, int size, outlog *L) {
    if (size <= 0 || size > 1024 * 4 || size % 4) L->sizes_ok = 0;
    for (int k = 0; k + 3 < size; k += 4) {
        int s = (int16_t)(f[k] | f[k + 1] << 8); L->sumsq += (double)s * s; L->nsamp++;
        int sg = s > 1000 ? 1 : s < -1000 ? -1 : L->sign;
        if (L->sign && sg != L->sign) L->turns++;
        L->sign = sg;
    }
    L->bytes += size;
}
// Feeds the selected track's samples into the decoder and takes every output; at the extractor's end of stream it sends the end-of-stream input
// (send_eos) or stops feeding (the game looping instead). kind: 1 video values checked, 0 audio, -1 nothing checked (a real movie)
static void run(obj *ex, obj *dec, outlog *L, int kind, int send_eos) {
    static uint8_t frame[4 << 20]; int fed_end = 0, idle = 0;
    while (!L->eos && idle < 3) {
        int did = 0;
        while (!fed_end) {
            uint64_t ti; int32_t idx, rem;
            if (VCALL(ex, E_TRACK, f_pu64, &ti) == ST_EOS) {
                if (send_eos) { if (VCALL(dec, D_ACQIN, f_ii, &idx, &rem) != ST_OK) break; VCALL(dec, D_SEND, f_send, idx, 0, 0, (int64_t)0, (uint32_t)BF_EOS); }
                fed_end = 1; did = 1; break;
            }
            if (VCALL(dec, D_ACQIN, f_ii, &idx, &rem) != ST_OK) break;
            mvbuf in; VCALL(dec, D_GETIN, f_ib, idx, &in);
            int64_t t = 0; void *meta = NULL; int32_t sync = 0;
            VCALL(ex, E_READ, f_buf, &in); VCALL(ex, E_TIME, f_p64, &t); VCALL(ex, E_META, f_md, &meta); mv_FindInt32(&meta, "is-sync-frame", &sync); mv_MediaDataD(&meta);
            VCALL(dec, D_SEND, f_send, idx, in.off, in.size, t, (uint32_t)(sync ? BF_SYNC : 0));
            VCALL(ex, E_ADVANCE, f_v); did = 1;
        }
        for (;;) {
            int32_t o, rem; int64_t pts; uint32_t fl;
            if (VCALL(dec, D_ACQOUT, f_acq, &o, &pts, &fl, &rem) != ST_OK) break;
            mvbuf ob = {frame, sizeof frame, 0, 0};
            VCALL(dec, D_GETOUT, f_ib, o, &ob); did = 1;
            if (fl & BF_EOS) L->eos = 1;
            else {
                if (!t_events[EV_FORMAT]) L->format_first = 0;
                if (pts < L->last_pts) L->order_ok = 0;
                L->last_pts = pts; if (L->n < 64) L->pts[L->n] = pts;
                if (kind == 1) check_frame(frame, ob.size, pts, L); else if (kind == 0) check_pcm(frame, ob.size, L);
                L->n++;
            }
            VCALL(dec, D_RELEASE, f_rel, o);
        }
        idle = did ? 0 : idle + 1;
    }
}
static obj *new_decoder(int type, int fmt, void *md, int *status) {
    obj *d = calloc(1, sizeof *d); mv_Decoder((void **)d, type, fmt, 1, 16);
    void **ev = calloc(4, sizeof *ev);   // the game's DecoderEvents: registered empty, filled in after (blade2-mobile's game; plan item 64k)
    VCALL(d, D_EVENTS, f_md, ev);
    for (int i = 0; i < 4; i++) ev[i] = &t_event_obj[i];
    *status = VCALL(d, D_CONFIGURE, f_md, &md);
    return d;
}

static int probe(const char *file) {   // a real movie: every video frame and audio chunk through the extractor and the decoders
    t_probe = file; obj ex = {0}; mv_Extractor((void **)&ex, 0);
    if (VCALL(&ex, E_SETPATH, f_ptr, "content:/probe") != ST_OK) { printf("%s: no audio / video track this path reads\n", file); return 1; }
    int32_t nt = 0; VCALL(&ex, E_COUNT, f_i, &nt);
    for (int i = 0; i < nt; i++) {
        void *md = NULL; const char *mime = ""; int st = 0;
        VCALL(&ex, E_CONFIG, f_imd, i, &md); mv_FindString(&md, "mime", &mime);
        int video = !strcmp(mime, "video/avc"), audio = !strcmp(mime, "audio/mp4a-latm");
        if (!video && !audio) { printf("track %d: %s, not decoded\n", i, mime); continue; }
        obj *d = new_decoder(video ? DEC_AVC : DEC_AAC, video ? 4 : 1, md, &st);
        if (st != ST_OK) { printf("track %d: %s, Configure %#x\n", i, mime, st); continue; }
        VCALL(&ex, E_SELECT, f_int, i); VCALL(&ex, E_SEEK, f_64, (int64_t)0); VCALL(d, D_START, f_v);
        outlog L = OUTLOG; uint64_t t0 = now_ns(); run(&ex, d, &L, -1, 1); double ms = (double)(now_ns() - t0) / 1e6;
        printf("track %d: %s, %d %s, end of stream %d, times in order %d, the last at %.3f s, %.2f ms each\n", i, mime, L.n, video ? "frames" : "chunks", L.eos, L.order_ok,
               (double)L.last_pts / 1e6, L.n ? ms / L.n : 0);
        VCALL(&ex, E_UNSELECT, f_int, i);
    }
    return 0;
}
static int count_copies(void) {   // the media cache's temporary copies in DM_TEMP (this run's own directory)
    DIR *d = opendir(t_dir); struct dirent *e; int n = 0;
    while (d && (e = readdir(d))) if (!strncmp(e->d_name, "movie-", 6)) n++;
    if (d) closedir(d);
    return n;
}
static void t_clean(void) {   // (the files main writes, and their directory)
    DIR *d = opendir(t_dir); struct dirent *e; char f[1024];
    while (d && (e = readdir(d))) if (e->d_name[0] != '.') { snprintf(f, sizeof f, "%s/%s", t_dir, e->d_name); unlink(f); }
    if (d) closedir(d);
    rmdir(t_dir);
}
#define SUMMARY() printf("== %d checks, %d failed ==\n", g_n, g_fail)
int main(int argc, char **argv) {
    if (argc > 1) return probe(argv[1]);
    const char *tmp = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    snprintf(t_dir, sizeof t_dir, "%s/t_movie.%d.d", tmp, (int)getpid()); mkdir(t_dir, 0755); atexit(t_clean);   // one per process: its variants (t_movie_evcopy) run beside it
    setenv("DM_TEMP", t_dir, 1);   // where the media cache puts its copies
    char file[700], link2[700], junk[700];
    snprintf(file, sizeof file, "%s/t.mp4", t_dir); snprintf(link2, sizeof link2, "%s/p.mp4", t_dir); snprintf(junk, sizeof junk, "%s/junk.mp4", t_dir);
    int made = t_movie_clip(file, W, H, FPS, N, KEY, colour, HZ);
    EXPECT("the clip is written: 12 frames of H.264 and half a second of AAC in an MP4", 1, made);
    if (!made || link(file, link2)) { g_fail++; SUMMARY(); return 1; }
    { FILE *f = fopen(junk, "wb"); if (!f) { perror(junk); return 1; } fputs("not a movie at all", f); fclose(f); }

    // Extractor, through the game's stream reader (a temporary copy, shared by the Extractors on one path)
    t_reader rdr = {t_reader_vt, 0, 0};
    obj bad = {0}; mv_Extractor((void **)&bad, 0);
    EXPECT("SetDataSource(reader) when the reader cannot open the path: UnsupportedMediaType", ST_UNSUPPORTED_MEDIA, VCALL(&bad, E_SETREADER, f_rdr, &rdr, "content:/none.mp4"));
    EXPECT("... and on a file that is no movie: UnsupportedMediaType, its copy removed", ST_UNSUPPORTED_MEDIA * 10,
           VCALL(&bad, E_SETREADER, f_rdr, &rdr, "content:/junk.mp4") * 10 + count_copies());
    rdr.opens = rdr.closes = 0;
    obj ex = {0}, ex2 = {0}; mv_Extractor((void **)&ex, 0); mv_Extractor((void **)&ex2, 0);
    EXPECT("SetDataSource(reader, \"content:/t.mp4\")", ST_OK, VCALL(&ex, E_SETREADER, f_rdr, &rdr, "content:/t.mp4"));
    EXPECT("a second Extractor on the same path", ST_OK, VCALL(&ex2, E_SETREADER, f_rdr, &rdr, "content:/t.mp4"));
    EXPECT("... shares the first one's copy: the file opened once, closed once, one copy in DM_TEMP", 111, rdr.opens * 100 + rdr.closes * 10 + count_copies());
    int32_t nt = 0; VCALL(&ex, E_COUNT, f_i, &nt); EXPECT("two tracks", 2, nt);
    if (nt != 2) { SUMMARY(); return 1; }
    void *md[2] = {NULL, NULL}; const char *mime[2] = {"", ""};
    for (int i = 0; i < 2; i++) { VCALL(&ex, E_CONFIG, f_imd, i, &md[i]); mv_FindString(&md[i], "mime", &mime[i]); }
    int vt = !strcmp(mime[0], "video/avc") ? 0 : 1, at = 1 - vt;
    int32_t w = 0, h = 0, fr = 0, ch = 0, sr = 0; int64_t dur = 0;
    mv_FindInt32(&md[vt], "width", &w); mv_FindInt32(&md[vt], "height", &h); mv_FindInt32(&md[vt], "frame-rate", &fr); mv_FindInt64(&md[vt], "durationUs", &dur);
    mv_FindInt32(&md[at], "channel-count", &ch); mv_FindInt32(&md[at], "sample-rate", &sr);
    EXPECT("video track: video/avc, 320 x 240, 24 frames per second", 1, !strcmp(mime[vt], "video/avc") && w == W && h == H && fr == FPS);
    EXPECT("... half a second long (within a frame)", 1, llabs(dur - 500000) <= 1000000 / FPS);
    EXPECT("audio track: audio/mp4a-latm, 2 channels, 48 kHz", 1, !strcmp(mime[at], "audio/mp4a-latm") && ch == 2 && sr == 48000);
    VCALL(&ex, E_SELECT, f_int, vt);
    int k = 0, time_ok = 1, filled = 1, sync0 = -1, sync1 = -1, key_by = -1;
    for (;; k++) {
        static uint8_t sb[W * H * 2]; mvbuf b = {sb, sizeof sb, 0, 0}; int64_t t = -1; void *meta = NULL; int32_t sync = -1;
        if (VCALL(&ex, E_READ, f_buf, &b) != ST_OK) break;
        VCALL(&ex, E_TIME, f_p64, &t); VCALL(&ex, E_META, f_md, &meta); mv_FindInt32(&meta, "is-sync-frame", &sync); mv_MediaDataD(&meta);
        if (k >= N || llabs(t - pts_us(k)) > 1) time_ok = 0;
        if (b.size <= 0) filled = 0;
        if (k == 0) sync0 = sync;
        if (k == 1) sync1 = sync;
        if (k >= 1 && sync == 1 && key_by < 0) key_by = k;
        VCALL(&ex, E_ADVANCE, f_v);
    }
    EXPECT("Read: 12 video samples, none empty", N * 10 + 1, k * 10 + filled);
    EXPECT("GetSampleTime: sample i at i / 24 s", 1, time_ok);
    EXPECT("is-sync-frame: the first sample is a key frame, the second is not, the next key frame comes by the seventh", 1, sync0 == 1 && sync1 == 0 && key_by >= 1 && key_by <= KEY);
    { int64_t t = -1; void *meta = NULL; int32_t sync = -1;
      VCALL(&ex, E_SEEK, f_64, (int64_t)300000); VCALL(&ex, E_TIME, f_p64, &t); VCALL(&ex, E_META, f_md, &meta); mv_FindInt32(&meta, "is-sync-frame", &sync); mv_MediaDataD(&meta);
      EXPECT("SeekTo 300 ms: the read goes on from the key frame at or before it", 1, sync == 1 && t >= 0 && t <= 300000 && t >= pts_us(key_by));
      printf("(key frames 0 and %d; after SeekTo 300 ms the next sample is at %lld us)\n", key_by, (long long)t); }
    VCALL(&ex, E_SELECT, f_int, at); VCALL(&ex, E_SEEK, f_64, (int64_t)0);
    int nv = 0, na = 0, back = 0; int64_t prev = -1;
    for (;;) {
        uint64_t ti = 9; int64_t t = -1;
        if (VCALL(&ex, E_TRACK, f_pu64, &ti) != ST_OK) break;
        VCALL(&ex, E_TIME, f_p64, &t);
        if ((int)ti == vt) nv++; else na++;
        if (t < prev - 50000) back = 1;
        if (t > prev) prev = t;
        VCALL(&ex, E_ADVANCE, f_v);
    }
    EXPECT("both tracks selected: 12 video samples among the audio packets, by time (none more than 50 ms behind)", N * 10, nv * 10 + back);
    EXPECT("... half a second of AAC packets (1024 frames each: 23 to 27)", 1, na >= 23 && na <= 27);
    printf("(%d audio packets)\n", na);

    // Extractor by path: the file opened in place, no copy
    obj exp = {0}, exn = {0}; mv_Extractor((void **)&exp, 0); mv_Extractor((void **)&exn, 0);
    EXPECT("SetDataSource(\"content:/none.mp4\"), a missing file: UnsupportedMediaType", ST_UNSUPPORTED_MEDIA, VCALL(&exn, E_SETPATH, f_ptr, "content:/none.mp4"));
    EXPECT("SetDataSource(\"content:/p.mp4\")", ST_OK, VCALL(&exp, E_SETPATH, f_ptr, "content:/p.mp4"));
    nt = 0; VCALL(&exp, E_COUNT, f_i, &nt);
    EXPECT("... two tracks, read in place: still one copy in DM_TEMP", 21, nt * 10 + count_copies());

    // Decoders that refuse
    int st = 0; void *none = NULL; mv_MediaData(&none);
    VCALL(&ex, E_UNSELECT, f_int, at);
    new_decoder(DEC_AAC, 1, md[vt], &st); EXPECT("an AAC decoder configured with the video track: UnsupportedMediaType", ST_UNSUPPORTED_MEDIA, st);
    new_decoder(DEC_VP9, 4, md[vt], &st); EXPECT("a VP9 decoder (nothing decodes it) configured with the video track: UnsupportedMediaType", ST_UNSUPPORTED_MEDIA, st);
    new_decoder(DEC_AVC, 4, none, &st); EXPECT("Configure without a track configuration: InvalidConfiguration", ST_INVALID_CONFIG, st);

    // H.264 to NV12
    memset(t_events, 0, sizeof t_events);
    obj *dec = new_decoder(DEC_AVC, 4, md[vt], &st);
    EXPECT("an H.264 decoder configured with the video track", ST_OK, st);
    if (st != ST_OK) { SUMMARY(); return 1; }
    int32_t osz = 0, oal = 0; VCALL(dec, D_OUTSIZE, f_ii, &osz, &oal);
    EXPECT("GetOutputBufferSize: one NV12 frame, alignment 256", W * H * 3 / 2 * 1000 + 256, osz * 1000 + oal);
    VCALL(dec, D_START, f_v);
    EXPECT("Start signals input available and format changed (the events filled in after they were registered)", 11, (t_events[EV_INPUT] > 0) * 10 + (t_events[EV_FORMAT] == 1));
    VCALL(&ex, E_SEEK, f_64, (int64_t)0);
    outlog L = OUTLOG; run(&ex, dec, &L, 1, 1);
    int at_times = L.n == N; for (int i = 0; i < L.n && i < N; i++) if (llabs(L.pts[i] - pts_us(i)) > 1) at_times = 0;
    EXPECT("12 frames decoded, then the end-of-stream output", N * 10 + 1, L.n * 10 + L.eos);
    EXPECT("... frame i at i / 24 s, in order, each one NV12 frame", 111, L.order_ok * 100 + at_times * 10 + L.sizes_ok);
    EXPECT("... NV12 values within 4 of what was encoded (Y, then Cb Cr interleaved)", 1, L.values_ok);
    EXPECT("... output available signalled, format changed before the first output", 11, (t_events[EV_OUTPUT] > 0) * 10 + L.format_first);
    { int32_t o, orem; int64_t opts; uint32_t ofl;
      EXPECT("... and no second end-of-stream output", ST_OUT_NOT_AVAILABLE, VCALL(dec, D_ACQOUT, f_acq, &o, &opts, &ofl, &orem)); }
    void *of = NULL; VCALL(dec, D_OUTFMT, f_md, &of);
    int32_t stride = 0, uvo = 0, cl = -1, ct = -1, cr = -1, cb = -1; mv_FindInt32(&of, "stride", &stride); mv_FindInt32(&of, "nv12-uv-offset", &uvo); mv_FindRect(&of, "crop", &cl, &ct, &cr, &cb);
    EXPECT("output format: stride = width, nv12-uv-offset = width x height, crop inclusive", 1, stride == W && uvo == W * H && cl == 0 && ct == 0 && cr == W - 1 && cb == H - 1);
    printf("(largest NV12 difference from what was encoded: %d)\n", g_maxdiff);

    // A loop: the game seeks back at the end of the stream and feeds on, with no end-of-stream input. The decoder learns that its read has ended
    // from the first input of the second round (no output for it) and reads again from the time of the next one, sample 1's: 41666 us, a little
    // before frame 1's 1 / 24 s, so AVFoundation gives frame 0 first, at that time (a range that starts inside a frame's display time begins with
    // that frame). Every picture comes once more, the first of them one frame's time late.
    obj *ld = new_decoder(DEC_AVC, 4, md[vt], &st); VCALL(ld, D_START, f_v); VCALL(&ex, E_SEEK, f_64, (int64_t)0);
    outlog A = OUTLOG; run(&ex, ld, &A, 1, 0);
    VCALL(&ex, E_SEEK, f_64, (int64_t)0);
    outlog B = OUTLOG; run(&ex, ld, &B, 1, 1);
    EXPECT("a loop: the first round gives 12 frames and no end of stream", N * 10, A.n * 10 + A.eos);
    int pics = B.n == N, late = B.n == N; for (int i = 0; i < B.n && i < N; i++) { if (B.pic[i] != i) pics = 0; if (llabs(B.pts[i] - pts_us(i ? i : 1)) > 1) late = 0; }
    EXPECT("... the second gives all 12 again, then the end of stream", N * 10 + 1, B.n * 10 + B.eos);
    EXPECT("... each picture once and in order; times in order, frame 0's that of frame 1", 111, pics * 100 + B.order_ok * 10 + late);

    // Flush
    obj *fd = new_decoder(DEC_AVC, 4, md[vt], &st); VCALL(fd, D_START, f_v); VCALL(&ex, E_SEEK, f_64, (int64_t)0);
    int sent = 0;
    for (; sent < 8; sent++) {
        int32_t idx, rem; mvbuf in; int64_t t = 0;
        if (VCALL(fd, D_ACQIN, f_ii, &idx, &rem) != ST_OK) break;
        VCALL(fd, D_GETIN, f_ib, idx, &in); VCALL(&ex, E_READ, f_buf, &in); VCALL(&ex, E_TIME, f_p64, &t);
        VCALL(fd, D_SEND, f_send, idx, in.off, in.size, t, (uint32_t)0); VCALL(&ex, E_ADVANCE, f_v);
    }
    { int32_t idx, rem, o, orem; int64_t opts; uint32_t ofl;
      EXPECT("eight inputs sent and no output taken: four answered, four waiting, no input buffer free", 8 * 10000 + ST_IN_NOT_AVAILABLE, sent * 10000 + VCALL(fd, D_ACQIN, f_ii, &idx, &rem));
      int ev = t_events[EV_INPUT], got = 0; VCALL(fd, D_FLUSH, f_v);
      while (got < 16 && VCALL(fd, D_ACQIN, f_ii, &idx, &rem) == ST_OK) got++;
      EXPECT("Flush gives every input buffer back and signals input available", 41, got * 10 + (t_events[EV_INPUT] > ev));
      EXPECT("... and drops the decoded frames nobody took", ST_OUT_NOT_AVAILABLE, VCALL(fd, D_ACQOUT, f_acq, &o, &opts, &ofl, &orem)); }

    // AAC to PCM16
    VCALL(&ex, E_UNSELECT, f_int, vt); VCALL(&ex, E_SELECT, f_int, at); VCALL(&ex, E_SEEK, f_64, (int64_t)0);
    memset(t_events, 0, sizeof t_events);
    obj *ad = new_decoder(DEC_AAC, 1, md[at], &st);
    EXPECT("an AAC decoder configured with the audio track", ST_OK, st);
    osz = oal = 0; VCALL(ad, D_OUTSIZE, f_ii, &osz, &oal);
    EXPECT("GetOutputBufferSize: 1024 stereo frames of PCM16, alignment 256", 4096 * 1000 + 256, osz * 1000 + oal);
    VCALL(ad, D_START, f_v);
    outlog P = OUTLOG; run(&ex, ad, &P, 0, 1);
    double rms = P.nsamp ? sqrt(P.sumsq / (double)P.nsamp) : 0;
    EXPECT("audio decoded to the end of the stream, in whole stereo frames, 1024 at most a chunk, times in order", 111, P.eos * 100 + P.sizes_ok * 10 + P.order_ok);
    EXPECT("... about half a second of PCM (24000 frames within 2048)", 1, labs(P.bytes / 4 - 24000) <= 2048);
    EXPECT("... the half-scale 440 Hz sine in it (RMS 11585 within 10 %, 440 sign changes within 5 %)", 1, fabs(rms - 11585) < 1159 && abs(P.turns - HZ) <= 22);
    printf("(%ld frames of PCM in %d chunks, RMS %.0f, %d sign changes)\n", P.bytes / 4, P.n, rms, P.turns);

    // The copy leaves with the last Extractor on its path
    VCALL(&ex, E_DTOR, f_dtor);
    int left = count_copies(); VCALL(&ex2, E_DTOR, f_dtor); VCALL(&exp, E_DTOR, f_dtor);
    EXPECT("the copy stays while one Extractor uses it and is removed with the last", 10, left * 10 + count_copies());
    SUMMARY();
    return g_fail != 0;
}
