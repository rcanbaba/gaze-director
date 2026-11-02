import CoreMediaIO
import Foundation

let providerSource = GazeCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
