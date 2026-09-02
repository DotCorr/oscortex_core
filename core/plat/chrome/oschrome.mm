/* Platform Chromium Content via official CEF. Not Metal. Not Flutter. */
#include "oschrome.h"

#import <Cocoa/Cocoa.h>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_render_handler.h"
#include "include/wrapper/cef_library_loader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

int g_inited = 0;
int g_no_chromium = 0;
CefRefPtr<CefApp> g_app;
CefScopedLibraryLoader* g_loader = nullptr;

class OsChromeApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString& /*process_type*/,
      CefRefPtr<CefCommandLine> cl) override {
    cl->AppendSwitch("disable-gpu");
    cl->AppendSwitch("disable-gpu-compositing");
    cl->AppendSwitch("in-process-gpu");
    cl->AppendSwitch("no-sandbox");
    cl->AppendSwitch("disable-extensions");
    cl->AppendSwitch("disable-background-networking");
    cl->AppendSwitch("disable-sync");
    cl->AppendSwitch("disable-default-apps");
    cl->AppendSwitch("disable-translate");
    cl->AppendSwitch("disable-component-update");
    cl->AppendSwitch("no-first-run");
    cl->AppendSwitch("use-mock-keychain");
    /* Software rasterizer stays ON — disable-gpu without it has no paint. */
  }
  IMPLEMENT_REFCOUNTING(OsChromeApp);
};

class OsChromeClient : public CefClient,
                       public CefRenderHandler,
                       public CefLifeSpanHandler,
                       public CefLoadHandler {
 public:
  OsChromeClient(int w, int h)
      : w_(w),
        h_(h),
        painted_(0),
        loaded_(0),
        pixels_(static_cast<size_t>(w) * h, 0u) {}

  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  void GetViewRect(CefRefPtr<CefBrowser> /*browser*/, CefRect& rect) override {
    rect = CefRect(0, 0, w_, h_);
  }

  void OnPaint(CefRefPtr<CefBrowser> /*browser*/, PaintElementType type,
               const RectList& /*dirty*/, const void* buffer, int width,
               int height) override {
    if (type != PET_VIEW || buffer == 0 || width <= 0 || height <= 0) {
      return;
    }
    const int copy_w = width < w_ ? width : w_;
    const int copy_h = height < h_ ? height : h_;
    const uint8_t* src = static_cast<const uint8_t*>(buffer);
    for (int y = 0; y < copy_h; y++) {
      for (int x = 0; x < copy_w; x++) {
        const uint8_t* p = src + (static_cast<size_t>(y) * width + x) * 4;
        /* CEF OSR is BGRA. */
        uint32_t rgb = (static_cast<uint32_t>(p[2]) << 16) |
                       (static_cast<uint32_t>(p[1]) << 8) |
                       static_cast<uint32_t>(p[0]);
        pixels_[static_cast<size_t>(y) * w_ + x] = rgb;
      }
    }
    /* First OSR frame is often black; wait until a non-zero sample. */
    if (pixels_[0] != 0 || (w_ > 1 && h_ > 1 &&
                            pixels_[static_cast<size_t>(h_ / 2) * w_ + w_ / 2] !=
                                0)) {
      painted_ = 1;
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> /*browser*/,
                 CefRefPtr<CefFrame> /*frame*/,
                 int /*httpStatusCode*/) override {
    loaded_ = 1;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> /*browser*/) override {
    browser_ = nullptr;
  }

  int painted() const { return painted_; }
  int loaded() const { return loaded_; }
  const uint32_t* pixels() const { return pixels_.data(); }
  int w() const { return w_; }
  int h() const { return h_; }
  CefRefPtr<CefBrowser> browser() const { return browser_; }

  IMPLEMENT_REFCOUNTING(OsChromeClient);

 private:
  int w_;
  int h_;
  int painted_;
  int loaded_;
  std::vector<uint32_t> pixels_;
  CefRefPtr<CefBrowser> browser_;
};

const char* cache_dir() {
  static char path[512];
  if (path[0] == 0) {
    const char* tmp = getenv("TMPDIR");
    if (tmp == 0 || tmp[0] == 0) {
      tmp = "/tmp";
    }
    snprintf(path, sizeof(path), "%s/oschrome-cef-cache", tmp);
    mkdir(path, 0755);
  }
  return path;
}

void pump_once() {
  CefDoMessageLoopWork();
  NSDate* until = [NSDate dateWithTimeIntervalSinceNow:0.01];
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
}

}  // namespace

struct OsChrome {
  int w;
  int h;
  int no_chromium;
  CefRefPtr<OsChromeClient> client;
  std::vector<uint32_t> fallback;
};

int oschrome_backend_chromium(void) { return 1; }

const char* oschrome_backend_name(const OsChrome* b) {
  if (b == 0) {
    return "none";
  }
  if (b->no_chromium || g_no_chromium) {
    return "none";
  }
  return "chromium";
}

int oschrome_default_data_url(char* buf, int buf_n) {
  unsigned r = (OSCHROME_PAGE >> 16) & 0xFFu;
  unsigned g = (OSCHROME_PAGE >> 8) & 0xFFu;
  unsigned b = OSCHROME_PAGE & 0xFFu;
  /* rgb() not #RRGGBB — '#' is a data: URL fragment. */
  int n = snprintf(
      buf, buf_n > 0 ? static_cast<size_t>(buf_n) : 0,
      "data:text/html;charset=utf-8,"
      "<!doctype html><html><head><style>"
      "html,body{margin:0;background:rgb(%u,%u,%u);width:100%%;height:100%%}"
      "</style></head><body></body></html>",
      r, g, b);
  if (n < 0 || (buf_n > 0 && n >= buf_n)) {
    return -1;
  }
  return n;
}

int oschrome_init(int argc, char** argv) {
  if (g_inited) {
    return OSCHROME_OK;
  }
  const char* skip = getenv("OSCHROME_NO_CHROMIUM");
  if (skip != 0 && skip[0] == '1' && skip[1] == 0) {
    g_no_chromium = 1;
    g_inited = 1;
    return OSCHROME_OK;
  }

  [NSApplication sharedApplication];

  /* Loader must outlive CefInitialize — the destructor unloads the
     framework. Helpers _exit and never destroy it. */
  g_loader = new CefScopedLibraryLoader();
  int is_helper = 0;
  for (int i = 1; i < argc; i++) {
    if (argv[i] != 0 && strncmp(argv[i], "--type=", 7) == 0) {
      is_helper = 1;
      break;
    }
  }
  if (is_helper) {
    if (!g_loader->LoadInHelper()) {
      return OSCHROME_ERR;
    }
    CefMainArgs main_args(argc, argv);
    int code = CefExecuteProcess(main_args, nullptr, nullptr);
    _exit(code >= 0 ? code : 0);
  }
  if (!g_loader->LoadInMain()) {
    delete g_loader;
    g_loader = nullptr;
    return OSCHROME_ERR;
  }

  CefMainArgs main_args(argc, argv);
  int code = CefExecuteProcess(main_args, nullptr, nullptr);
  if (code >= 0) {
    _exit(code);
  }

  CefSettings settings;
  settings.windowless_rendering_enabled = true;
  settings.no_sandbox = true;
  settings.log_severity = LOGSEVERITY_ERROR;
  settings.external_message_pump = true;
  CefString(&settings.root_cache_path).FromASCII(cache_dir());
  CefString(&settings.cache_path).FromASCII(cache_dir());

  g_app = new OsChromeApp();
  if (!CefInitialize(main_args, settings, g_app, nullptr)) {
    g_app = nullptr;
    return OSCHROME_ERR;
  }
  g_inited = 1;
  return OSCHROME_OK;
}

void oschrome_shutdown(void) {
  if (!g_inited) {
    return;
  }
  if (!g_no_chromium) {
    CefShutdown();
  }
  g_app = nullptr;
  delete g_loader;
  g_loader = nullptr;
  g_inited = 0;
  g_no_chromium = 0;
}

OsChrome* oschrome_create(int w, int h) {
  if (w <= 0 || h <= 0) {
    return 0;
  }
  OsChrome* b = new OsChrome();
  b->w = w;
  b->h = h;
  b->no_chromium = g_no_chromium;
  if (g_no_chromium) {
    b->fallback.assign(static_cast<size_t>(w) * h, 0u);
    return b;
  }
  if (!g_inited) {
    delete b;
    return 0;
  }
  b->client = new OsChromeClient(w, h);
  return b;
}

void oschrome_destroy(OsChrome* b) {
  if (b == 0) {
    return;
  }
  if (b->client.get() != 0) {
    CefRefPtr<CefBrowser> br = b->client->browser();
    if (br.get() != 0) {
      br->GetHost()->CloseBrowser(true);
      for (int i = 0; i < 50; i++) {
        pump_once();
      }
    }
    b->client = nullptr;
  }
  delete b;
}

int oschrome_load_url(OsChrome* b, const char* url) {
  if (b == 0 || url == 0 || url[0] == 0) {
    return OSCHROME_ERR;
  }
  if (b->no_chromium) {
    return OSCHROME_OK;
  }
  if (b->client.get() == 0) {
    return OSCHROME_ERR;
  }
  CefRefPtr<CefBrowser> existing = b->client->browser();
  if (existing.get() != 0) {
    existing->GetMainFrame()->LoadURL(url);
    return OSCHROME_OK;
  }
  CefWindowInfo info;
  info.SetAsWindowless(0);
  CefBrowserSettings bset;
  bset.windowless_frame_rate = 30;
  bset.background_color = 0xFF000000;
  CefBrowserHost::CreateBrowser(info, b->client, url, bset, nullptr, nullptr);
  return OSCHROME_OK;
}

int oschrome_pump(OsChrome* b, int timeout_ms) {
  if (b == 0) {
    return OSCHROME_ERR;
  }
  if (b->no_chromium) {
    return OSCHROME_OK;
  }
  if (timeout_ms <= 0) {
    timeout_ms = 20000;
  }
  const int slices = timeout_ms / 10 + 1;
  for (int i = 0; i < slices; i++) {
    pump_once();
    if (b->client.get() != 0 && b->client->browser().get() != 0 &&
        (i % 20) == 19) {
      b->client->browser()->GetHost()->Invalidate(PET_VIEW);
    }
    if (b->client.get() != 0 && b->client->painted()) {
      return OSCHROME_OK;
    }
  }
  return OSCHROME_ERR;
}

int oschrome_readback(OsChrome* b, uint32_t* out, int max_pixels) {
  if (b == 0 || out == 0 || max_pixels <= 0) {
    return -1;
  }
  int n = b->w * b->h;
  if (n > max_pixels) {
    n = max_pixels;
  }
  const uint32_t* src;
  if (b->no_chromium) {
    src = b->fallback.data();
  } else if (b->client.get() != 0) {
    src = b->client->pixels();
  } else {
    return -1;
  }
  memcpy(out, src, static_cast<size_t>(n) * sizeof(uint32_t));
  return n;
}

int oschrome_pixel(OsChrome* b, int x, int y, uint32_t* out) {
  if (b == 0 || out == 0 || x < 0 || y < 0 || x >= b->w || y >= b->h) {
    return OSCHROME_ERR;
  }
  const uint32_t* src;
  if (b->no_chromium) {
    src = b->fallback.data();
  } else if (b->client.get() != 0) {
    src = b->client->pixels();
  } else {
    return OSCHROME_ERR;
  }
  *out = src[static_cast<size_t>(y) * b->w + x];
  return OSCHROME_OK;
}

int oschrome_ppm_write(OsChrome* b, const char* path) {
  if (b == 0 || path == 0) {
    return OSCHROME_ERR;
  }
  const uint32_t* src;
  if (b->no_chromium) {
    src = b->fallback.data();
  } else if (b->client.get() != 0) {
    src = b->client->pixels();
  } else {
    return OSCHROME_ERR;
  }
  FILE* f = fopen(path, "wb");
  if (f == 0) {
    return OSCHROME_ERR;
  }
  fprintf(f, "P6\n%d %d\n255\n", b->w, b->h);
  int n = b->w * b->h;
  for (int i = 0; i < n; i++) {
    uint32_t c = src[i];
    unsigned char rgb[3];
    rgb[0] = static_cast<unsigned char>((c >> 16) & 0xFFu);
    rgb[1] = static_cast<unsigned char>((c >> 8) & 0xFFu);
    rgb[2] = static_cast<unsigned char>(c & 0xFFu);
    if (fwrite(rgb, 1, 3, f) != 3) {
      fclose(f);
      return OSCHROME_ERR;
    }
  }
  fclose(f);
  return OSCHROME_OK;
}
