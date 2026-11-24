/*
 * HPACK decode runner for nghttp2 1.71.0 (bench/hpack/run_ab.rb), built
 * out of tree against the libnghttp2.a fuzz/hpack_nghttp2/build.sh makes:
 *
 *   cc -O2 -I$WORK/prefix/include bench/hpack/nghttp2_runner.c $WORK/prefix/lib/libnghttp2.a -o nghttp2_runner
 *   nghttp2_runner CORPUS WARMUP PASSES
 *
 * Same corpus, same work and same output as bench/hpack/mica_runner.cr.
 */
#include <nghttp2/nghttp2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint8_t *corpus;
static size_t corpus_size;

static uint32_t u32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void pass(long long *fields, long long *field_bytes) {
  nghttp2_hd_inflater *inflater = NULL;
  size_t at = 0;
  *fields = 0;
  *field_bytes = 0;
  while (at < corpus_size) {
    uint8_t kind = corpus[at++];
    if (kind == 'S') {
      if (inflater) nghttp2_hd_inflate_del(inflater);
      if (nghttp2_hd_inflate_new(&inflater) != 0) exit(2);
    } else if (kind == 'T') {
      if (nghttp2_hd_inflate_change_table_size(inflater, u32(corpus + at)) != 0) exit(2);
      at += 4;
    } else {
      uint32_t len = u32(corpus + at);
      const uint8_t *in = corpus + at + 4;
      at += 4 + len;
      for (;;) {
        nghttp2_nv nv;
        int flags = 0;
        nghttp2_ssize rv = nghttp2_hd_inflate_hd3(inflater, &nv, &flags, in, len, 1);
        if (rv < 0) { fprintf(stderr, "inflate failed\n"); exit(2); }
        in += rv;
        len -= (uint32_t)rv;
        if (flags & NGHTTP2_HD_INFLATE_EMIT) {
          (*fields)++;
          *field_bytes += (long long)(nv.namelen + nv.valuelen);
        }
        if (flags & NGHTTP2_HD_INFLATE_FINAL) { nghttp2_hd_inflate_end_headers(inflater); break; }
        if ((flags & NGHTTP2_HD_INFLATE_EMIT) == 0 && len == 0) break;
      }
    }
  }
  if (inflater) nghttp2_hd_inflate_del(inflater);
}

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  FILE *file = fopen(argv[1], "rb");
  if (!file) return 2;
  fseek(file, 0, SEEK_END);
  corpus_size = (size_t)ftell(file);
  fseek(file, 0, SEEK_SET);
  corpus = malloc(corpus_size);
  if (fread(corpus, 1, corpus_size, file) != corpus_size) return 2;
  fclose(file);
  long long fields, field_bytes;
  for (int i = 0; i < atoi(argv[2]); i++) pass(&fields, &field_bytes);
  for (int i = 0; i < atoi(argv[3]); i++) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    pass(&fields, &field_bytes);
    clock_gettime(CLOCK_MONOTONIC, &end);
    long long ns = (long long)(end.tv_sec - start.tv_sec) * 1000000000LL + (end.tv_nsec - start.tv_nsec);
    printf("pass %lld %lld %lld\n", ns, fields, field_bytes);
  }
  return 0;
}
