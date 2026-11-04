#ifndef RUNNER_CLIPBOARD_HTML_H_
#define RUNNER_CLIPBOARD_HTML_H_

#include <iomanip>
#include <sstream>
#include <string>

// CF_HTML offsets count UTF-8 bytes from the start of the header, not Unicode
// characters. Keep this portable so non-ASCII fragments can be tested on Linux.
inline std::string MakeClipboardHtml(const std::string& fragment) {
  const std::string prefix =
      "<html><head><meta charset=\"utf-8\"></head><body><!--StartFragment-->";
  const std::string suffix = "<!--EndFragment--></body></html>";
  auto header = [](size_t start_html, size_t end_html, size_t start_fragment,
                   size_t end_fragment) {
    std::ostringstream out;
    out << "Version:1.0\r\n" << std::setfill('0')
        << "StartHTML:" << std::setw(10) << start_html << "\r\n"
        << "EndHTML:" << std::setw(10) << end_html << "\r\n"
        << "StartFragment:" << std::setw(10) << start_fragment << "\r\n"
        << "EndFragment:" << std::setw(10) << end_fragment << "\r\n";
    return out.str();
  };
  const size_t start_html = header(0, 0, 0, 0).size();
  const size_t start_fragment = start_html + prefix.size();
  const size_t end_fragment = start_fragment + fragment.size();
  return header(start_html, end_fragment + suffix.size(), start_fragment,
                end_fragment) + prefix + fragment + suffix;
}

#endif
