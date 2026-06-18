// In-process NotificationCenter names used inside the headless server. TKT-060
// (Phase 6).
//
// After the process split these fire entirely WITHIN the server process: the
// stores post them on every write (including writes that arrive over the API on a
// NIO thread), and ServerLifecycle observes them to reconcile HTTPS and re-sync
// the install-page slug registry. NotificationCenter is in-process only, so none
// of these cross the menu-bar/server boundary -- the old menu-bar posting paths
// (.startServerRequested/.restartServerRequested/etc.) are gone; the menu bar
// drives everything through the REST API instead.
import Foundation

extension Notification.Name {
    /// Posted by the project store after any successful create/update/delete, by
    /// any writer (the API on a NIO thread, an internal call on main).
    /// ServerLifecycle observes this to re-sync the deploy server's slug registry.
    /// TKT-055 (Phase 2).
    static let projectsDidChange = Notification.Name("RemoteDeploy.projectsDidChange")

    /// Posted by the SettingsStore after any successful settings write, by any
    /// writer. ServerLifecycle observes this to bring HTTPS into line (cert/port
    /// changes) and reconfigure push notifiers. TKT-055 (Phase 2).
    static let settingsDidChange = Notification.Name("RemoteDeploy.settingsDidChange")
}
