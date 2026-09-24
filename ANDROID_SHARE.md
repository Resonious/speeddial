# Android sharing flows

## Share to Speeddial

Android sends one `ACTION_SEND` file (a `content://` URI) to `MainActivity`.
The activity reads at most 8 MiB while it has the temporary URI grant and
passes the file name, MIME type, and bytes to Flutter. A card floats at the
upper right of the app, including when no daemon or session is selected. Its
X discards the file. When a session is open, **Attach to session** moves the
file into that session's composer, where it can be removed or sent with text.
Opening another session before sending keeps it staged in the first composer.
Another Android share replaces the floating file, without changing files
already staged in composers. A read/size error is shown in the card.

## Share to a project

Each locally cached project on each configured daemon is published as a
dynamic Android Sharing Shortcut, labelled with its project and daemon.
Selecting it gives the activity an `ACTION_SEND` and shortcut ID. After the
file is read, Flutter validates the shortcut against the local project cache,
creates a session on that daemon, stages the file in its composer, and selects
the new session. It does not start an agent turn until the user sends. The
session uses the most recently used settings for that daemon/project (provider,
Ante provider model, base branch, sandbox, yolo, short prompt, and mode).
Settings and project labels are saved locally; shortcut publication at startup
uses that cache immediately, then daemon refreshes update it. With no previous
session, creation uses the preferred available provider and the normal new
session defaults. On creation failure, the file remains floating with an error
so it can still be attached manually or retried through sharing.

The Android Sharesheet may rank or limit the number of visible shortcuts;
Speeddial publishes the most recently active projects first, up to the
platform's dynamic shortcut limit. The generic
app share target remains available for every single file MIME type.
