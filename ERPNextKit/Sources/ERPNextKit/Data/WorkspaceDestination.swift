import Foundation

/// A workspace can contain cards, or (in v16) point directly to another
/// destination. Older servers omit `type` and always contain cards.
public enum WorkspaceDestination: Sendable, Hashable {
    case content
    case doctype(String)
    case report(String)
    case web(URL)

    public init(document: Document, baseURL: URL? = nil) throws {
        switch document["type"]?.nonEmptyString ?? "Workspace" {
        case "Workspace":
            self = .content
        case "Link":
            guard let target = document["link_to"]?.nonEmptyString else {
                throw ERPNextError(message: "This workspace has no link destination.")
            }
            switch document["link_type"]?.nonEmptyString {
            case "DocType":
                self = .doctype(target)
            case "Report":
                self = .report(target)
            case "Page":
                guard let baseURL else {
                    throw ERPNextError(message: "This workspace needs a server URL to open its page.")
                }
                self = .web(baseURL.appending(path: "app").appending(component: target))
            default:
                throw ERPNextError(message: "This workspace's link type is not supported.")
            }
        case "URL":
            // Relative links resolve against the site's directory, including
            // a path prefix when the server is hosted below the domain root.
            let base = baseURL?.appendingPathComponent("", isDirectory: true)
            guard let target = document["external_link"]?.nonEmptyString,
                let url = URL(string: target, relativeTo: base)?.absoluteURL,
                let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                let host = url.host(), !host.isEmpty
            else {
                throw ERPNextError(message: "This workspace has no valid web address.")
            }
            self = .web(url)
        default:
            throw ERPNextError(message: "This workspace type is not supported.")
        }
    }
}
