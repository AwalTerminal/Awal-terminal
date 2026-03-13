import XCTest
@testable import AwalTerminalLib

final class ProjectDetectorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectDetectorTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Exact file detection

    func testDetectsRustByCargoToml() {
        touch("Cargo.toml")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("rust"))
    }

    func testDetectsNodeByPackageJson() {
        touch("package.json")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("node"))
    }

    func testDetectsPythonByRequirementsTxt() {
        touch("requirements.txt")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("python"))
    }

    func testDetectsGoByGoMod() {
        touch("go.mod")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("go"))
    }

    func testDetectsSwiftByPackageSwift() {
        touch("Package.swift")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("swift"))
    }

    func testDetectsFlutterByPubspec() {
        touch("pubspec.yaml")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("flutter"))
    }

    func testDetectsJavaByPomXml() {
        touch("pom.xml")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("java"))
    }

    func testDetectsRubyByGemfile() {
        touch("Gemfile")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("ruby"))
    }

    func testDetectsElixirByMixExs() {
        touch("mix.exs")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("elixir"))
    }

    func testDetectsZigByBuildZig() {
        touch("build.zig")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("zig"))
    }

    // MARK: - Glob pattern detection

    func testDetectsSwiftByXcodeproj() {
        touch("MyApp.xcodeproj")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("swift"))
    }

    func testDetectsCsharpByCsproj() {
        touch("MyApp.csproj")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("csharp"))
    }

    // MARK: - Multiple stacks

    func testDetectsMultipleStacks() {
        touch("Cargo.toml")
        touch("package.json")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("rust"))
        XCTAssertTrue(result.contains("node"))
    }

    // MARK: - Empty directory

    func testEmptyDirectoryDetectsNothing() {
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Override stacks

    func testOverrideStacksSkipDetection() {
        touch("Cargo.toml")
        let result = ProjectDetector.detect(
            path: tmpDir.path,
            overrideStacks: ["custom-stack"]
        )
        XCTAssertEqual(result, ["custom-stack"])
        XCTAssertFalse(result.contains("rust"))
    }

    // MARK: - Registry rules

    func testRegistryRulesExtendDetection() {
        touch("my-custom-marker.lock")
        let result = ProjectDetector.detect(
            path: tmpDir.path,
            registryRules: ["custom": ["my-custom-marker.lock"]]
        )
        XCTAssertTrue(result.contains("custom"))
    }

    // MARK: - Sub-stack detection

    func testDetectsNextjsSubStack() {
        touch("package.json", content: "{\"dependencies\": {\"next\": \"14.0.0\"}}")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("node"))
        XCTAssertTrue(result.contains("nextjs"))
    }

    func testDetectsExpressSubStack() {
        touch("package.json", content: "{\"dependencies\": {\"express\": \"4.0.0\"}}")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("node"))
        XCTAssertTrue(result.contains("express"))
    }

    func testDetectsDjangoSubStackFromRequirements() {
        touch("requirements.txt", content: "django==4.2\ncelery==5.3")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("python"))
        XCTAssertTrue(result.contains("django"))
    }

    func testDetectsNextjsByConfigFile() {
        touch("package.json")
        touch("next.config.js")
        let result = ProjectDetector.detect(path: tmpDir.path)
        XCTAssertTrue(result.contains("nextjs"))
    }

    // MARK: - Built-in rules coverage

    func testBuiltInRulesContainExpectedStacks() {
        let expectedStacks = ["go", "flutter", "swift", "python", "csharp", "rust",
                              "node", "java", "kotlin", "php", "ruby", "zig", "elixir", "cpp"]
        for stack in expectedStacks {
            XCTAssertNotNil(ProjectDetector.builtInRules[stack], "Missing built-in rule for \(stack)")
        }
    }

    // MARK: - Helpers

    private func touch(_ name: String, content: String = "") {
        let path = tmpDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: path.path, contents: content.data(using: .utf8))
    }
}
