import Foundation

/// A deliberately small, strict semantic-version parser used at update trust boundaries.
/// Build metadata is ignored for precedence, as required by Semantic Versioning 2.0.0.
struct DDumpSemanticVersion: Comparable, Equatable, Sendable {
  private enum PrereleaseIdentifier: Equatable, Sendable {
    case numeric(Int)
    case text(String)
  }

  private let core: [Int]
  private let prerelease: [PrereleaseIdentifier]

  init?(_ rawValue: String) {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.first == "v" || value.first == "V" {
      value.removeFirst()
    }

    let withoutBuildMetadata = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let versionParts = withoutBuildMetadata.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard !versionParts[0].isEmpty else { return nil }

    let numericComponents = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard !numericComponents.isEmpty else { return nil }

    var parsedCore: [Int] = []
    parsedCore.reserveCapacity(numericComponents.count)
    for component in numericComponents {
      guard !component.isEmpty,
            component.allSatisfy(\.isNumber),
            let number = Int(component) else {
        return nil
      }
      parsedCore.append(number)
    }

    var parsedPrerelease: [PrereleaseIdentifier] = []
    if versionParts.count == 2 {
      guard !versionParts[1].isEmpty else { return nil }
      for component in versionParts[1].split(separator: ".", omittingEmptySubsequences: false) {
        guard !component.isEmpty,
              component.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
          return nil
        }
        if component.allSatisfy(\.isNumber), let number = Int(component) {
          parsedPrerelease.append(.numeric(number))
        } else {
          parsedPrerelease.append(.text(String(component)))
        }
      }
    }

    core = parsedCore
    prerelease = parsedPrerelease
  }

  static func < (lhs: DDumpSemanticVersion, rhs: DDumpSemanticVersion) -> Bool {
    let componentCount = max(lhs.core.count, rhs.core.count)
    for index in 0..<componentCount {
      let left = index < lhs.core.count ? lhs.core[index] : 0
      let right = index < rhs.core.count ? rhs.core[index] : 0
      if left != right { return left < right }
    }

    if lhs.prerelease.isEmpty { return false }
    if rhs.prerelease.isEmpty { return true }

    for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
      let left = lhs.prerelease[index]
      let right = rhs.prerelease[index]
      if left == right { continue }

      switch (left, right) {
      case let (.numeric(leftValue), .numeric(rightValue)):
        return leftValue < rightValue
      case (.numeric, .text):
        return true
      case (.text, .numeric):
        return false
      case let (.text(leftValue), .text(rightValue)):
        return leftValue < rightValue
      }
    }

    return lhs.prerelease.count < rhs.prerelease.count
  }

  /// Compares the remotely advertised version to the installed version.
  /// A positive result is the only state in which an update may be offered.
  static func compare(remote: String, installed: String) -> ComparisonResult? {
    guard let remoteVersion = DDumpSemanticVersion(remote),
          let installedVersion = DDumpSemanticVersion(installed) else {
      return nil
    }
    if remoteVersion > installedVersion { return .orderedDescending }
    if remoteVersion < installedVersion { return .orderedAscending }
    return .orderedSame
  }
}
