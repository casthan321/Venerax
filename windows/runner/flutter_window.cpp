#pragma comment(lib, "winhttp.lib")
#include "flutter_window.h"

#include <algorithm>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <Windows.h>
#include <winhttp.h>

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

#include "utils.h"

namespace {

std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> mouse_events;

void AppendProxyCapability(std::string* value, const char* capability) {
  if (!value->empty()) {
    value->push_back(';');
  }
  value->append(capability);
}

std::optional<std::string> GetProxy() {
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG config{};
  if (!WinHttpGetIEProxyConfigForCurrentUser(&config)) {
    return std::nullopt;
  }

  std::string proxy;
  if (config.lpszProxy != nullptr) {
    auto value = Utf8FromUtf16(config.lpszProxy);
    if (!value.empty()) {
      proxy = std::move(value);
    }
  }
  // Only capability markers cross the bridge. PAC URLs and bypass rules may
  // contain sensitive host names or policy and must never be exposed or logged.
  if (config.fAutoDetect != FALSE) {
    AppendProxyCapability(&proxy, "autodetect=1");
  }
  if (config.lpszAutoConfigUrl != nullptr &&
      config.lpszAutoConfigUrl[0] != L'\0') {
    AppendProxyCapability(&proxy, "autoconfig=1");
  }
  if (config.lpszProxyBypass != nullptr && config.lpszProxyBypass[0] != L'\0') {
    AppendProxyCapability(&proxy, "bypass=1");
  }

  GlobalFree(config.lpszAutoConfigUrl);
  GlobalFree(config.lpszProxy);
  GlobalFree(config.lpszProxyBypass);
  return proxy.empty() ? std::nullopt
                       : std::optional<std::string>(std::move(proxy));
}

void WriteImageToClipboard(
    const flutter::MethodCall<>& call,
    const std::unique_ptr<flutter::MethodResult<>>& result) {
  if (call.arguments() == nullptr ||
      !std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
    result->Error("invalid_arguments", "Expected image arguments.");
    return;
  }

  const auto& arguments = std::get<flutter::EncodableMap>(*call.arguments());
  const auto data_it = arguments.find(flutter::EncodableValue("data"));
  const auto width_it = arguments.find(flutter::EncodableValue("width"));
  const auto height_it = arguments.find(flutter::EncodableValue("height"));
  if (data_it == arguments.end() || width_it == arguments.end() ||
      height_it == arguments.end() ||
      !std::holds_alternative<std::vector<uint8_t>>(data_it->second) ||
      !std::holds_alternative<int32_t>(width_it->second) ||
      !std::holds_alternative<int32_t>(height_it->second)) {
    result->Error("invalid_arguments", "Invalid image data.");
    return;
  }

  auto data = std::get<std::vector<uint8_t>>(data_it->second);
  const int32_t width = std::get<int32_t>(width_it->second);
  const int32_t height = std::get<int32_t>(height_it->second);
  const uint64_t expected_size =
      width > 0 && height > 0
          ? static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4
          : 0;
  if (expected_size == 0 || expected_size != data.size()) {
    result->Error("invalid_arguments", "Invalid image dimensions.");
    return;
  }

  // Windows bitmaps use BGRA byte order.
  for (size_t i = 0; i < data.size(); i += 4) {
    std::swap(data[i], data[i + 2]);
  }

  HBITMAP bitmap = CreateBitmap(width, height, 1, 32, data.data());
  if (bitmap == nullptr) {
    result->Error("clipboard_error", "Could not create a bitmap.");
    return;
  }

  if (!OpenClipboard(nullptr)) {
    DeleteObject(bitmap);
    result->Error("clipboard_error", "Could not open the clipboard.");
    return;
  }

  EmptyClipboard();
  if (SetClipboardData(CF_BITMAP, bitmap) == nullptr) {
    CloseClipboard();
    DeleteObject(bitmap);
    result->Error("clipboard_error", "Could not write to the clipboard.");
    return;
  }

  // The system owns the bitmap after SetClipboardData succeeds.
  CloseClipboard();
  result->Success();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  const flutter::MethodChannel<> channel(
      flutter_controller_->engine()->messenger(), "venera/method_channel",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler(
      [](const flutter::MethodCall<>& call,
         const std::unique_ptr<flutter::MethodResult<>>& result) {
        if (call.method_name() == "getProxy") {
          const auto proxy = GetProxy();
          if (proxy.has_value()) {
            result->Success(proxy.value());
          } else {
            result->Success(flutter::EncodableValue("No Proxy"));
          }
          return;
        }
        result->NotImplemented();
      });

  flutter::EventChannel<> channel2(
      flutter_controller_->engine()->messenger(), "venera/mouse",
      &flutter::StandardMethodCodec::GetInstance());

  auto eventHandler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [](const flutter::EncodableValue* /* arguments */,
         std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
        mouse_events = std::move(events);
        return nullptr;
      },
      [](const flutter::EncodableValue* /* arguments */)
          -> std::unique_ptr<
              flutter::StreamHandlerError<flutter::EncodableValue>> {
        mouse_events = nullptr;
        return nullptr;
      });

  channel2.SetStreamHandler(std::move(eventHandler));

  const flutter::MethodChannel<> channel3(
    flutter_controller_->engine()->messenger(), "venera/clipboard",
    &flutter::StandardMethodCodec::GetInstance());
  channel3.SetMethodCallHandler(
      [](const flutter::MethodCall<>& call,
         const std::unique_ptr<flutter::MethodResult<>>& result) {
        if (call.method_name() == "writeImageToClipboard") {
          WriteImageToClipboard(call, result);
          return;
        }
        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
  mouse_events = nullptr;
}

void mouse_side_button_listener(unsigned int input) {
  if (mouse_events != nullptr) {
    mouse_events->Success(static_cast<int>(input));
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  UINT button = GET_XBUTTON_WPARAM(wparam);
  if (button == XBUTTON1 && message == WM_XBUTTONDOWN) {
    mouse_side_button_listener(0);
  } else if (button == XBUTTON2 && message == WM_XBUTTONDOWN) {
    mouse_side_button_listener(1);
  }
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
