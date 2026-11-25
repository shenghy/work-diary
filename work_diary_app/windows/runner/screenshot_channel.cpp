#include "screenshot_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <gdiplus.h>
#include <objidl.h>
#include <vector>
#include <string>
#include <memory>
#include <cstdint>
#include "screenshot_window.h"

#pragma comment(lib, "gdiplus.lib")

using namespace flutter;

// ---------- base64 编码 ----------
static std::string base64_encode(const unsigned char* data, size_t len) {
  static const char table[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result;
  result.reserve(((len + 2) / 3) * 4);
  for (size_t i = 0; i < len; i += 3) {
    uint32_t n = static_cast<uint32_t>(data[i]) << 16;
    if (i + 1 < len) n |= static_cast<uint32_t>(data[i + 1]) << 8;
    if (i + 2 < len) n |= static_cast<uint32_t>(data[i + 2]);
    result.push_back(table[(n >> 18) & 0x3F]);
    result.push_back(table[(n >> 12) & 0x3F]);
    result.push_back(i + 1 < len ? table[(n >> 6) & 0x3F] : '=');
    result.push_back(i + 2 < len ? table[n & 0x3F] : '=');
  }
  return result;
}

// ---------- 获取 PNG 编码器 CLSID ----------
static int GetEncoderClsid(const WCHAR* format, CLSID* pClsid) {
  UINT num = 0, size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;
  auto* info = static_cast<Gdiplus::ImageCodecInfo*>(malloc(size));
  if (!info) return -1;
  Gdiplus::GetImageEncoders(num, size, info);
  for (UINT j = 0; j < num; j++) {
    if (wcscmp(info[j].MimeType, format) == 0) {
      *pClsid = info[j].Clsid;
      free(info);
      return static_cast<int>(j);
    }
  }
  free(info);
  return -1;
}

// ---------- 截取指定区域（虚拟屏幕坐标），返回 PNG 字节 ----------
static std::vector<unsigned char> CaptureRegion(int x, int y, int w, int h) {
  std::vector<unsigned char> png_data;
  if (w <= 0 || h <= 0) {
    return png_data;
  }

  // 编码器先取：拿不到就不必再截整屏，也避免用未初始化的 CLSID 去 Save。
  CLSID png_clsid;
  if (GetEncoderClsid(L"image/png", &png_clsid) < 0) {
    return png_data;
  }

  Gdiplus::GdiplusStartupInput gdi_input;
  ULONG_PTR gdi_token = 0;
  if (Gdiplus::GdiplusStartup(&gdi_token, &gdi_input, nullptr) != Gdiplus::Ok) {
    return png_data;
  }

  HDC h_screen = GetDC(nullptr);
  HDC h_mem = CreateCompatibleDC(h_screen);
  HBITMAP h_bmp = CreateCompatibleBitmap(h_screen, w, h);

  if (h_mem != nullptr && h_bmp != nullptr) {
    HGDIOBJ old_bitmap = SelectObject(h_mem, h_bmp);
    // CAPTUREBLT：连分层/透明窗口一起截，避免漏掉悬浮窗、工具提示等。
    // 注意：HDR / 广色域显示器上 GDI 位图可能偏色，这是 BitBlt 的固有限制。
    BOOL captured = BitBlt(h_mem, 0, 0, w, h, h_screen, x, y,
                           SRCCOPY | CAPTUREBLT);
    SelectObject(h_mem, old_bitmap);

    if (captured != 0) {
      Gdiplus::Bitmap* bitmap = Gdiplus::Bitmap::FromHBITMAP(h_bmp, nullptr);
      if (bitmap != nullptr) {
        IStream* p_stream = nullptr;
        if (CreateStreamOnHGlobal(nullptr, TRUE, &p_stream) == S_OK) {
          if (bitmap->Save(p_stream, &png_clsid, nullptr) == Gdiplus::Ok) {
            STATSTG stat_info{};
            if (p_stream->Stat(&stat_info, STATFLAG_NONAME) == S_OK &&
                stat_info.cbSize.QuadPart > 0) {
              const ULONG png_size =
                  static_cast<ULONG>(stat_info.cbSize.QuadPart);
              png_data.resize(png_size);
              LARGE_INTEGER start{};
              ULONG read_bytes = 0;
              if (p_stream->Seek(start, STREAM_SEEK_SET, nullptr) == S_OK &&
                  SUCCEEDED(p_stream->Read(png_data.data(), png_size,
                                           &read_bytes)) &&
                  read_bytes > 0) {
                png_data.resize(read_bytes);
              } else {
                png_data.clear();
              }
            }
          }
          p_stream->Release();
        }
        delete bitmap;
      }
    }
  }

  if (h_bmp != nullptr) {
    DeleteObject(h_bmp);
  }
  if (h_mem != nullptr) {
    DeleteDC(h_mem);
  }
  ReleaseDC(nullptr, h_screen);
  Gdiplus::GdiplusShutdown(gdi_token);

  return png_data;
}

// ---------- 注册通道 ----------
void ScreenshotChannel::RegisterWithRegistrar(
    flutter::FlutterViewController* controller) {
  auto channel = std::make_unique<MethodChannel<EncodableValue>>(
      controller->engine()->messenger(), "com.workdiary/screenshot",
      &StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const MethodCall<EncodableValue>& call,
         std::unique_ptr<MethodResult<EncodableValue>> result) {
        // 静态变量：保存待返回的 result 和截图窗口（异步返回结果）
        static std::unique_ptr<MethodResult<EncodableValue>> pending_result;
        static std::unique_ptr<ScreenshotWindow> screenshot_window;

        if (call.method_name() == "startScreenshot") {
          // 如果已有截图窗口在运行，返回错误
          if (screenshot_window) {
            result->Error("ALREADY_RUNNING", "已有截图窗口在运行");
            return;
          }

          // 1. 截取全屏（虚拟屏幕原始分辨率）
          int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
          int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
          int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
          int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
          auto png_data = CaptureRegion(left, top, width, height);

          if (png_data.empty()) {
            result->Error("CAPTURE_FAILED", "截图失败");
            return;
          }

          // 2. 保存 pending_result，等截图窗口关闭后再返回
          pending_result = std::move(result);

          // 3. 创建独立的截图窗口（主窗口保持不变）
          screenshot_window = std::make_unique<ScreenshotWindow>(
              png_data,
              [](const std::string& cropped_base64) {
                // 截图窗口关闭后，返回结果给 Dart 端
                if (pending_result) {
                  if (cropped_base64.empty()) {
                    // 用户取消：返回空字符串
                    pending_result->Success(EncodableValue(std::string("")));
                  } else {
                    pending_result->Success(EncodableValue(cropped_base64));
                  }
                  pending_result.reset();
                }
                screenshot_window.reset();
              });
          if (!screenshot_window->Show()) {
            // 创建窗口失败：必须把结果回给 Dart，否则调用的 Future 永远不完成
            // （用户看到的现象是热键按了没反应，再按又被“已有窗口在运行”挡住）。
            screenshot_window.reset();
            if (pending_result) {
              pending_result->Error("WINDOW_FAILED", "无法创建截图窗口");
              pending_result.reset();
            }
          }
          return;
        }

        if (call.method_name() == "getVirtualScreen") {
          // 返回虚拟屏幕（所有显示器并集）的坐标和尺寸
          int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
          int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
          int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
          int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);

          EncodableMap map;
          map[EncodableValue("left")] = EncodableValue(left);
          map[EncodableValue("top")] = EncodableValue(top);
          map[EncodableValue("width")] = EncodableValue(width);
          map[EncodableValue("height")] = EncodableValue(height);
          result->Success(EncodableValue(std::move(map)));
        }
        else if (call.method_name() == "captureRegion") {
          // 按虚拟屏幕坐标截取区域
          if (call.arguments() == nullptr) {
            result->Error("INVALID_ARGS", "缺少参数");
            return;
          }
          // 用 get_if 而不是会抛 bad_variant_access 的 std::get：
          // 通道回调里抛出的 C++ 异常没有人接，会直接 terminate 进程。
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("INVALID_ARGS", "参数格式错误");
            return;
          }
          auto it_x = args->find(EncodableValue("x"));
          auto it_y = args->find(EncodableValue("y"));
          auto it_w = args->find(EncodableValue("width"));
          auto it_h = args->find(EncodableValue("height"));

          if (it_x == args->end() || it_y == args->end() ||
              it_w == args->end() || it_h == args->end()) {
            result->Error("INVALID_ARGS", "缺少参数 x/y/width/height");
            return;
          }

          // Dart 的 int 可能落成 int32 或 int64，两种都要认
          auto as_int = [](const EncodableValue& value, int fallback) -> int {
            if (const auto* v32 = std::get_if<int32_t>(&value)) return *v32;
            if (const auto* v64 = std::get_if<int64_t>(&value)) {
              return static_cast<int>(*v64);
            }
            return fallback;
          };

          int x = as_int(it_x->second, 0);
          int y = as_int(it_y->second, 0);
          int w = as_int(it_w->second, 0);
          int h = as_int(it_h->second, 0);

          if (w <= 0 || h <= 0) {
            result->Error("INVALID_SIZE", "宽高必须大于 0");
            return;
          }

          auto png_data = CaptureRegion(x, y, w, h);
          if (png_data.empty()) {
            result->Error("CAPTURE_FAILED", "截图失败");
            return;
          }

          std::string b64 = base64_encode(png_data.data(), png_data.size());
          result->Success(EncodableValue(std::move(b64)));
        }
        else if (call.method_name() == "captureFullScreen") {
          // 兼容旧方法：截取整个虚拟屏幕
          int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
          int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
          int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
          int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);

          auto png_data = CaptureRegion(left, top, width, height);
          if (png_data.empty()) {
            result->Error("CAPTURE_FAILED", "截图失败");
            return;
          }
          std::string b64 = base64_encode(png_data.data(), png_data.size());
          result->Success(EncodableValue(std::move(b64)));
        }
        else {
          result->NotImplemented();
        }
      });
}
