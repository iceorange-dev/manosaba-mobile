// gfx/nvn/vk/vk_misc.c: what the interface layer tells a backend that the Vulkan one does not use yet (plan item 301e): program keys and releases
// (the shaders come with 301e2), the store lookahead index, the depth convention (the translation's answer), the upscaling pass,
// pipeline warming and texture dumps.
#include "vk.h"

int g_dm_present_link;   // the present pacing switch (nvn_mtl.m's): 0, no display link here
void mtl_prog_release(prog_t *p) { (void)p; }
void mtl_prog_fkeys(uint64_t serial, const uint8_t fk[6][8]) { (void)serial; (void)fk; }
void mtl_sub_index(const uint64_t *h, int n) { (void)h; (void)n; }
void mtl_set_depth_mode(int m) { (void)m; }
int mtl_warm_wait(int timeout_ms) { (void)timeout_ms; return 0; }
void mtl_texdump_next(const char *path) { (void)path; }
