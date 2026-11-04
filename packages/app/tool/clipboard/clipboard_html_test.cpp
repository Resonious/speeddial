// Run on any C++17 host: g++ -std=c++17 clipboard_html_test.cpp -o /tmp/cf_html_test && /tmp/cf_html_test
#include "../../windows/runner/clipboard_html.h"

#include <cassert>
#include <string>

int main() {
  for (const std::string& fragment : {std::string(), std::string(u8"<pre>日本語 🥖 &amp; café\n  second line</pre>")}) {
    const std::string payload = MakeClipboardHtml(fragment);
    auto offset = [&](const std::string& key) {
      return std::stoull(payload.substr(payload.find(key + ':') + key.size() + 1, 10));
    };
    const size_t html_start = offset("StartHTML");
    const size_t html_end = offset("EndHTML");
    const size_t fragment_start = offset("StartFragment");
    const size_t fragment_end = offset("EndFragment");
    assert(payload.substr(html_start, 6) == "<html>");
    assert(html_end == payload.size());
    assert(payload.substr(fragment_start, fragment_end - fragment_start) == fragment);
    assert(payload.substr(fragment_start - 20, 20) == "<!--StartFragment-->");
    assert(payload.substr(fragment_end, 18) == "<!--EndFragment-->");
    assert(payload.find("Version:1.0\r\n") == 0);
  }
}
