/*
 * The nghttp2 side of the HPACK differential (fuzz/hpack_differential.cr).
 * Built out of tree against libnghttp2 1.71.0 (see build.sh); never linked
 * into Mica. Reads commands on stdin and answers on stdout, all integers
 * big-endian u32:
 *
 *   'I' size        new inflater, then change_table_size(size)
 *   'S' size        inflater change_table_size(size)
 *   'D' len bytes   inflate one block -> 'K' count {nlen name vlen value flags}* table_size
 *                                       or 'E' error
 *   'Z' size        new deflater (max table size), then change_table_size(size)
 *   'T' size        deflater change_table_size(size)
 *   'H' count {nlen name vlen value flags}*  deflate one list -> 'B' len bytes
 *   'P' len bytes   decode-only timing: inflate the block, answer nothing
 *   'Q'             quit
 */
#include <nghttp2/nghttp2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static nghttp2_hd_inflater *inflater;
static nghttp2_hd_deflater *deflater;
static uint8_t *buffer;
static size_t buffer_size;

static void die(const char *what) { fprintf(stderr, "harness: %s\n", what); exit(2); }

static uint32_t read_u32(void) {
  uint8_t b[4];
  if (fread(b, 1, 4, stdin) != 4) die("short read");
  return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

static void write_u32(uint32_t v) {
  uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
  fwrite(b, 1, 4, stdout);
}

static uint8_t *read_bytes(uint32_t len) {
  if (len > buffer_size) {
    buffer_size = len * 2 + 16;
    buffer = realloc(buffer, buffer_size);
    if (!buffer) die("oom");
  }
  if (len && fread(buffer, 1, len, stdin) != len) die("short read");
  return buffer;
}

/* Inflates one block; with answer, writes the headers or the error. */
static void inflate_block(const uint8_t *in, size_t len, int answer) {
  static uint8_t *out;
  static size_t out_cap, out_len;
  uint32_t count = 0;
  int failed = 0;
  out_len = 0;
  for (;;) {
    nghttp2_nv nv;
    int flags = 0;
    nghttp2_ssize rv = nghttp2_hd_inflate_hd3(inflater, &nv, &flags, in, len, 1);
    if (rv < 0) { failed = 1; break; }
    in += rv;
    len -= (size_t)rv;
    if (flags & NGHTTP2_HD_INFLATE_EMIT) {
      count++;
      if (answer) {
        size_t need = out_len + 9 + nv.namelen + nv.valuelen;
        if (need > out_cap) { out_cap = need * 2; out = realloc(out, out_cap); if (!out) die("oom"); }
        uint8_t *p = out + out_len;
        p[0] = nv.namelen >> 24; p[1] = nv.namelen >> 16; p[2] = nv.namelen >> 8; p[3] = nv.namelen;
        memcpy(p + 4, nv.name, nv.namelen); p += 4 + nv.namelen;
        p[0] = nv.valuelen >> 24; p[1] = nv.valuelen >> 16; p[2] = nv.valuelen >> 8; p[3] = nv.valuelen;
        memcpy(p + 4, nv.value, nv.valuelen); p += 4 + nv.valuelen;
        *p++ = (nv.flags & NGHTTP2_NV_FLAG_NO_INDEX) ? 1 : 0;
        out_len = (size_t)(p - out);
      }
    }
    if (flags & NGHTTP2_HD_INFLATE_FINAL) { nghttp2_hd_inflate_end_headers(inflater); break; }
    if ((flags & NGHTTP2_HD_INFLATE_EMIT) == 0 && len == 0) break;
  }
  if (!answer) return;
  if (failed) { fputc('E', stdout); return; }
  fputc('K', stdout);
  write_u32(count);
  fwrite(out, 1, out_len, stdout);
  write_u32((uint32_t)nghttp2_hd_inflate_get_dynamic_table_size(inflater));
}

int main(void) {
  for (;;) {
    int op = fgetc(stdin);
    if (op == EOF || op == 'Q') break;
    switch (op) {
    case 'I': {
      uint32_t size = read_u32();
      if (inflater) nghttp2_hd_inflate_del(inflater);
      if (nghttp2_hd_inflate_new(&inflater) != 0) die("inflate_new");
      if (nghttp2_hd_inflate_change_table_size(inflater, size) != 0) die("inflate size");
      break;
    }
    case 'S':
      if (nghttp2_hd_inflate_change_table_size(inflater, read_u32()) != 0) die("inflate size");
      break;
    case 'D': {
      uint32_t len = read_u32();
      inflate_block(read_bytes(len), len, 1);
      fflush(stdout);
      break;
    }
    case 'P': {
      uint32_t len = read_u32();
      inflate_block(read_bytes(len), len, 0);
      break;
    }
    case 'Z': {
      uint32_t size = read_u32();
      if (deflater) nghttp2_hd_deflate_del(deflater);
      if (nghttp2_hd_deflate_new(&deflater, 65536) != 0) die("deflate_new");
      if (nghttp2_hd_deflate_change_table_size(deflater, size) != 0) die("deflate size");
      break;
    }
    case 'T':
      if (nghttp2_hd_deflate_change_table_size(deflater, read_u32()) != 0) die("deflate size");
      break;
    case 'H': {
      uint32_t count = read_u32();
      nghttp2_nv *nva = calloc(count ? count : 1, sizeof(nghttp2_nv));
      for (uint32_t i = 0; i < count; i++) {
        uint32_t nlen = read_u32();
        uint8_t *name = malloc(nlen + 1);
        if (nlen && fread(name, 1, nlen, stdin) != nlen) die("short read");
        uint32_t vlen = read_u32();
        uint8_t *value = malloc(vlen + 1);
        if (vlen && fread(value, 1, vlen, stdin) != vlen) die("short read");
        int flags = fgetc(stdin);
        nva[i] = (nghttp2_nv){name, value, nlen, vlen, (uint8_t)(flags ? NGHTTP2_NV_FLAG_NO_INDEX : 0)};
      }
      size_t bound = nghttp2_hd_deflate_bound(deflater, nva, count);
      uint8_t *out = malloc(bound + 1);
      ssize_t rv = nghttp2_hd_deflate_hd(deflater, out, bound, nva, count);
      if (rv < 0) die("deflate");
      fputc('B', stdout);
      write_u32((uint32_t)rv);
      fwrite(out, 1, (size_t)rv, stdout);
      fflush(stdout);
      for (uint32_t i = 0; i < count; i++) { free(nva[i].name); free(nva[i].value); }
      free(nva);
      free(out);
      break;
    }
    default:
      die("unknown command");
    }
  }
  fflush(stdout);
  return 0;
}
