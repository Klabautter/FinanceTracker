import SwiftUI

struct RootView: View {
    let dependencies: AppDependencies

    var body: some View {
        #if os(macOS)
        MacRootView(dependencies: dependencies)
        #else
        IOSRootView(dependencies: dependencies)
        #endif
    }
}
