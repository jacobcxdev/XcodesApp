import Path
import Foundation
import XcodesKit

extension Path {
    static var defaultXcodesApplicationSupport: Path {
        Path.applicationSupport/"dev.jacobcx.Xcodes"
    }

    static var xcodesApplicationSupport: Path {
        Current.defaults.string(forKey: "localPath").flatMap(Path.init) ?? defaultXcodesApplicationSupport
    }
    
    static var cacheFile: Path {
        XcodesPathResolver.availableXcodesCacheFile(in: xcodesApplicationSupport)
    }
    
    static var defaultInstallDirectory: Path {
        XcodesPathResolver.appDefaultInstallDirectory
    }
    
    static var installDirectory: Path {
        XcodesPathResolver.appInstallDirectory(savedPath: Current.defaults.string(forKey: "installPath"))
    }
    
    static var runtimeCacheFile: Path {
        XcodesPathResolver.downloadableRuntimesCacheFile(in: xcodesApplicationSupport)
    }
    
    static var xcodesCaches: Path {
        Path.caches/"dev.jacobcx.Xcodes"
    }
}
