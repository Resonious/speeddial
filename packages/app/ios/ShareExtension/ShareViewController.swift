import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let status = UILabel()
  private var targets: [[String: String]] = []
  private var provider: NSItemProvider?
  private var saving = false
  private var saved = false
  private let cancel = UIButton(type: .system)

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.font = .preferredFont(forTextStyle: .body)
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    status.text = "Choose a project for a new session, or attach later in SpeedDial. One file, up to 8 MiB."
    table.dataSource = self
    table.delegate = self
    cancel.setTitle("Cancel", for: .normal)
    cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [status, table, cancel])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    guard providers.count == 1 else {
      status.text = "Please share one file at a time."
      table.isHidden = true
      return
    }
    provider = providers[0]
    do { targets = try ShareInbox.shared().targets() }
    catch { status.text = error.localizedDescription; table.isHidden = true }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    targets.count + 1
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.text = indexPath.row == 0 ? "Attach later in SpeedDial" : targets[indexPath.row - 1]["label"]
    cell.textLabel?.numberOfLines = 0
    cell.textLabel?.font = .preferredFont(forTextStyle: .body)
    cell.textLabel?.adjustsFontForContentSizeCategory = true
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard !saving, !saved, let provider else { return }
    saving = true
    table.isUserInteractionEnabled = false
    cancel.isEnabled = false
    status.text = "Saving shared file…"
    let target = indexPath.row == 0 ? nil : targets[indexPath.row - 1]["id"]
    let suggestedName = provider.suggestedName
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
        let outcome = Self.persist(url: item as? URL, error: error,
          suggestedName: suggestedName, typeID: nil, target: target)
        Task { @MainActor in self?.finished(error: outcome) }
      }
      return
    }
    // File representations avoid decoding large images in this small process.
    guard let typeID = provider.registeredTypeIdentifiers.first(where: {
      UTType($0)?.conforms(to: .data) == true
    }) else {
      finished(error: ShareFailure("This item does not contain a supported file."))
      return
    }
    provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, error in
      // The temporary representation is valid only during this callback.
      let outcome = Self.persist(url: url, error: error,
        suggestedName: suggestedName, typeID: typeID, target: target)
      Task { @MainActor in self?.finished(error: outcome) }
    }
  }

  nonisolated private static func persist(
    url: URL?, error: Error?, suggestedName: String?, typeID: String?, target: String?
  ) -> Error? {
    do {
      if let error { throw error }
      guard let url else { throw ShareFailure("Could not read the shared file.") }
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      let data = try ShareInbox.readFile(url)
      let type = typeID.flatMap { UTType($0) } ?? UTType(filenameExtension: url.pathExtension)
      var name = suggestedName ?? url.lastPathComponent
      if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
        name += "." + ext
      }
      try ShareInbox.shared().save(data: data, name: name,
        mimeType: type?.preferredMIMEType ?? "application/octet-stream", target: target)
      return nil
    } catch { return error }
  }

  private func finished(error: Error?) {
    saving = false
    cancel.isEnabled = true
    if let error {
      status.text = error.localizedDescription
      table.isUserInteractionEnabled = true
    } else {
      saved = true
      status.text = "Saved. Open SpeedDial to finish attaching your file."
      table.isHidden = true
      cancel.setTitle("Done", for: .normal)
    }
  }

  @objc private func close() {
    if saved { extensionContext?.completeRequest(returningItems: nil) }
    else { extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
  }
}
