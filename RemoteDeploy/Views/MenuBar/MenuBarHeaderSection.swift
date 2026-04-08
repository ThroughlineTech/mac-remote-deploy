// Header section of the menu bar popover: just the title. Server/Tailscale
// status rows live in ServerStatusSection now. TKT-012 decomposition, tightened
// in TKT-024 to hit the 5-subview / <100-line bar.
import SwiftUI

struct MenuBarHeaderSection: View {
    var body: some View {
        Text("Remote Deploy Server")
            .font(.headline)
            .padding(.bottom, 2)
    }
}
