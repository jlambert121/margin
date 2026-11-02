import Cocoa

#if !TESTING
    @main struct MarginApplication {
        static func main() {
            // The first controller becomes AppKit's shared controller. Create our
            // subclass before NSApplication can instantiate the default one.
            let controller = DocumentController()
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = AppDelegate(controller: controller)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }
#endif
