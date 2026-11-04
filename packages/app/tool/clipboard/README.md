# Native clipboard checks

Run from the repository root. These tests use only local clipboard data.

Windows CF_HTML framing can be checked on any C++17 host. It verifies byte offsets
with Japanese, emoji, and accented text, including an empty fragment:

```sh
g++ -std=c++17 -Wall -Wextra -Werror packages/app/tool/clipboard/clipboard_html_test.cpp -o /tmp/cf_html_test
/tmp/cf_html_test
```

For Linux, first build the app to populate `linux/flutter/ephemeral`. Then check
both clipboard representations and replacement/ownership cleanup using GTK under
Xvfb (this does not render Flutter):

```sh
g++ -std=c++17 -Wall -Wextra -Wno-unused-parameter -Werror \
  packages/app/tool/clipboard/linux_clipboard_test.cpp \
  packages/app/linux/runner/rich_clipboard.cc \
  -Ipackages/app/linux/flutter/ephemeral -Lpackages/app/linux/flutter/ephemeral \
  -Wl,-rpath,"$PWD/packages/app/linux/flutter/ephemeral" \
  -lflutter_linux_gtk $(pkg-config --cflags --libs gtk+-3.0) \
  -o /tmp/linux_clipboard_test
xvfb-run -a /tmp/linux_clipboard_test
```

Dart/widget tests cover the formatted payload, one rich write per click, and
clipboard errors. A real Windows/iOS build and pasting into Slack's formatted
editor remain platform checks; a passing payload test does not prove Slack's
version or editor settings will consume HTML. Use normal paste, not paste as
plain text.
