import Foundation

@main
enum DDumpSemanticVersionTests {
  private static var failures = 0

  private static func expect(
    _ remote: String,
    comparedTo installed: String,
    equals expected: ComparisonResult?,
    _ description: String
  ) {
    let actual = DDumpSemanticVersion.compare(remote: remote, installed: installed)
    if actual != expected {
      failures += 1
      fputs("FAIL: \(description) (actual: \(String(describing: actual)))\n", stderr)
    }
  }

  static func main() {
    expect("v0.3.14", comparedTo: "0.3.18", equals: .orderedAscending, "public 0.3.14 must not downgrade private 0.3.18")
    expect("v0.3.19", comparedTo: "0.3.18", equals: .orderedDescending, "newer patch is an update")
    expect("0.3.18", comparedTo: "v0.3.18", equals: .orderedSame, "leading v does not change precedence")
    expect("0.3.18+build.7", comparedTo: "0.3.18+build.2", equals: .orderedSame, "build metadata does not change precedence")
    expect("0.3.18-beta.2", comparedTo: "0.3.18-beta.1", equals: .orderedDescending, "prerelease identifiers are ordered")
    expect("0.3.18", comparedTo: "0.3.18-beta.9", equals: .orderedDescending, "stable is newer than prerelease")
    expect("0.3.18-beta", comparedTo: "0.3.18", equals: .orderedAscending, "prerelease cannot downgrade stable")
    expect("not-a-version", comparedTo: "0.3.18", equals: nil, "malformed remote version fails closed")
    expect("0.3.19", comparedTo: "also-invalid", equals: nil, "malformed installed version fails closed")

    guard failures == 0 else {
      fputs("\(failures) semantic version test(s) failed.\n", stderr)
      exit(1)
    }
    print("PASS: semantic version ordering and downgrade rejection")
  }
}
