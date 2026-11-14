import Foundation

/// One step of "Open session". Executed in order by the app; pure so it can be tested.
public enum NavigationStep: Equatable {
    /// Ask the host app to open (and so focus) the window that already has this folder open.
    case focusFolder(path: String, bundleId: String)
    /// Open the multi-root .code-workspace file that contains the session's folder (focuses its already-open window).
    case openWorkspace(path: String, bundleId: String)
    /// Bring an app forward without opening anything (terminal-hosted CLI sessions).
    case activateApp(bundleId: String)
    /// Open a URL (the Claude extension deep link for this exact session).
    case openURL(URL)
}

public enum SessionNavigator {
    /// Extension sessions: focus the workspace window first so the deep link lands in the window that owns the
    /// session, then open the deep link (focuses the tab if open, else resumes it in that folder).
    /// CLI sessions never get the extension deep link: it would open a second writer on a running CLI conversation.
    public static func plan(for s: Session, cursorBundleIds: [String], deepLinkTemplate: String,
                            isDirectory: (String) -> Bool, workspaceFor: (String) -> String? = { _ in nil }) -> [NavigationStep] {
        let cursor = cursorBundleIds.first ?? "com.todesktop.230313mzl4w4u92"
        let hostIsCursor = s.host.map { cursorBundleIds.contains($0) } ?? false
        // Only the session's own workspace folder: a later tool cwd (subfolder, /tmp) would open a new window and resume there.
        let root = s.workspaceRoot.flatMap { !$0.isEmpty && isDirectory($0) ? $0 : nil }
        // Strict unreserved-set encoding: a hostile session_id must not add `&prompt=` or other parameters.
        let link = CapabilityMatrix(channels: [:], deepLinkTemplate: deepLinkTemplate).deepLink(sessionId: s.id)
        switch RowFormat.source(s) {
        case .cliTerminal, .unknown:   // unknown entrypoint: focus only, never resume it in the extension (D4)
            if hostIsCursor { return root.map { [.focusFolder(path: $0, bundleId: cursor)] } ?? [.activateApp(bundleId: cursor)] }
            return s.host.map { [.activateApp(bundleId: $0)] } ?? []
        case .headless:
            return []
        case .ideExtension:
            // Deep link only when the session is known to run in Cursor AND its own folder window can be focused first;
            // otherwise the link could resume the conversation in the wrong window (a second writer). Review M1.
            guard hostIsCursor, let root else {
                if let root, let host = s.host { return [.focusFolder(path: root, bundleId: host)] }
                return s.host.map { [.activateApp(bundleId: $0)] } ?? [.activateApp(bundleId: cursor)]
            }
            // A bare folder of a multi-root workspace would open a separate window, so open the workspace file instead.
            let focus = workspaceFor(root).map { NavigationStep.openWorkspace(path: $0, bundleId: cursor) } ?? .focusFolder(path: root, bundleId: cursor)
            return [focus, .openURL(link)]
        }
    }
}
