import Foundation
import Version
import XcodesKit

enum XcodeListCategory: String, CaseIterable, Identifiable, CustomStringConvertible {
    case all
    case release
    case beta
    case releasePlusNewBetas
    
    var id: Self { self }
    
    var description: String {
        switch self {
            case .all: return localizeString("All")
            case .release: return localizeString("Release")
            case .beta: return localizeString("Beta")
            case .releasePlusNewBetas:
                return "\(localizeString("Release")) + \(localizeString("Beta"))"
        }
    }

    var isManaged: Bool { PreferenceKey.xcodeListCategory.isManaged() }

    var versionFilter: XcodeListVersionFilter {
        switch self {
        case .all, .releasePlusNewBetas:
            return .all
        case .release:
            return .release
        case .beta:
            return .prerelease
        }
    }

    func applying<Element>(
        to elements: [Element],
        architectureFilters: [ArchitectureFilter],
        allowedMajorVersions: Int?,
        searchText: String,
        installedOnly: Bool,
        item: (Element) -> XcodeListItem
    ) -> [Element] {
        let categoryElements: [Element]

        if self == .releasePlusNewBetas {
            let architectureElements = elements.applying(
                XcodeListFilters(architectureFilters: architectureFilters),
                item: item
            )
            let releasedVersions = Set(
                architectureElements
                    .map(item)
                    .filter { $0.version.isNotPrerelease }
                    .map { ReleaseVersion($0.version) }
            )

            categoryElements = elements.filter { element in
                let version = item(element).version
                return version.isNotPrerelease || releasedVersions.contains(ReleaseVersion(version)) == false
            }
        } else {
            categoryElements = elements
        }

        return categoryElements.applying(
            XcodeListFilters(
                versionFilter: versionFilter,
                architectureFilters: architectureFilters,
                allowedMajorVersions: allowedMajorVersions,
                searchText: searchText,
                installedOnly: installedOnly
            ),
            item: item
        )
    }
}

private struct ReleaseVersion: Hashable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ version: Version) {
        major = version.major
        minor = version.minor
        patch = version.patch
    }
}

enum XcodeListArchitecture: String, CaseIterable, Identifiable, CustomStringConvertible {
    case universal
    case appleSilicon
    
    var id: Self { self }

    static var defaultForCurrentMachine: Self {
        switch ArchitectureVariant.defaultForMachine() {
        case .universal:
            return .universal
        case .appleSilicon:
            return .appleSilicon
        }
    }
    
    var description: String {
        switch self {
            case .universal: return localizeString("Universal")
            case .appleSilicon: return localizeString("Apple Silicon")
        }
    }

    var menuDescription: String {
        isCurrentMachineDefault ? "\(description) (\(localizeString("This Mac")))" : description
    }
    
    var isCurrentMachineDefault: Bool {
        self == Self.defaultForCurrentMachine
    }
    
    var isManaged: Bool { PreferenceKey.xcodeListArchitectures.isManaged() }

    var architectureFilters: [ArchitectureFilter] {
        switch self {
        case .universal:
            return [.variant(.universal)]
        case .appleSilicon:
            return [.variant(.appleSilicon)]
        }
    }
}
