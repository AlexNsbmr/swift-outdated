import Foundation
import Files
import Rainbow
import ShellOut
import Version
import Logging

let log = Logger(label: "SwiftOutdated")

public struct SwiftPackage: Hashable {
    public let package: String
    public let repositoryURL: String
    public let revision: String?
    public let version: Version?
}

extension SwiftPackage: Encodable {}

extension SwiftPackage {
    public var hasResolvedVersion: Bool {
        self.version != nil
    }
    
    public func availableVersions() -> [Version] {
        do {
            log.trace("Running git ls-remote for \(self.package).")
            let lsRemote = try shellOut(
                to: "git",
                arguments: ["ls-remote", "--tags", self.repositoryURL]
            )
            return lsRemote
                .split(separator: "\n")
                .map {
                    $0.split(separator: "\t")
                        .last!
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(
                            of: #"refs\/tags\/(v(?=\d))?"#,
                            with: "",
                            options: .regularExpression
                        )
                }
                // Filter annotated tags, we just need a list of available tags, not the specific
                // commits they point to.
                .filter { !$0.contains("^{}") }
                .compactMap { Version($0) }
                .sorted()
        } catch {
            log.error("Error on git ls-remote for \(package): \(error)")
            return []
        }
    }
    
    public static func currentPackagePins(in folder: Folder) throws -> [Self] {
        let file: File = try {
            let possibleRootResolvedPaths = [
                "Package.resolved",
                ".package.resolved",
                "xcshareddata/swiftpm/Package.resolved",
                "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            ]
            if let resolvedPath = possibleRootResolvedPaths.lazy.compactMap({ try? folder.file(at: $0) }).first {
                log.info("Found package pins at \(resolvedPath.path(relativeTo: folder))")
                return resolvedPath
            }

            let xcodeWorkspaces = folder.subfolders.filter { $0.name.hasSuffix("xcworkspace") }
            if let xcodeWorkspace = xcodeWorkspaces.first {
                if xcodeWorkspaces.count > 1 {
                    print("Multiple workspaces found. Using \(xcodeWorkspace.path(relativeTo: folder))".yellow)
                }
                let resolvedPath = "xcshareddata/swiftpm/Package.resolved"
                guard xcodeWorkspace.containsFile(at: resolvedPath) else {
                    log.info("Found workspace package pins at \(resolvedPath)")
                    throw Error.notFound
                }
                return try xcodeWorkspace.file(at: resolvedPath)
            }

            let xcodeProjects = folder.subfolders.filter { $0.name.hasSuffix("xcodeproj") }
            if let xcodeProject = xcodeProjects.first {
                if xcodeProjects.count > 1 {
                    print("Multiple projects found. Using \(xcodeProject.path(relativeTo: folder))".yellow)
                }
                let resolvedPath = "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                guard xcodeProject.containsFile(at: resolvedPath) else {
                    log.info("Found project package pins at \(resolvedPath)")
                    throw Error.notFound
                }
                return try xcodeProject.file(at: resolvedPath)
            }

            throw Error.notFound
        }()
        
        guard let data = try? file.read() else {
            throw Error.notReadable
        }
        
        if let resolvedV1 = try? JSONDecoder().decode(ResolvedV1.self, from: data) {
            return resolvedV1.object.pins.map {
                SwiftPackage(
                    package: $0.package,
                    repositoryURL: $0.repositoryURL,
                    revision: $0.state.revision,
                    version: Version($0.state.version ?? "")
                )
            }
        } else if let resolvedV2 = try? JSONDecoder().decode(ResolvedV2.self, from: data) {
            return resolvedV2.pins.map {
                SwiftPackage(
                    package: $0.identity,
                    repositoryURL: $0.location,
                    revision: $0.state.revision,
                    version: Version($0.state.version ?? "")
                )
            }
        } else {
            return []
        }
    }
    
    public static func readDirectDependencies(in folder: Folder) throws -> [String]? {
        guard let packageSwiftFile = try? folder.file(at: "Package.swift") else {
            log.warning("Package.swift file not found")
            return nil
        }
        
        do {
            let packageContent = try packageSwiftFile.readAsString()
            
            // Extract dependencies section
            guard let dependenciesSection = extractDependenciesSection(from: packageContent) else {
                log.warning("Could not find dependencies section in Package.swift")
                return nil
            }
            
            // Extract package names from URLs
            let directDependencies = extractPackageNames(from: dependenciesSection)
            log.info("Found \(directDependencies.count) direct dependencies in Package.swift")
            return directDependencies
        } catch {
            log.error("Failed to read Package.swift: \(error)")
            return nil
        }
    }
    
    private static func extractDependenciesSection(from packageContent: String) -> String? {
        let pattern = #"dependencies:\s*\[([\s\S]*?)\],"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let nsString = packageContent as NSString
        let matches = regex.matches(in: packageContent, options: [], range: NSRange(location: 0, length: nsString.length))
        
        guard let match = matches.first,
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: packageContent) else {
            return nil
        }
        
        return String(packageContent[range])
    }
    
    private static func extractPackageNames(from dependenciesSection: String) -> [String] {
        // Match URLs like: .package(url: "https://github.com/apple/swift-log.git", from: "1.5.2"),
        let pattern = #"\.package\s*\(\s*url:\s*"([^"]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        let nsString = dependenciesSection as NSString
        let matches = regex.matches(in: dependenciesSection, options: [], range: NSRange(location: 0, length: nsString.length))
        
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let urlRange = Range(match.range(at: 1), in: dependenciesSection) else {
                return nil
            }
            
            let urlString = String(dependenciesSection[urlRange])
            
            // Extract the repository name from the URL
            let components = urlString.split(separator: "/")
            guard components.count >= 2 else { return nil }
            
            var repoName = String(components.last!)
            // Remove .git suffix if present
            if repoName.hasSuffix(".git") {
                repoName = String(repoName.dropLast(4))
            }
            
            return repoName
        }
    }
}

extension SwiftPackage {
    public static func collectVersions(for packages: [SwiftPackage], ignoringPrerelease: Bool, onlyMajorUpdates: Bool) async -> PackageCollection {
        log.info("Collecting versions for \(packages.map { $0.package }.joined(separator: ", ")).")
        let versions = await withTaskGroup(of: (SwiftPackage, [Version]?).self) { group in
            for package in packages where package.hasResolvedVersion {
                log.info("Package \(package.package) has resolved version, queueing version fetch.")
                group.addTask {
                    let availableVersions = package.availableVersions()
                    log.info("Found \(availableVersions.count) versions for \(package.package).")
                    return (package, availableVersions)
                }
            }

            var availableVersions = [SwiftPackage: [Version]]()
            for await (package, versions) in group {
                if let versions = versions {
                    availableVersions[package] = versions
                }
            }

            return availableVersions
        }

        let outdatedPackages = versions
            .compactMap { package, allVersions -> OutdatedPackage? in
                if let current = package.version, 
                   let latest = getLatestVersion(from: allVersions, currentVersion: current, ignoringPrerelease: ignoringPrerelease, onlyMajorUpdates: onlyMajorUpdates),
                   current != latest
                {
                    log.info("Package \(package.package) is outdated.")
                    return OutdatedPackage(package: package.package, currentVersion: current, latestVersion: latest, url: package.repositoryURL)
                } else {
                    log.info("Package \(package.package) is up to date.")
                }
                return nil
            }
            .sorted(by: { $0.package < $1.package })
        let ignoredPackages = packages.filter { !$0.hasResolvedVersion }
        if !ignoredPackages.isEmpty {
            log.info("Ignoring \(ignoredPackages.map { $0.package }.joined(separator: ", ")) because of non-version pins.")
        }
        return PackageCollection(outdatedPackages: outdatedPackages, ignoredPackages: ignoredPackages)
    }

    private static func getLatestVersion(from allVersions: [Version], currentVersion: Version, ignoringPrerelease: Bool, onlyMajorUpdates: Bool) -> Version? {
        var validVersions: [Version] = allVersions

        if ignoringPrerelease {
            validVersions = validVersions.filter { $0.prereleaseIdentifiers.isEmpty }
        }

        if onlyMajorUpdates {
            validVersions = validVersions.filter { ($0.major - currentVersion.major) > 0 }
        }

        return validVersions.last
    }
}

extension SwiftPackage {
    public enum Error: Swift.Error, LocalizedError {
        case notFound
        case notReadable
        
        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Package.resolved found in current working tree."
            case .notReadable:
                return "No Package.resolved read in current working tree."
            }
        }
    }
}
