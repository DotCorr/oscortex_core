/* Platform FFmpeg: open a container, decode one frame, read a pixel. */
#include "osmedia.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#ifndef OSMEDIA_GUEST
#include <libswscale/swscale.h>
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef OSMEDIA_GUEST
void osmedia_trace(const char *s);
#endif

struct OsMedia {
  AVFormatContext *fmt;
  AVCodecContext *ctx;
  int stream;
  int live;
  int w;
  int h;
  uint32_t *rgb;
  const char *backend;
  uint8_t *annex;
  int annex_len;
  int annex_off;
};

static int g_no_ffmpeg = 0;
static int g_inited = 0;

static uint32_t *alloc_rgb(int w, int h) {
  size_t n;
  if (w <= 0 || h <= 0) {
    return 0;
  }
  n = (size_t)w * (size_t)h;
  return (uint32_t *)calloc(n, sizeof(uint32_t));
}

int osmedia_init(void) {
#ifndef OSMEDIA_GUEST
  const char *e;
  e = getenv("OSMEDIA_NO_FFMPEG");
  g_no_ffmpeg = (e != 0 && e[0] == '1' && e[1] == 0);
#else
  g_no_ffmpeg = 0;
#endif
  if (!g_no_ffmpeg) {
    av_log_set_level(AV_LOG_ERROR);
  }
  g_inited = 1;
  return OSMEDIA_OK;
}

void osmedia_shutdown(void) {
  g_inited = 0;
  g_no_ffmpeg = 0;
}

int osmedia_backend_ffmpeg(void) { return 1; }

const char *osmedia_version(void) {
  const char *v;
  if (g_no_ffmpeg) {
    return "none";
  }
  v = av_version_info();
  if (v == 0) {
    return "none";
  }
  return v;
}

const char *osmedia_backend_name(const OsMedia *m) {
  if (m == 0 || m->backend == 0) {
    return "none";
  }
  return m->backend;
}

static OsMedia *empty_handle(const char *backend) {
  OsMedia *m;
  m = (OsMedia *)calloc(1, sizeof(*m));
  if (m == 0) {
    return 0;
  }
  m->w = OSMEDIA_W;
  m->h = OSMEDIA_H;
  m->rgb = alloc_rgb(m->w, m->h);
  if (m->rgb == 0) {
    free(m);
    return 0;
  }
  m->backend = backend;
  m->live = 0;
  return m;
}

OsMedia *osmedia_open(const char *path) {
  AVFormatContext *fmt;
  const AVCodec *dec;
  AVCodecContext *ctx;
  int stream;
  int rc;
  OsMedia *m;

  if (!g_inited) {
    return 0;
  }
  if (g_no_ffmpeg) {
    return empty_handle("none");
  }
  if (path == 0 || path[0] == 0) {
    return 0;
  }

  fmt = 0;
  rc = avformat_open_input(&fmt, path, 0, 0);
  if (rc < 0) {
    return 0;
  }
  rc = avformat_find_stream_info(fmt, 0);
  if (rc < 0) {
    avformat_close_input(&fmt);
    return 0;
  }
  stream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
  if (stream < 0 || dec == 0) {
    avformat_close_input(&fmt);
    return 0;
  }
  ctx = avcodec_alloc_context3(dec);
  if (ctx == 0) {
    avformat_close_input(&fmt);
    return 0;
  }
  rc = avcodec_parameters_to_context(ctx, fmt->streams[stream]->codecpar);
  if (rc < 0) {
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    return 0;
  }
  rc = avcodec_open2(ctx, dec, 0);
  if (rc < 0) {
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    return 0;
  }

  m = (OsMedia *)calloc(1, sizeof(*m));
  if (m == 0) {
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    return 0;
  }
  m->w = ctx->width > 0 ? ctx->width : OSMEDIA_W;
  m->h = ctx->height > 0 ? ctx->height : OSMEDIA_H;
  m->rgb = alloc_rgb(m->w, m->h);
  if (m->rgb == 0) {
    free(m);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    return 0;
  }
  m->fmt = fmt;
  m->ctx = ctx;
  m->stream = stream;
  m->backend = "ffmpeg";
  m->live = 1;
  return m;
}

struct MemIO {
  const uint8_t *buf;
  int len;
  int pos;
};

static int mem_read(void *opaque, uint8_t *buf, int buf_size) {
  struct MemIO *io;
  int n;
  io = (struct MemIO *)opaque;
  if (io == 0 || buf == 0 || buf_size <= 0) {
    return AVERROR_EOF;
  }
  if (io->pos >= io->len) {
    return AVERROR_EOF;
  }
  n = io->len - io->pos;
  if (n > buf_size) {
    n = buf_size;
  }
  memcpy(buf, io->buf + io->pos, (size_t)n);
  io->pos = io->pos + n;
  return n;
}

static int64_t mem_seek(void *opaque, int64_t off, int whence) {
  struct MemIO *io;
  int64_t pos;
  io = (struct MemIO *)opaque;
  if (io == 0) {
    return -1;
  }
  if (whence == AVSEEK_SIZE) {
    return (int64_t)io->len;
  }
  if (whence == SEEK_SET) {
    pos = off;
  } else if (whence == SEEK_CUR) {
    pos = (int64_t)io->pos + off;
  } else if (whence == SEEK_END) {
    pos = (int64_t)io->len + off;
  } else {
    return -1;
  }
  if (pos < 0 || pos > (int64_t)io->len) {
    return -1;
  }
  io->pos = (int)pos;
  return pos;
}

#ifdef OSMEDIA_GUEST
static int annex_start(const uint8_t *b, int n, int from) {
  int i;
  for (i = from; i + 2 < n; i++) {
    if (i + 3 < n && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 &&
        b[i + 3] == 1) {
      return i;
    }
    if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
      return i;
    }
  }
  return -1;
}

static int annex_start_len(const uint8_t *b, int i) {
  if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1) {
    return 4;
  }
  return 3;
}

static int looks_annexb(const uint8_t *b, int n) {
  if (b == 0 || n < 4) {
    return 0;
  }
  if (b[0] == 0 && b[1] == 0 && b[2] == 1) {
    return 1;
  }
  if (b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1) {
    return 1;
  }
  return 0;
}

static OsMedia *open_annex_h264(const uint8_t *buf, int len) {
  const AVCodec *dec;
  AVCodecContext *ctx;
  OsMedia *m;
  uint8_t *copy;
  int rc;

  osmedia_trace("OSMEDIA ANNEX");
  dec = avcodec_find_decoder(AV_CODEC_ID_H264);
  osmedia_trace(dec == 0 ? "OSMEDIA NODEC" : "OSMEDIA DEC1");
  if (dec == 0) {
    return 0;
  }
  ctx = avcodec_alloc_context3(dec);
  osmedia_trace(ctx == 0 ? "OSMEDIA NOCTX" : "OSMEDIA CTX1");
  if (ctx == 0) {
    return 0;
  }
  ctx->thread_count = 1;
  osmedia_trace("OSMEDIA OPEN2");
  rc = avcodec_open2(ctx, dec, 0);
  osmedia_trace("OSMEDIA OPEN2-D");
  if (rc < 0) {
    avcodec_free_context(&ctx);
    return 0;
  }
  copy = (uint8_t *)malloc((size_t)len + 16);
  if (copy == 0) {
    avcodec_free_context(&ctx);
    return 0;
  }
  memcpy(copy, buf, (size_t)len);
  memset(copy + len, 0, 16);
  m = (OsMedia *)calloc(1, sizeof(*m));
  if (m == 0) {
    free(copy);
    avcodec_free_context(&ctx);
    return 0;
  }
  m->w = OSMEDIA_W;
  m->h = OSMEDIA_H;
  m->rgb = alloc_rgb(m->w, m->h);
  if (m->rgb == 0) {
    free(copy);
    free(m);
    avcodec_free_context(&ctx);
    return 0;
  }
  m->ctx = ctx;
  m->annex = copy;
  m->annex_len = len;
  m->annex_off = 0;
  m->backend = "ffmpeg";
  m->live = 1;
  m->stream = 0;
  osmedia_trace("OSMEDIA ANNEX-OK");
  return m;
}
#endif

OsMedia *osmedia_open_mem(const uint8_t *buf, int len) {
  AVFormatContext *fmt;
  const AVCodec *dec;
  AVCodecContext *ctx;
  AVIOContext *avio;
  uint8_t *iobuf;
  struct MemIO *io;
  int stream;
  int rc;
  OsMedia *m;

  if (!g_inited) {
    return 0;
  }
  if (g_no_ffmpeg) {
    return empty_handle("none");
  }
  if (buf == 0 || len <= 0) {
    return 0;
  }

#ifdef OSMEDIA_GUEST
  osmedia_trace("OSMEDIA MEM");
  if (looks_annexb(buf, len)) {
    return open_annex_h264(buf, len);
  }
#endif
  io = (struct MemIO *)calloc(1, sizeof(*io));
#ifdef OSMEDIA_GUEST
  osmedia_trace(io == 0 ? "OSMEDIA CAL0" : "OSMEDIA CAL1");
#endif
  if (io == 0) {
    return 0;
  }
  io->buf = buf;
  io->len = len;
  io->pos = 0;
#ifdef OSMEDIA_GUEST
  osmedia_trace("OSMEDIA AVM");
#endif
  iobuf = (uint8_t *)av_malloc(4096);
#ifdef OSMEDIA_GUEST
  osmedia_trace(iobuf == 0 ? "OSMEDIA AVM0" : "OSMEDIA AVM1");
#endif
#ifdef OSMEDIA_GUEST
  osmedia_trace("OSMEDIA CTX");
#endif
  if (iobuf == 0) {
    free(io);
    return 0;
  }
  avio = avio_alloc_context(iobuf, 4096, 0, io, mem_read, 0, mem_seek);
  if (avio == 0) {
    av_free(iobuf);
    free(io);
    return 0;
  }
  fmt = avformat_alloc_context();
  if (fmt == 0) {
    av_free(avio->buffer);
    avio_context_free(&avio);
    free(io);
    return 0;
  }
#ifdef OSMEDIA_GUEST
  osmedia_trace("OSMEDIA AVIO");
#endif
  fmt->pb = avio;
  fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
#ifdef OSMEDIA_GUEST
  {
    const AVInputFormat *iformat;
    void *it;
    it = 0;
    iformat = av_demuxer_iterate(&it);
    fmt->probesize = 2048;
    fmt->max_analyze_duration = 0;
    osmedia_trace("OSMEDIA AVOI");
    rc = avformat_open_input(&fmt, "clip.mp4", iformat, 0);
    osmedia_trace("OSMEDIA AVOI-D");
  }
#else
  rc = avformat_open_input(&fmt, "clip.mp4", 0, 0);
#endif
  if (rc < 0) {
    av_free(avio->buffer);
    avio_context_free(&avio);
    avformat_free_context(fmt);
    free(io);
    return 0;
  }
#ifdef OSMEDIA_GUEST
  if (fmt->nb_streams == 0) {
#endif
  rc = avformat_find_stream_info(fmt, 0);
  if (rc < 0) {
    avformat_close_input(&fmt);
    free(io);
    return 0;
  }
#ifdef OSMEDIA_GUEST
  }
#endif
  stream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
  if (stream < 0 || dec == 0) {
    avformat_close_input(&fmt);
    free(io);
    return 0;
  }
  ctx = avcodec_alloc_context3(dec);
  if (ctx == 0) {
    avformat_close_input(&fmt);
    free(io);
    return 0;
  }
  rc = avcodec_parameters_to_context(ctx, fmt->streams[stream]->codecpar);
  if (rc < 0) {
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    free(io);
    return 0;
  }
  rc = avcodec_open2(ctx, dec, 0);
  if (rc < 0) {
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    free(io);
    return 0;
  }

  m = (OsMedia *)calloc(1, sizeof(*m));
  if (m == 0) {
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    free(io);
    return 0;
  }
  m->w = ctx->width > 0 ? ctx->width : OSMEDIA_W;
  m->h = ctx->height > 0 ? ctx->height : OSMEDIA_H;
  m->rgb = alloc_rgb(m->w, m->h);
  if (m->rgb == 0) {
    free(m);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    free(io);
    return 0;
  }
  m->fmt = fmt;
  m->ctx = ctx;
  m->stream = stream;
  m->backend = "ffmpeg";
  m->live = 1;
  return m;
}

void osmedia_close(OsMedia *m) {
  if (m == 0) {
    return;
  }
  if (m->ctx != 0) {
    avcodec_free_context(&m->ctx);
  }
  if (m->fmt != 0) {
    avformat_close_input(&m->fmt);
  }
  free(m->annex);
  free(m->rgb);
  free(m);
}

#ifdef OSMEDIA_GUEST
static int clamp8(int v) {
  if (v < 0) {
    return 0;
  }
  if (v > 255) {
    return 255;
  }
  return v;
}

static int copy_yuv420_rgb(OsMedia *m, AVFrame *frame) {
  int x;
  int y;
  int w;
  int h;
  w = frame->width;
  h = frame->height;
  for (y = 0; y < h; y++) {
    const uint8_t *yp;
    const uint8_t *up;
    const uint8_t *vp;
    yp = frame->data[0] + y * frame->linesize[0];
    up = frame->data[1] + (y / 2) * frame->linesize[1];
    vp = frame->data[2] + (y / 2) * frame->linesize[2];
    for (x = 0; x < w; x++) {
      int Y;
      int U;
      int V;
      int r;
      int g;
      int b;
      Y = (int)yp[x];
      U = (int)up[x / 2] - 128;
      V = (int)vp[x / 2] - 128;
      r = clamp8(Y + ((91881 * V) >> 16));
      g = clamp8(Y - ((22554 * U + 46802 * V) >> 16));
      b = clamp8(Y + ((116130 * U) >> 16));
      m->rgb[y * w + x] =
          ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    }
  }
  return OSMEDIA_OK;
}
#endif

static int copy_frame_rgb(OsMedia *m, AVFrame *frame) {
#ifndef OSMEDIA_GUEST
  struct SwsContext *sws;
  uint8_t *dst[4];
  int dst_linesize[4];
  uint8_t *tmp;
#endif
  int x;
  int y;
  int w;
  int h;

  w = frame->width;
  h = frame->height;
  if (w <= 0 || h <= 0) {
    return OSMEDIA_ERR;
  }
  if (w != m->w || h != m->h) {
    uint32_t *nrgb;
    nrgb = alloc_rgb(w, h);
    if (nrgb == 0) {
      return OSMEDIA_ERR;
    }
    free(m->rgb);
    m->rgb = nrgb;
    m->w = w;
    m->h = h;
  }

#ifdef OSMEDIA_GUEST
  (void)x;
  (void)y;
  if (frame->format != AV_PIX_FMT_YUV420P &&
      frame->format != AV_PIX_FMT_YUVJ420P) {
    return OSMEDIA_ERR;
  }
  if (frame->data[0] == 0 || frame->data[1] == 0 || frame->data[2] == 0) {
    return OSMEDIA_ERR;
  }
  return copy_yuv420_rgb(m, frame);
#else
  tmp = (uint8_t *)malloc((size_t)w * (size_t)h * 3u);
  if (tmp == 0) {
    return OSMEDIA_ERR;
  }
  dst[0] = tmp;
  dst[1] = 0;
  dst[2] = 0;
  dst[3] = 0;
  dst_linesize[0] = w * 3;
  dst_linesize[1] = 0;
  dst_linesize[2] = 0;
  dst_linesize[3] = 0;

  sws = sws_getContext(w, h, (enum AVPixelFormat)frame->format, w, h,
                       AV_PIX_FMT_RGB24, SWS_BILINEAR, 0, 0, 0);
  if (sws == 0) {
    free(tmp);
    return OSMEDIA_ERR;
  }
  sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, h,
            dst, dst_linesize);
  sws_freeContext(sws);

  for (y = 0; y < h; y++) {
    for (x = 0; x < w; x++) {
      const uint8_t *p;
      p = tmp + ((size_t)y * (size_t)w + (size_t)x) * 3u;
      m->rgb[y * w + x] =
          ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
    }
  }
  free(tmp);
  return OSMEDIA_OK;
#endif
}

int osmedia_decode_frame(OsMedia *m) {
  AVPacket *pkt;
  AVFrame *frame;
  int got;
  int rc;

  if (m == 0 || !m->live || m->ctx == 0) {
    return OSMEDIA_ERR;
  }
  if (m->fmt == 0 && m->annex == 0) {
    return OSMEDIA_ERR;
  }

  pkt = av_packet_alloc();
  frame = av_frame_alloc();
  if (pkt == 0 || frame == 0) {
    av_packet_free(&pkt);
    av_frame_free(&frame);
    return OSMEDIA_ERR;
  }

  got = 0;
#ifdef OSMEDIA_GUEST
  if (m->annex != 0 && m->fmt == 0) {
    int off;
    off = m->annex_off;
    while (off < m->annex_len) {
      int start;
      int sl;
      int next;
      int end;
      int sz;
      start = annex_start(m->annex, m->annex_len, off);
      if (start < 0) {
        off = m->annex_len;
        break;
      }
      sl = annex_start_len(m->annex, start);
      next = annex_start(m->annex, m->annex_len, start + sl);
      end = next < 0 ? m->annex_len : next;
      sz = end - start;
      if (sz <= 0) {
        break;
      }
      pkt->data = m->annex + start;
      pkt->size = sz;
      rc = avcodec_send_packet(m->ctx, pkt);
      pkt->data = 0;
      pkt->size = 0;
      off = end;
      m->annex_off = off;
      if (rc < 0) {
        break;
      }
      rc = avcodec_receive_frame(m->ctx, frame);
      if (rc == 0) {
        got = 1;
        break;
      }
      if (rc != AVERROR(EAGAIN)) {
        break;
      }
    }
    if (!got && off >= m->annex_len) {
      avcodec_send_packet(m->ctx, 0);
      rc = avcodec_receive_frame(m->ctx, frame);
      if (rc == 0) {
        got = 1;
      }
    }
    if (got) {
      rc = copy_frame_rgb(m, frame);
    } else {
      rc = OSMEDIA_ERR;
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return rc;
  }
#endif
  while (av_read_frame(m->fmt, pkt) >= 0) {
    if (pkt->stream_index != m->stream) {
      av_packet_unref(pkt);
      continue;
    }
    rc = avcodec_send_packet(m->ctx, pkt);
    av_packet_unref(pkt);
    if (rc < 0) {
      break;
    }
    rc = avcodec_receive_frame(m->ctx, frame);
    if (rc == 0) {
      got = 1;
      break;
    }
    if (rc != AVERROR(EAGAIN)) {
      break;
    }
  }
  if (!got) {
    avcodec_send_packet(m->ctx, 0);
    rc = avcodec_receive_frame(m->ctx, frame);
    if (rc == 0) {
      got = 1;
    }
  }

  if (got) {
    rc = copy_frame_rgb(m, frame);
  } else {
    rc = OSMEDIA_ERR;
  }

  av_frame_free(&frame);
  av_packet_free(&pkt);
  return rc;
}

int osmedia_readback(OsMedia *m, uint32_t *out, int max_pixels) {
  int n;
  int i;
  if (m == 0 || m->rgb == 0 || out == 0 || max_pixels <= 0) {
    return -1;
  }
  n = m->w * m->h;
  if (n > max_pixels) {
    n = max_pixels;
  }
  for (i = 0; i < n; i++) {
    out[i] = m->rgb[i];
  }
  return n;
}

int osmedia_pixel(OsMedia *m, int x, int y, uint32_t *out) {
  if (m == 0 || m->rgb == 0 || out == 0) {
    return OSMEDIA_ERR;
  }
  if (x < 0 || y < 0 || x >= m->w || y >= m->h) {
    return OSMEDIA_ERR;
  }
  *out = m->rgb[y * m->w + x];
  return OSMEDIA_OK;
}

int osmedia_ppm_write(OsMedia *m, const char *path) {
  FILE *f;
  int x;
  int y;
  uint32_t p;
  if (m == 0 || m->rgb == 0 || path == 0) {
    return OSMEDIA_ERR;
  }
  f = fopen(path, "wb");
  if (f == 0) {
    return OSMEDIA_ERR;
  }
  if (fprintf(f, "P6\n%d %d\n255\n", m->w, m->h) < 0) {
    fclose(f);
    return OSMEDIA_ERR;
  }
  for (y = 0; y < m->h; y++) {
    for (x = 0; x < m->w; x++) {
      unsigned char rgb[3];
      p = m->rgb[y * m->w + x];
      rgb[0] = (unsigned char)((p >> 16) & 0xFF);
      rgb[1] = (unsigned char)((p >> 8) & 0xFF);
      rgb[2] = (unsigned char)(p & 0xFF);
      if (fwrite(rgb, 1, 3, f) != 3) {
        fclose(f);
        return OSMEDIA_ERR;
      }
    }
  }
  if (fclose(f) != 0) {
    return OSMEDIA_ERR;
  }
  return OSMEDIA_OK;
}
