#include "rich_clipboard.h"

#include <flutter/standard_method_codec.h>

#include <cstring>
#include <limits>
#include <string>

#include "clipboard_html.h"

namespace {

// SetClipboardData takes ownership only on success.
class ClipboardBlock {
 public:
  ClipboardBlock(const void* bytes, size_t size) {
    handle_ = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!handle_) return;
    void* destination = GlobalLock(handle_);
    if (!destination) {
      GlobalFree(handle_);
      handle_ = nullptr;
      return;
    }
    std::memcpy(destination, bytes, size);
    GlobalUnlock(handle_);
  }
  ~ClipboardBlock() { if (handle_) GlobalFree(handle_); }
  bool valid() const { return handle_ != nullptr; }
  bool Publish(UINT format) {
    if (!SetClipboardData(format, handle_)) return false;
    handle_ = nullptr;
    return true;
  }
 private:
  HGLOBAL handle_ = nullptr;
};

bool WriteHtml(HWND owner, const std::string& text, const std::string& html) {
  if (text.size() > static_cast<size_t>(std::numeric_limits<int>::max())) return false;
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length == 0 && !text.empty()) return false;
  std::wstring wide(static_cast<size_t>(length), L'\0');
  if (length > 0 && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), wide.data(), length) != length) return false;
  std::wstring plain;
  for (size_t i = 0; i < wide.size(); ++i) {
    if (wide[i] == L'\n' && (i == 0 || wide[i - 1] != L'\r')) plain += L'\r';
    plain += wide[i];
  }
  const std::string formatted = MakeClipboardHtml(html);
  ClipboardBlock plain_block(plain.c_str(), (plain.size() + 1) * sizeof(wchar_t));
  ClipboardBlock html_block(formatted.c_str(), formatted.size() + 1);
  const UINT html_format = RegisterClipboardFormatW(L"HTML Format");
  if (!plain_block.valid() || !html_block.valid() || !html_format || !OpenClipboard(owner)) return false;
  const bool success = EmptyClipboard() && plain_block.Publish(CF_UNICODETEXT) &&
      html_block.Publish(html_format);
  // A partial write must not look like a successful rich copy.
  if (!success) EmptyClipboard();
  CloseClipboard();
  return success;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
InstallRichClipboard(flutter::BinaryMessenger* messenger, HWND owner) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "sh.speeddial/clipboard", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([owner](const auto& call, auto result) {
    if (call.method_name() != "writeHtml") {
      result->NotImplemented();
      return;
    }
    const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const std::string* text = nullptr;
    const std::string* html = nullptr;
    if (args) {
      auto text_it = args->find(flutter::EncodableValue("text"));
      auto html_it = args->find(flutter::EncodableValue("html"));
      if (text_it != args->end()) text = std::get_if<std::string>(&text_it->second);
      if (html_it != args->end()) html = std::get_if<std::string>(&html_it->second);
    }
    if (!text || !html) {
      result->Error("invalid_arguments", "Expected text and html strings");
    } else if (!WriteHtml(owner, *text, *html)) {
      result->Error("clipboard_write", "Could not write rich clipboard content");
    } else {
      result->Success();
    }
  });
  return channel;
}
