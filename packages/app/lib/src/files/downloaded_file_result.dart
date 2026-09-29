enum DownloadedFileStatus { saved, cancelled, browserDownload, unsupported }

class DownloadedFileResult {
  const DownloadedFileResult(this.status, {this.path});

  final DownloadedFileStatus status;
  final String? path;
}
