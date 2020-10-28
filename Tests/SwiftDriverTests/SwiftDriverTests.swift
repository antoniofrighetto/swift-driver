//===--------------- SwiftDriverTests.swift - Swift Driver Tests -======---===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Foundation
@_spi(Testing) import SwiftDriver
import SwiftDriverExecution
import SwiftOptions
import TSCBasic
import XCTest

final class SwiftDriverTests: XCTestCase {

  /// Determine if the test's execution environment has LLDB
  /// Used to skip tests that rely on LLDB in such environments.
  private func testEnvHasLLDB() throws -> Bool {
    let executor = try SwiftDriverExecutor(diagnosticsEngine: DiagnosticsEngine(),
                                           processSet: ProcessSet(),
                                           fileSystem: localFileSystem,
                                           env: ProcessEnv.vars)
    let toolchain: Toolchain
    #if os(macOS)
    toolchain = DarwinToolchain(env: ProcessEnv.vars, executor: executor)
    #else
    toolchain = GenericUnixToolchain(env: ProcessEnv.vars, executor: executor)
    #endif
    do {
      _ = try toolchain.getToolPath(.lldb)
    } catch ToolchainError.unableToFind {
      return false
    }
    return true
  }

  func testInvocationRunModes() throws {

    let driver1 = try Driver.invocationRunMode(forArgs: ["swift"])
    XCTAssertEqual(driver1.mode, .normal(isRepl: false))
    XCTAssertEqual(driver1.args, ["swift"])

    let driver2 = try Driver.invocationRunMode(forArgs: ["swift", "-buzz"])
    XCTAssertEqual(driver2.mode, .normal(isRepl: false))
    XCTAssertEqual(driver2.args, ["swift", "-buzz"])

    let driver3 = try Driver.invocationRunMode(forArgs: ["swift", "/"])
    XCTAssertEqual(driver3.mode, .normal(isRepl: false))
    XCTAssertEqual(driver3.args, ["swift", "/"])

    let driver4 = try Driver.invocationRunMode(forArgs: ["swift", "./foo"])
    XCTAssertEqual(driver4.mode, .normal(isRepl: false))
    XCTAssertEqual(driver4.args, ["swift", "./foo"])

    let driver5 = try Driver.invocationRunMode(forArgs: ["swift", "repl"])
    XCTAssertEqual(driver5.mode, .normal(isRepl: true))
    XCTAssertEqual(driver5.args, ["swift"])

    let driver6 = try Driver.invocationRunMode(forArgs: ["swift", "foo", "bar"])
    XCTAssertEqual(driver6.mode, .subcommand("swift-foo"))
    XCTAssertEqual(driver6.args, ["swift-foo", "bar"])

    let driver7 = try Driver.invocationRunMode(forArgs: ["swift", "-frontend", "foo", "bar"])
    XCTAssertEqual(driver7.mode, .subcommand("swift-frontend"))
    XCTAssertEqual(driver7.args, ["swift-frontend", "foo", "bar"])

    let driver8 = try Driver.invocationRunMode(forArgs: ["swift", "-modulewrap", "foo", "bar"])
    XCTAssertEqual(driver8.mode, .subcommand("swift-frontend"))
    XCTAssertEqual(driver8.args, ["swift-frontend", "-modulewrap", "foo", "bar"])
  }

  func testSubcommandsHandling() throws {

    XCTAssertNoThrow(try Driver(args: ["swift"]))
    XCTAssertNoThrow(try Driver(args: ["swift", "-I=foo"]))
    XCTAssertNoThrow(try Driver(args: ["swift", ".foo"]))
    XCTAssertNoThrow(try Driver(args: ["swift", "/foo"]))

    XCTAssertThrowsError(try Driver(args: ["swift", "foo"]))
  }

  func testDriverKindParsing() throws {
    func assertArgs(
      _ args: String...,
      parseTo driverKind: DriverKind,
      leaving remainingArgs: [String],
      file: StaticString = #file, line: UInt = #line
    ) throws {
      var args = args
      let result = try Driver.determineDriverKind(args: &args)

      XCTAssertEqual(result, driverKind, file: file, line: line)
      XCTAssertEqual(args, remainingArgs, file: file, line: line)
    }
    func assertArgsThrow(
      _ args: String...,
      file: StaticString = #file, line: UInt = #line
    ) throws {
      var args = args
      XCTAssertThrowsError(try Driver.determineDriverKind(args: &args))
    }

    try assertArgs("swift", parseTo: .interactive, leaving: [])
    try assertArgs("/path/to/swift", parseTo: .interactive, leaving: [])
    try assertArgs("swiftc", parseTo: .batch, leaving: [])
    try assertArgs(".build/debug/swiftc", parseTo: .batch, leaving: [])
    try assertArgs("swiftc", "--driver-mode=swift", parseTo: .interactive, leaving: [])
    try assertArgs("swift", "-zelda", parseTo: .interactive, leaving: ["-zelda"])
    try assertArgs("swiftc", "--driver-mode=swift", "swiftc",
                   parseTo: .interactive, leaving: ["swiftc"])
    try assertArgsThrow("driver")
    try assertArgsThrow("swiftc", "--driver-mode=blah")
    try assertArgsThrow("swiftc", "--driver-mode=")
  }

  func testCompilerMode() throws {
    do {
      let driver1 = try Driver(args: ["swift", "main.swift"])
      XCTAssertEqual(driver1.compilerMode, .immediate)

      let driver2 = try Driver(args: ["swift"])
      XCTAssertEqual(driver2.compilerMode, .repl)
    }

    do {
      let driver1 = try Driver(args: ["swiftc", "main.swift", "-whole-module-optimization"])
      XCTAssertEqual(driver1.compilerMode, .singleCompile)

      let driver2 = try Driver(args: ["swiftc", "main.swift", "-whole-module-optimization", "-no-whole-module-optimization"])
      XCTAssertEqual(driver2.compilerMode, .standardCompile)

      let driver3 = try Driver(args: ["swiftc", "main.swift", "-g"])
      XCTAssertEqual(driver3.compilerMode, .standardCompile)
    }
  }

  func testJoinedPathOptions() throws {
    var driver = try Driver(args: ["swiftc", "-c", "-I=/some/dir", "-F=other/relative/dir", "foo.swift"])
    let jobs = try driver.planBuild()
    XCTAssertTrue(jobs[0].commandLine.contains(.joinedOptionAndPath("-I=", .absolute(.init("/some/dir")))))
    XCTAssertTrue(jobs[0].commandLine.contains(.joinedOptionAndPath("-F=", .relative(.init("other/relative/dir")))))
  }

  func testRelativeOptionOrdering() throws {
    var driver = try Driver(args: ["swiftc", "foo.swift",
                                   "-F", "/path/to/frameworks",
                                   "-Fsystem", "/path/to/systemframeworks",
                                   "-F", "/path/to/more/frameworks"])
    let jobs = try driver.planBuild()
    XCTAssertEqual(jobs[0].kind, .compile)
    // The relative ordering of -F and -Fsystem options should be preserved.
    XCTAssertTrue(jobs[0].commandLine.contains(subsequence: [.flag("-F"), .path(.absolute(.init("/path/to/frameworks"))),
                                                             .flag("-Fsystem"), .path(.absolute(.init("/path/to/systemframeworks"))),
                                                             .flag("-F"), .path(.absolute(.init("/path/to/more/frameworks")))]))
  }

  func testBatchModeDiagnostics() throws {
      try assertNoDriverDiagnostics(args: "swiftc", "-enable-batch-mode") { driver in
        switch driver.compilerMode {
        case .batchCompile:
          break
        default:
          XCTFail("Expected batch compile, got \(driver.compilerMode)")
        }
      }

      try assertDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-whole-module-optimization") { driver, diagnostics in
        XCTAssertEqual(driver.compilerMode, .singleCompile)
        diagnostics.expect(.warning("ignoring '-enable-batch-mode' because '-whole-module-optimization' was also specified"))
      }

      try assertDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-whole-module-optimization", "-no-whole-module-optimization", "-index-file", "-module-name", "foo") { driver, diagnostics in
        XCTAssertEqual(driver.compilerMode, .singleCompile)
        diagnostics.expect(.warning("ignoring '-enable-batch-mode' because '-index-file' was also specified"))
      }

      try assertNoDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-whole-module-optimization", "-no-whole-module-optimization") { driver in
        switch driver.compilerMode {
        case .batchCompile:
          break
        default:
          XCTFail("Expected batch compile, got \(driver.compilerMode)")
        }
      }
  }

  // This test is dependent on the swift-help executable being available, which
  // isn't always the case right now.
  #if false
  func testHelp() throws {
    do {
      var driver = try Driver(args: ["swift", "--help"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let helpJob = plannedJobs.first!
      XCTAssertTrue(helpJob.kind == .help)
      XCTAssertTrue(helpJob.requiresInPlaceExecution)
      XCTAssertTrue(helpJob.tool.name.hasSuffix("swift-help"))
      let expected: [Job.ArgTemplate] = [.flag("-tool=swift")]
      XCTAssertEqual(helpJob.commandLine, expected)
    }

    do {
      var driver = try Driver(args: ["swiftc", "-help-hidden"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let helpJob = plannedJobs.first!
      XCTAssertTrue(helpJob.kind == .help)
      XCTAssertTrue(helpJob.requiresInPlaceExecution)
      XCTAssertTrue(helpJob.tool.name.hasSuffix("swift-help"))
      let expected: [Job.ArgTemplate] = [.flag("-tool=swiftc"), .flag("-show-hidden")]
      XCTAssertEqual(helpJob.commandLine, expected)
    }
  }
  #endif

  func testInputFiles() throws {
    let driver1 = try Driver(args: ["swiftc", "a.swift", "/tmp/b.swift"])
    XCTAssertEqual(driver1.inputFiles,
                   [ TypedVirtualPath(file: .relative(RelativePath("a.swift")), type: .swift),
                     TypedVirtualPath(file: .absolute(AbsolutePath("/tmp/b.swift")), type: .swift) ])
    let driver2 = try Driver(args: ["swiftc", "a.swift", "-working-directory", "/wobble", "/tmp/b.swift"])
    XCTAssertEqual(driver2.inputFiles,
                   [ TypedVirtualPath(file: .absolute(AbsolutePath("/wobble/a.swift")), type: .swift),
                     TypedVirtualPath(file: .absolute(AbsolutePath("/tmp/b.swift")), type: .swift) ])

    let driver3 = try Driver(args: ["swift", "-"])
    XCTAssertEqual(driver3.inputFiles, [ TypedVirtualPath(file: .standardInput, type: .swift )])

    let driver4 = try Driver(args: ["swift", "-", "-working-directory" , "-wobble"])
    XCTAssertEqual(driver4.inputFiles, [ TypedVirtualPath(file: .standardInput, type: .swift )])
  }

  func testRecordedInputModificationDates() throws {
    try withTemporaryDirectory { path in
      guard let cwd = localFileSystem
        .currentWorkingDirectory else { fatalError() }
      let main = path.appending(component: "main.swift")
      let util = path.appending(component: "util.swift")
      let utilRelative = util.relative(to: cwd)
      try localFileSystem.writeFileContents(main) { $0 <<< "print(hi)" }
      try localFileSystem.writeFileContents(util) { $0 <<< "let hi = \"hi\"" }

      let mainMDate = try localFileSystem.getFileInfo(main).modTime
      let utilMDate = try localFileSystem.getFileInfo(util).modTime
      let driver = try Driver(args: [
        "swiftc", main.pathString, utilRelative.pathString,
      ])
      XCTAssertEqual(driver.recordedInputModificationDates, [
        .init(file: .absolute(main), type: .swift) : mainMDate,
        .init(file: .relative(utilRelative), type: .swift) : utilMDate,
      ])
    }
  }

  func testPrimaryOutputKinds() throws {
    let driver1 = try Driver(args: ["swiftc", "foo.swift", "-emit-module"])
    XCTAssertEqual(driver1.compilerOutputType, .swiftModule)
    XCTAssertEqual(driver1.linkerOutputType, nil)

    let driver2 = try Driver(args: ["swiftc", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver2.compilerOutputType, .object)
    XCTAssertEqual(driver2.linkerOutputType, .dynamicLibrary)

    let driver3 = try Driver(args: ["swiftc", "-static", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver3.compilerOutputType, .object)
    XCTAssertEqual(driver3.linkerOutputType, .staticLibrary)

    let driver4 = try Driver(args: ["swiftc", "-lto=llvm-thin", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver4.compilerOutputType, .llvmBitcode)
    let driver5 = try Driver(args: ["swiftc", "-lto=llvm-full", "foo.swift", "-emit-library"])
    XCTAssertEqual(driver5.compilerOutputType, .llvmBitcode)
  }

  func testPrimaryOutputKindsDiagnostics() throws {
      try assertDriverDiagnostics(args: "swift", "-i") {
        $1.expect(.error("the flag '-i' is no longer required and has been removed; use 'swift input-filename'"))
      }
  }

  func testBaseOutputPaths() throws {
    // Test the combination of -c and -o includes the base output path.
    do {
      var driver = try Driver(args: ["swiftc", "-c", "foo.swift", "-o", "/some/output/path/bar.o"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/some/output/path/bar.o"))))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-sil", "foo.swift", "-o", "/some/output/path/bar.sil"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/some/output/path/bar.sil"))))
    }

    do {
      // If no output is specified, verify we print to stdout for textual formats.
      var driver = try Driver(args: ["swiftc", "-emit-assembly", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(.standardOutput)))
    }
  }

    func testMultithreading() throws {
      XCTAssertNil(try Driver(args: ["swiftc"]).numParallelJobs)

      XCTAssertEqual(try Driver(args: ["swiftc", "-j", "4"]).numParallelJobs, 4)

      XCTAssertNil(try Driver(args: ["swiftc", "-j", "0"]).numParallelJobs)

      var env = ProcessEnv.vars
      env["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
      XCTAssertEqual(try Driver(args: ["swiftc", "-j", "4"], env: env).numParallelJobs, 1)
    }

    func testMultithreadingDiagnostics() throws {
      try assertDriverDiagnostics(args: "swiftc", "-j", "0") {
        $1.expect(.error("invalid value '0' in '-j'"))
      }

      var env = ProcessEnv.vars
      env["SWIFTC_MAXIMUM_DETERMINISM"] = "1"
      try assertDriverDiagnostics(args: "swiftc", "-j", "8", env: env) {
        $1.expect(.remark("SWIFTC_MAXIMUM_DETERMINISM overriding -j"))
      }
    }

  func testDebugSettings() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module") { driver in
      XCTAssertNil(driver.debugInfo.level)
      XCTAssertEqual(driver.debugInfo.format, .dwarf)
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-g") { driver in
      XCTAssertEqual(driver.debugInfo.level, .astTypes)
      XCTAssertEqual(driver.debugInfo.format, .dwarf)
    }

    try assertNoDriverDiagnostics(args: "swiftc", "-g", "foo.swift", "-gline-tables-only") { driver in
      XCTAssertEqual(driver.debugInfo.level, .lineTables)
      XCTAssertEqual(driver.debugInfo.format, .dwarf)
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-debug-prefix-map", "foo=bar=baz", "-debug-prefix-map", "qux=") { driver in
        let jobs = try driver.planBuild()
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("-debug-prefix-map")))
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("foo=bar=baz")))
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("-debug-prefix-map")))
        XCTAssertTrue(jobs[0].commandLine.contains(.flag("qux=")))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-debug-prefix-map", "foo", "-debug-prefix-map", "bar") {
        $1.expect(.error("values for '-debug-prefix-map' must be in the format 'original=remapped', but 'foo' was provided"))
        $1.expect(.error("values for '-debug-prefix-map' must be in the format 'original=remapped', but 'bar' was provided"))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-g", "-debug-info-format=codeview") { driver in
      XCTAssertEqual(driver.debugInfo.level, .astTypes)
      XCTAssertEqual(driver.debugInfo.format, .codeView)
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-debug-info-format=dwarf") {
      $1.expect(.error("option '-debug-info-format=' is missing a required argument (-g)"))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-g", "-debug-info-format=notdwarf") {
      $1.expect(.error("invalid value 'notdwarf' in '-debug-info-format='"))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-emit-module", "-gdwarf-types", "-debug-info-format=codeview") {
      $1.expect(.error("argument 'codeview' is not allowed with '-gdwarf-types'"))
    }
  }

  func testCoverageSettings() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-coverage-prefix-map", "foo=bar=baz", "-coverage-prefix-map", "qux=") { driver in
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-coverage-prefix-map")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("foo=bar=baz")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("-coverage-prefix-map")))
      XCTAssertTrue(jobs[0].commandLine.contains(.flag("qux=")))
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "-coverage-prefix-map", "foo", "-coverage-prefix-map", "bar") {
      $1.expect(.error("values for '-coverage-prefix-map' must be in the format 'original=remapped', but 'foo' was provided"))
      $1.expect(.error("values for '-coverage-prefix-map' must be in the format 'original=remapped', but 'bar' was provided"))
    }
  }

  func testModuleSettings() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift") { driver in
      XCTAssertNil(driver.moduleOutputInfo.output)
      XCTAssertEqual(driver.moduleOutputInfo.name, "foo")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-g") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .auxiliary(VirtualPath.temporary(RelativePath("foo.swiftmodule"))))
      XCTAssertEqual(driver.moduleOutputInfo.name, "foo")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-module-name", "wibble", "bar.swift", "-g") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .auxiliary( VirtualPath.temporary(RelativePath("wibble.swiftmodule"))))
      XCTAssertEqual(driver.moduleOutputInfo.name, "wibble")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "-emit-module", "foo.swift", "-module-name", "wibble", "bar.swift") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath(path: "wibble.swiftmodule")))
      XCTAssertEqual(driver.moduleOutputInfo.name, "wibble")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift") { driver in
      XCTAssertNil(driver.moduleOutputInfo.output)
      XCTAssertEqual(driver.moduleOutputInfo.name, "main")
    }

    try assertNoDriverDiagnostics(args: "swift", "-repl") { driver in
      XCTAssertNil(driver.moduleOutputInfo.output)
      XCTAssertEqual(driver.moduleOutputInfo.name, "REPL")
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-library", "-o", "libWibble.so") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.name, "Wibble")
    }

    try assertDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-library", "-o", "libWibble.so", "-module-name", "Swift") {
        $1.expect(.error("module name \"Swift\" is reserved for the standard library"))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-module", "-emit-library", "-o", "some/dir/libFoo.so", "-module-name", "MyModule") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath(path: "some/dir/MyModule.swiftmodule")))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-module", "-emit-library", "-o", "/", "-module-name", "MyModule") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath(path: "/MyModule.swiftmodule")))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "bar.swift", "-emit-module", "-emit-library", "-o", "../../some/other/dir/libFoo.so", "-module-name", "MyModule") { driver in
      XCTAssertEqual(driver.moduleOutputInfo.output, .topLevel(try VirtualPath(path: "../../some/other/dir/MyModule.swiftmodule")))
    }
  }

  func testModuleNameFallbacks() throws {
    try assertNoDriverDiagnostics(args: "swiftc", "file.foo.swift")
    try assertNoDriverDiagnostics(args: "swiftc", ".foo.swift")
    try assertNoDriverDiagnostics(args: "swiftc", "foo-bar.swift")
  }

  func testStandardCompileJobs() throws {
    var driver1 = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test"])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 3)
    XCTAssertEqual(plannedJobs[0].outputs.count, 1)
    XCTAssertEqual(plannedJobs[0].outputs.first!.file, VirtualPath.temporary(RelativePath("foo.o")))
    XCTAssertEqual(plannedJobs[1].outputs.count, 1)
    XCTAssertEqual(plannedJobs[1].outputs.first!.file, VirtualPath.temporary(RelativePath("bar.o")))
    XCTAssertTrue(plannedJobs[2].tool.name.contains(driver1.targetTriple.isDarwin ? "ld" : "clang"))
    XCTAssertEqual(plannedJobs[2].outputs.count, 1)
    XCTAssertEqual(plannedJobs[2].outputs.first!.file, VirtualPath.relative(RelativePath("Test")))

    // Forwarding of arguments.
    var driver2 = try Driver(args: ["swiftc", "-color-diagnostics", "foo.swift", "bar.swift", "-working-directory", "/tmp", "-api-diff-data-file", "diff.txt", "-Xfrontend", "-HI", "-no-color-diagnostics", "-g"])
    let plannedJobs2 = try driver2.planBuild()
    XCTAssert(plannedJobs2[0].commandLine.contains(Job.ArgTemplate.path(.absolute(try AbsolutePath(validating: "/tmp/diff.txt")))))
    XCTAssert(plannedJobs2[0].commandLine.contains(.flag("-HI")))
    XCTAssert(!plannedJobs2[0].commandLine.contains(.flag("-Xfrontend")))
    XCTAssert(plannedJobs2[0].commandLine.contains(.flag("-no-color-diagnostics")))
    XCTAssert(!plannedJobs2[0].commandLine.contains(.flag("-color-diagnostics")))
    XCTAssert(plannedJobs2[0].commandLine.contains(.flag("-target")))
    XCTAssert(plannedJobs2[0].commandLine.contains(.flag(driver2.targetTriple.triple)))
    XCTAssert(plannedJobs2[0].commandLine.contains(.flag("-enable-anonymous-context-mangled-names")))

    var driver3 = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-emit-library", "-module-name", "Test"])
    let plannedJobs3 = try driver3.planBuild()
    XCTAssertTrue(plannedJobs3[0].commandLine.contains(.flag("-module-name")))
    XCTAssertTrue(plannedJobs3[0].commandLine.contains(.flag("Test")))
    XCTAssertTrue(plannedJobs3[0].commandLine.contains(.flag("-parse-as-library")))
  }

  func testModuleNaming() throws {
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift"]).moduleOutputInfo.name, "foo")
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "a.out"]).moduleOutputInfo.name, "a")

    // This is silly, but necesary for compatibility with the integrated driver.
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "a.out.optimized"]).moduleOutputInfo.name, "main")

    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "a.out.optimized", "-module-name", "bar"]).moduleOutputInfo.name, "bar")
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-o", "+++.out"]).moduleOutputInfo.name, "main")
    XCTAssertEqual(try Driver(args: ["swift"]).moduleOutputInfo.name, "REPL")
    XCTAssertEqual(try Driver(args: ["swiftc", "foo.swift", "-emit-library", "-o", "libBaz.dylib"]).moduleOutputInfo.name, "Baz")
  }

  func testOutputFileMapLoading() throws {
    let contents = """
    {
      "": {
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps"
      },
      "/tmp/foo/Sources/foo/foo.swift": {
        "dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.d",
        "object": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o",
        "swiftmodule": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftmodule",
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swiftdeps"
      }
    }
    """

    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }
        let outputFileMap = try OutputFileMap.load(fileSystem: localFileSystem, file: .absolute(file.path), diagnosticEngine: diags)

        let object = try outputFileMap.getOutput(inputFile: .init(path: "/tmp/foo/Sources/foo/foo.swift"), outputType: .object)
        XCTAssertEqual(object.name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o")

        let masterDeps = try outputFileMap.getOutput(inputFile: .init(path: ""), outputType: .swiftDeps)
        XCTAssertEqual(masterDeps.name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps")
      }
    }
  }

  func testOutputFileMapLoadingDocAndSourceinfo() throws {
    let contents = """
    {
      "": {
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps"
      },
      "/tmp/foo/Sources/foo/foo.swift": {
        "dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.d",
        "object": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o",
        "swiftmodule": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftmodule",
        "swift-dependencies": "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swiftdeps"
      }
    }
    """

    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }
        let outputFileMap = try OutputFileMap.load(fileSystem: localFileSystem, file: .absolute(file.path), diagnosticEngine: diags)

        let doc = try outputFileMap.getOutput(inputFile: .init(path: "/tmp/foo/Sources/foo/foo.swift"), outputType: .swiftDocumentation)
        XCTAssertEqual(doc.name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftdoc")

        let source = try outputFileMap.getOutput(inputFile: .init(path: "/tmp/foo/Sources/foo/foo.swift"), outputType: .swiftSourceInfoFile)
        XCTAssertEqual(source.name, "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftsourceinfo")
      }
    }
  }

  func testMergeModuleEmittingDependencies() throws {
    var driver1 = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Foo", "-emit-dependencies", "-emit-module", "-serialize-diagnostics", "-driver-filelist-threshold=9999"])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertTrue(plannedJobs[0].kind == .compile)
    XCTAssertTrue(plannedJobs[1].kind == .compile)
    XCTAssertTrue(plannedJobs[2].kind == .mergeModule)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-dependencies-path")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-serialize-diagnostics-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-emit-dependencies-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-serialize-diagnostics-path")))
    XCTAssertFalse(plannedJobs[2].commandLine.contains(.flag("-emit-dependencies-path")))
    XCTAssertFalse(plannedJobs[2].commandLine.contains(.flag("-serialize-diagnostics-path")))
  }

  func testOutputFileMapStoring() throws {
    // Create sample OutputFileMap:

    // Rather than writing VirtualPath(path:...) over and over again, make strings, then fix it
    let stringyEntries: [String: [FileType: String]] = [
      "": [.swiftDeps: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/master.swiftdeps"],
      "foo.swift" : [
        .dependencies: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.d",
        .object: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swift.o",
        .swiftModule: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo~partial.swiftmodule",
        .swiftDeps: "/tmp/foo/.build/x86_64-apple-macosx/debug/foo.build/foo.swiftdeps"
        ]
    ]
    let pathyEntries = try Dictionary(uniqueKeysWithValues:
      stringyEntries.map { try
        (
          VirtualPath(path: $0.key),
          Dictionary(uniqueKeysWithValues: $0.value.map { try ($0.key, VirtualPath(path: $0.value))})
        )})
    let sampleOutputFileMap = OutputFileMap(entries: pathyEntries)

    try withTemporaryFile { file in
      try sampleOutputFileMap.store(fileSystem: localFileSystem, file: file.path, diagnosticEngine: DiagnosticsEngine())
      let contentsForDebugging = try localFileSystem.readFileContents(file.path).cString
      _ = contentsForDebugging
      let recoveredOutputFileMap = try OutputFileMap.load(fileSystem: localFileSystem, file: .absolute(file.path), diagnosticEngine: DiagnosticsEngine())
      XCTAssertEqual(sampleOutputFileMap, recoveredOutputFileMap)
    }
  }

  func testOutputFileMapResolving() throws {
    // Create sample OutputFileMap:

    let stringyEntries: [String: [FileType: String]] = [
      "": [.swiftDeps: "foo.build/master.swiftdeps"],
      "foo.swift" : [
        .dependencies: "foo.build/foo.d",
        .object: "foo.build/foo.swift.o",
        .swiftModule: "foo.build/foo~partial.swiftmodule",
        .swiftDeps: "foo.build/foo.swiftdeps"
      ]
    ]
    let resolvedStringyEntries: [String: [FileType: String]] = [
      "": [.swiftDeps: "/foo_root/foo.build/master.swiftdeps"],
      "/foo_root/foo.swift" : [
        .dependencies: "/foo_root/foo.build/foo.d",
        .object: "/foo_root/foo.build/foo.swift.o",
        .swiftModule: "/foo_root/foo.build/foo~partial.swiftmodule",
        .swiftDeps: "/foo_root/foo.build/foo.swiftdeps"
      ]
    ]
    func outputFileMapFromStringyEntries(
      _ entries: [String: [FileType: String]]
    ) throws -> OutputFileMap {
      .init(entries: Dictionary(uniqueKeysWithValues: try entries.map { try (
        VirtualPath(path: $0.key),
        $0.value.mapValues(VirtualPath.init(path:))
      )}))
    }
    let sampleOutputFileMap =
      try outputFileMapFromStringyEntries(stringyEntries)
    let resolvedOutputFileMap = sampleOutputFileMap
      .resolveRelativePaths(relativeTo: .init("/foo_root"))
    let expectedOutputFileMap =
      try outputFileMapFromStringyEntries(resolvedStringyEntries)
    XCTAssertEqual(expectedOutputFileMap, resolvedOutputFileMap)
  }

  func testOutputFileMapRelativePathArg() throws {
    try withTemporaryDirectory { path in
      guard let cwd = localFileSystem
        .currentWorkingDirectory else { fatalError() }
      let outputFileMap = path.appending(component: "outputFileMap.json")
      try localFileSystem.writeFileContents(outputFileMap) {
        $0 <<< """
        {
          "": {
            "swift-dependencies": "build/master.swiftdeps"
          },
          "main.swift": {
            "object": "build/main.o",
            "dependencies": "build/main.o.d"
          },
          "util.swift": {
            "object": "build/util.o",
            "dependencies": "build/util.o.d"
          }
        }
        """
      }
      let outputFileMapRelative = outputFileMap.relative(to: cwd).pathString
      // FIXME: Needs a better way to check that outputFileMap correctly loaded
      XCTAssertNoThrow(try Driver(args: [
        "swiftc",
        "--output-file-map", outputFileMapRelative,
        "main.swift", "util.swift",
      ]))
    }
  }

  func testResponseFileExpansion() throws {
    try withTemporaryDirectory { path in
      let diags = DiagnosticsEngine()
      let fooPath = path.appending(component: "foo.rsp")
      let barPath = path.appending(component: "bar.rsp")
      try localFileSystem.writeFileContents(fooPath) {
        $0 <<< "hello\nbye\nbye\\ to\\ you\n@\(barPath.pathString)"
      }
      try localFileSystem.writeFileContents(barPath) {
        $0 <<< "from\nbar\n@\(fooPath.pathString)"
      }
      let args = try Driver.expandResponseFiles(["swift", "compiler", "-Xlinker", "@loader_path", "@" + fooPath.pathString, "something"], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(args, ["swift", "compiler", "-Xlinker", "@loader_path", "hello", "bye", "bye to you", "from", "bar", "something"])
      XCTAssertEqual(diags.diagnostics.count, 1)
      XCTAssert(diags.diagnostics.first!.description.contains("is recursively expanded"))
    }
  }

  /// Tests how response files tokens such as spaces, comments, escaping characters and quotes, get parsed and expanded.
  func testResponseFileTokenization() throws {
    try withTemporaryDirectory { path  in
      let diags = DiagnosticsEngine()
      let fooPath = path.appending(component: "foo.rsp")
      let barPath = path.appending(component: "bar.rsp")
      let escapingPath = path.appending(component: "escaping.rsp")

      try localFileSystem.writeFileContents(fooPath) {
        $0 <<< #"""
        Command1 --kkc
        //This is a comment
        // this is another comment
        but this is \\\\\a command
        @\#(barPath.pathString)
        @NotAFile
        -flag="quoted string with a \"quote\" inside" -another-flag
        """#
        <<< "\nthis  line\thas        lots \t  of    whitespace"
      }

      try localFileSystem.writeFileContents(barPath) {
        $0 <<< #"""
        swift
        "rocks!"
        compiler
        -Xlinker

        @loader_path
        mkdir "Quoted Dir"
        cd Unquoted\ Dir
        // Bye!
        """#
      }

      try localFileSystem.writeFileContents(escapingPath) {
        $0 <<< "swift\n--driver-mode=swiftc\n-v\r\n//comment\n\"the end\""
      }
      let args = try Driver.expandResponseFiles(["@" + fooPath.pathString], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(args, ["Command1", "--kkc", "but", "this", "is", #"\\a"#, "command", #"swift"#, "rocks!" ,"compiler", "-Xlinker", "@loader_path", "mkdir", "Quoted Dir", "cd", "Unquoted Dir", "@NotAFile", #"-flag=quoted string with a "quote" inside"#, "-another-flag", "this", "line", "has", "lots", "of", "whitespace"])
      let escapingArgs = try Driver.expandResponseFiles(["@" + escapingPath.pathString], fileSystem: localFileSystem, diagnosticsEngine: diags)
      XCTAssertEqual(escapingArgs, ["swift", "--driver-mode=swiftc", "-v","the end"])
    }
  }

  func testUsingResponseFiles() throws {
    let manyArgs = (1...20000).map { "-DTEST_\($0)" }
    // Needs response file
    do {
      var driver = try Driver(args: ["swift"] + manyArgs + ["foo.swift"])
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs.count == 1 && jobs[0].kind == .interpret)
      let interpretJob = jobs[0]
      let resolver = try ArgsResolver(fileSystem: localFileSystem)
      let resolvedArgs: [String] = try resolver.resolveArgumentList(for: interpretJob, forceResponseFiles: false)
      XCTAssertTrue(resolvedArgs.count == 2)
      XCTAssertEqual(resolvedArgs[1].first, "@")
      let responseFilePath = try AbsolutePath(validating: String(resolvedArgs[1].dropFirst()))
      let contents = try localFileSystem.readFileContents(responseFilePath).description
      XCTAssertTrue(contents.hasPrefix("-frontend\n-interpret\nfoo.swift"))
      XCTAssertTrue(contents.contains("-D\nTEST_20000"))
      XCTAssertTrue(contents.contains("-D\nTEST_1"))
    }
    // Forced response file
    do {
      var driver = try Driver(args: ["swift"] + ["foo.swift"])
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs.count == 1 && jobs[0].kind == .interpret)
      let interpretJob = jobs[0]
      let resolver = try ArgsResolver(fileSystem: localFileSystem)
      let resolvedArgs: [String] = try resolver.resolveArgumentList(for: interpretJob, forceResponseFiles: true)
      XCTAssertTrue(resolvedArgs.count == 2)
      XCTAssertEqual(resolvedArgs[1].first, "@")
      let responseFilePath = try AbsolutePath(validating: String(resolvedArgs[1].dropFirst()))
      let contents = try localFileSystem.readFileContents(responseFilePath).description
      XCTAssertTrue(contents.hasPrefix("-frontend\n-interpret\nfoo.swift"))
    }

    // No response file
    do {
      var driver = try Driver(args: ["swift"] + ["foo.swift"])
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs.count == 1 && jobs[0].kind == .interpret)
      let interpretJob = jobs[0]
      let resolver = try ArgsResolver(fileSystem: localFileSystem)
      let resolvedArgs: [String] = try resolver.resolveArgumentList(for: interpretJob, forceResponseFiles: false)
      XCTAssertFalse(resolvedArgs.map { $0.hasPrefix("@") }.reduce(false){ $0 || $1 })
    }
  }

  func testLinking() throws {
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
    env["SWIFT_DRIVER_SWIFT_AUTOLINK_EXTRACT_EXEC"] = "/garbage/swift-autolink-extract"
    env["SWIFT_DRIVER_DSYMUTIL_EXEC"] = "/garbage/dsymutil"

    let commonArgs = ["swiftc", "foo.swift", "bar.swift",  "-module-name", "Test"]
    do {
      // macOS target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-arch")))
      XCTAssertTrue(cmd.contains(.flag("x86_64")))
      XCTAssertTrue(cmd.contains(subsequence: ["-platform_version", "macos", "10.15.0"]))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // iOS target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "arm64-apple-ios10.0"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-arch")))
      XCTAssertTrue(cmd.contains(.flag("arm64")))
      XCTAssertTrue(cmd.contains(subsequence: ["-platform_version", "ios", "10.0.0"]))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // macOS catalyst target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "x86_64-apple-ios13.0-macabi"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-arch")))
      XCTAssertTrue(cmd.contains(.flag("x86_64")))
      XCTAssertTrue(cmd.contains(subsequence: ["-platform_version", "mac-catalyst", "13.0.0"]))
      XCTAssertTrue(cmd.contains(.flag("13.0.0")))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // Xlinker flags
      var driver = try Driver(args: commonArgs + ["-emit-library", "-L", "/tmp", "-Xlinker", "-w", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-dylib")))
      XCTAssertTrue(cmd.contains(.flag("-w")))
      XCTAssertTrue(cmd.contains(.flag("-L")))
      XCTAssertTrue(cmd.contains(.path(.absolute(AbsolutePath("/tmp")))))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.dylib"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // static linking
      var driver = try Driver(args: commonArgs + ["-emit-library", "-static", "-L", "/tmp", "-Xlinker", "-w", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-static")))
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.a"))

      // The regular Swift driver doesn't pass Xlinker flags to the static
      // linker, so be consistent with this
      XCTAssertFalse(cmd.contains(.flag("-w")))
      XCTAssertFalse(cmd.contains(.flag("-L")))
      XCTAssertFalse(cmd.contains(.path(.absolute(AbsolutePath("/tmp")))))

      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // executable linking
      var driver = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(3, plannedJobs.count)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .autolinkExtract })

      let linkJob = plannedJobs[2]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "Test"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }
    
    do {
      // lto linking
      var driver1 = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-apple-macosx10.15", "-lto=llvm-thin"], env: env)
      let plannedJobs1 = try driver1.planBuild()
      XCTAssertFalse(plannedJobs1.contains(where: { $0.kind == .autolinkExtract }))
      let linkJob1 = plannedJobs1.first(where: { $0.kind == .link })
      XCTAssertTrue(linkJob1?.tool.name.contains("ld"))
      XCTAssertTrue(linkJob1?.commandLine.contains(.flag("-lto_library")))

      var driver2 = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-unknown-linux", "-lto=llvm-thin"], env: env)
      let plannedJobs2 = try driver2.planBuild()
      XCTAssertFalse(plannedJobs2.contains(where: { $0.kind == .autolinkExtract }))
      let linkJob2 = plannedJobs2.first(where: { $0.kind == .link })
      XCTAssertTrue(linkJob2?.tool.name.contains("clang"))
      XCTAssertTrue(linkJob2?.commandLine.contains(.flag("-flto=thin")))

      var driver3 = try Driver(args: commonArgs + ["-emit-executable", "-target", "x86_64-unknown-linux", "-lto=llvm-full"], env: env)
      let plannedJobs3 = try driver3.planBuild()
      XCTAssertFalse(plannedJobs3.contains(where: { $0.kind == .autolinkExtract }))
      
      let compileJob3 = try XCTUnwrap(plannedJobs3.first(where: { $0.kind == .compile }))
      XCTAssertTrue(compileJob3.outputs.contains { $0.file.basename.hasSuffix(".bc") })

      let linkJob3 = try XCTUnwrap(plannedJobs3.first(where: { $0.kind == .link }))
      XCTAssertTrue(linkJob3.tool.name.contains("clang"))
      XCTAssertTrue(linkJob3.commandLine.contains(.flag("-flto=full")))
    }

    do {
      var driver = try Driver(args: commonArgs + ["-emit-executable", "-emit-module", "-g", "-target", "x86_64-apple-macosx10.15"], env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(5, plannedJobs.count)
      XCTAssertEqual(plannedJobs.map(\.kind), [.compile, .compile, .mergeModule, .link, .generateDSYM])

      let linkJob = plannedJobs[3]
      XCTAssertEqual(linkJob.kind, .link)

      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertTrue(cmd.contains(subsequence: [.flag("-add_ast_path"), .path(.relative(.init("Test.swiftmodule")))]))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "Test"))

      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // linux target
      var driver = try Driver(args: commonArgs + ["-emit-library", "-target", "x86_64-unknown-linux"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let autolinkExtractJob = plannedJobs[2]
      XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

      let autolinkCmd = autolinkExtractJob.commandLine
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("Test.autolink")))))

      let linkJob = plannedJobs[3]
      XCTAssertEqual(linkJob.kind, .link)
      let cmd = linkJob.commandLine
      XCTAssertTrue(cmd.contains(.flag("-o")))
      XCTAssertTrue(cmd.contains(.flag("-shared")))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertTrue(cmd.contains(.responseFilePath(.temporary(RelativePath("Test.autolink")))))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.so"))

      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-static")))
    }

    do {
      // static linux linking
      var driver = try Driver(args: commonArgs + ["-emit-library", "-static", "-target", "x86_64-unknown-linux"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let autolinkExtractJob = plannedJobs[2]
      XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

      let autolinkCmd = autolinkExtractJob.commandLine
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("Test.autolink")))))

      let linkJob = plannedJobs[3]
      let cmd = linkJob.commandLine
      // we'd expect "ar crs libTest.a foo.o bar.o"
      XCTAssertTrue(cmd.contains(.flag("crs")))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.a"))

      XCTAssertFalse(cmd.contains(.flag("-o")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      // static WASM linking
      var driver = try Driver(args: commonArgs + ["-emit-library", "-static", "-target", "wasm32-unknown-wasi"], env: env)
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let autolinkExtractJob = plannedJobs[2]
      XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

      let autolinkCmd = autolinkExtractJob.commandLine
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("Test.autolink")))))

      let linkJob = plannedJobs[3]
      let cmd = linkJob.commandLine
      // we'd expect "ar crs libTest.a foo.o bar.o"
      XCTAssertTrue(cmd.contains(.flag("crs")))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("foo.o")))))
      XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("bar.o")))))
      XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "libTest.a"))

      XCTAssertFalse(cmd.contains(.flag("-o")))
      XCTAssertFalse(cmd.contains(.flag("-dylib")))
      XCTAssertFalse(cmd.contains(.flag("-static")))
      XCTAssertFalse(cmd.contains(.flag("-shared")))
    }

    do {
      try withTemporaryDirectory { path in
        try localFileSystem.writeFileContents(
          path.appending(components: "wasi", "static-executable-args.lnk")) { $0 <<< "garbage" }
        // WASM executable linking
        var driver = try Driver(args: commonArgs + ["-emit-executable",
                                                    "-target", "wasm32-unknown-wasi",
                                                    "-resource-dir", path.pathString,
                                                    "-sdk", "/sdk/path"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(plannedJobs.count, 4)

        let autolinkExtractJob = plannedJobs[2]
        XCTAssertEqual(autolinkExtractJob.kind, .autolinkExtract)

        let autolinkCmd = autolinkExtractJob.commandLine
        XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("foo.o")))))
        XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("bar.o")))))
        XCTAssertTrue(autolinkCmd.contains(.path(.temporary(RelativePath("Test.autolink")))))

        let linkJob = plannedJobs[3]
        let cmd = linkJob.commandLine
        XCTAssertTrue(cmd.contains(subsequence: ["-target", "wasm32-unknown-wasi"]))
        XCTAssertTrue(cmd.contains(subsequence: ["--sysroot", .path(.absolute(.init("/sdk/path")))]))
        XCTAssertTrue(cmd.contains(.path(.absolute(path.appending(components: "wasi", "wasm32", "swiftrt.o")))))
        XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("foo.o")))))
        XCTAssertTrue(cmd.contains(.path(.temporary(RelativePath("bar.o")))))
        XCTAssertTrue(cmd.contains(.responseFilePath(.temporary(RelativePath("Test.autolink")))))
        XCTAssertTrue(cmd.contains(.responseFilePath(.absolute(path.appending(components: "wasi", "static-executable-args.lnk")))))
        XCTAssertEqual(linkJob.outputs[0].file, try VirtualPath(path: "Test"))

        XCTAssertFalse(cmd.contains(.flag("-dylib")))
        XCTAssertFalse(cmd.contains(.flag("-shared")))
      }
    }
  }

  func testWebAssemblyUnsupportedFeatures() throws {
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_SWIFT_AUTOLINK_EXTRACT_EXEC"] = "/garbage/swift-autolink-extract"
    do {
      var driver = try Driver(args: ["swift", "-target", "wasm32-unknown-wasi", "foo.swift"], env: env)
      XCTAssertThrowsError(try driver.planBuild()) {
        guard case WebAssemblyToolchain.Error.interactiveModeUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "wasm32-unknown-wasi", "-emit-library", "foo.swift"], env: env)
      XCTAssertThrowsError(try driver.planBuild()) {
        guard case WebAssemblyToolchain.Error.dynamicLibrariesUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "wasm32-unknown-wasi", "-no-static-executable", "foo.swift"], env: env)
      XCTAssertThrowsError(try driver.planBuild()) {
        guard case WebAssemblyToolchain.Error.dynamicLibrariesUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }

    do {
      XCTAssertThrowsError(try Driver(args: ["swiftc", "-target", "wasm32-unknown-wasi", "foo.swift", "-sanitize=thread"], env: env)) {
        guard case WebAssemblyToolchain.Error.sanitizersUnsupportedForTarget("wasm32-unknown-wasi") = $0 else {
          XCTFail()
          return
        }
      }
    }
  }

  func testCompatibilityLibs() throws {
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
    try withTemporaryDirectory { path in
      let path5_0Mac = path.appending(components: "macosx", "libswiftCompatibility50.a")
      let path5_1Mac = path.appending(components: "macosx", "libswiftCompatibility51.a")
      let pathDynamicReplacementsMac = path.appending(components: "macosx", "libswiftCompatibilityDynamicReplacements.a")
      let path5_0iOS = path.appending(components: "iphoneos", "libswiftCompatibility50.a")
      let path5_1iOS = path.appending(components: "iphoneos", "libswiftCompatibility51.a")
      let pathDynamicReplacementsiOS = path.appending(components: "iphoneos", "libswiftCompatibilityDynamicReplacements.a")

      for compatibilityLibPath in [path5_0Mac, path5_1Mac,
                                   pathDynamicReplacementsMac, path5_0iOS,
                                   path5_1iOS, pathDynamicReplacementsiOS] {
        try localFileSystem.writeFileContents(compatibilityLibPath) { $0 <<< "Empty" }
      }
      let commonArgs = ["swiftc", "foo.swift", "bar.swift",  "-module-name", "Test", "-resource-dir", path.pathString]

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.14"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.15.1"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.15.4"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "x86_64-apple-macosx10.15.4", "-runtime-compatibility-version", "5.0"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1Mac))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsMac))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "arm64-apple-ios13.0"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0iOS))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1iOS))]))
        XCTAssertFalse(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsiOS))]))
      }

      do {
        var driver = try Driver(args: commonArgs + ["-target", "arm64-apple-ios12.0"], env: env)
        let plannedJobs = try driver.planBuild()

        XCTAssertEqual(3, plannedJobs.count)
        let linkJob = plannedJobs[2]
        XCTAssertEqual(linkJob.kind, .link)
        let cmd = linkJob.commandLine

        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_0iOS))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(path5_1iOS))]))
        XCTAssertTrue(cmd.contains(subsequence: [.flag("-force_load"), .path(.absolute(pathDynamicReplacementsiOS))]))
      }
    }
  }

  func testSanitizerArgs() throws {
  // FIXME: This doesn't work on Linux.
  #if os(macOS)
    let commonArgs = [
      "swiftc", "foo.swift", "bar.swift",
      "-emit-executable", "-target", "x86_64-apple-macosx10.9",
      "-module-name", "Test"
    ]
    do {
      // address sanitizer
      var driver = try Driver(args: commonArgs + ["-sanitize=address"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=address")))

      let linkJob = plannedJobs[2]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains {
        if case .path(let path) = $0 {
          return path.name.contains("darwin/libclang_rt.asan_osx_dynamic.dylib")
        }
        return false
      })
    }

    do {
      // thread sanitizer
      var driver = try Driver(args: commonArgs + ["-sanitize=thread"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=thread")))

      let linkJob = plannedJobs[2]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains {
        if case .path(let path) = $0 {
          return path.name.contains("darwin/libclang_rt.tsan_osx_dynamic.dylib")
        }
        return false
      })
    }

    do {
      // undefined behavior sanitizer
      var driver = try Driver(args: commonArgs + ["-sanitize=undefined"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 3)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=undefined")))

      let linkJob = plannedJobs[2]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains {
        if case .path(let path) = $0 {
          return path.name.contains("darwin/libclang_rt.ubsan_osx_dynamic.dylib")
        }
        return false
      })
    }

    // FIXME: This test will fail when run on macOS, because the driver uses
    //        the existence of the runtime support libraries to determine if
    //        a sanitizer is supported. Until we allow cross-compiling with
    //        sanitizers, we'll need to disable this test on macOS
    #if os(Linux)
    do {
      // linux multiple sanitizers
      var driver = try Driver(
        args: commonArgs + [
          "-target", "x86_64-unknown-linux",
          "-sanitize=address", "-sanitize=undefined"
        ]
      )
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=address")))
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=undefined")))

      let linkJob = plannedJobs[3]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains(.flag("-fsanitize=address,undefined")))
    }

    do {
      // linux scudo hardened allocator
      var driver = try Driver(
        args: commonArgs + [
          "-target", "x86_64-unknown-linux",
          "-sanitize=scudo"
        ]
      )
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 4)

      let compileJob = plannedJobs[0]
      let compileCmd = compileJob.commandLine
      XCTAssertTrue(compileCmd.contains(.flag("-sanitize=scudo")))

      let linkJob = plannedJobs[3]
      let linkCmd = linkJob.commandLine
      XCTAssertTrue(linkCmd.contains(.flag("-fsanitize=scudo")))
    }
    #endif
  #endif
  }

  func testBatchModeCompiles() throws {
    do {
      var driver1 = try Driver(args: ["swiftc", "foo1.swift", "bar1.swift", "foo2.swift", "bar2.swift", "foo3.swift", "bar3.swift", "foo4.swift", "bar4.swift", "foo5.swift", "bar5.swift", "wibble.swift", "-module-name", "Test", "-enable-batch-mode", "-driver-batch-count", "3"])
      let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 4)
      XCTAssertEqual(plannedJobs[0].outputs.count, 4)
      XCTAssertEqual(plannedJobs[0].outputs.first!.file, VirtualPath.temporary(RelativePath("foo1.o")))
      XCTAssertEqual(plannedJobs[1].outputs.count, 4)
      XCTAssertEqual(plannedJobs[1].outputs.first!.file, VirtualPath.temporary(RelativePath("foo3.o")))
      XCTAssertEqual(plannedJobs[2].outputs.count, 3)
      XCTAssertEqual(plannedJobs[2].outputs.first!.file, VirtualPath.temporary(RelativePath("foo5.o")))
      XCTAssertTrue(plannedJobs[3].tool.name.contains(driver1.targetTriple.isDarwin ? "ld" : "clang"))
      XCTAssertEqual(plannedJobs[3].outputs.count, 1)
      XCTAssertEqual(plannedJobs[3].outputs.first!.file, VirtualPath.relative(RelativePath("Test")))
    }

    // Test 1 partition results in 1 job
    do {
      var driver = try Driver(args: ["swiftc", "-toolchain-stdlib-rpath", "-module-cache-path", "/tmp/clang-module-cache", "-swift-version", "4", "-Xfrontend", "-ignore-module-source-info", "-module-name", "batch", "-enable-batch-mode", "-j", "1", "-c", "main.swift", "lib.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      var count = 0
      for arg in plannedJobs[0].commandLine where arg == .flag("-primary-file") {
        count += 1
      }
      XCTAssertEqual(count, 2)
    }
  }

  func testSingleThreadedWholeModuleOptimizationCompiles() throws {
    var driver1 = try Driver(args: ["swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "-module-name", "Test", "-target", "x86_64-apple-macosx10.15", "-emit-module-interface", "-emit-objc-header-path", "Test-Swift.h", "-emit-private-module-interface-path", "Test.private.swiftinterface"])
    let plannedJobs = try driver1.planBuild()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertEqual(plannedJobs[0].kind, .compile)
    XCTAssertEqual(plannedJobs[0].outputs.count, 4)
    XCTAssertEqual(plannedJobs[0].outputs[0].file, VirtualPath.temporary(RelativePath("Test.o")))
    XCTAssertEqual(plannedJobs[0].outputs[1].file, VirtualPath.relative(RelativePath("Test-Swift.h")))
    XCTAssertEqual(plannedJobs[0].outputs[2].file, VirtualPath.relative(RelativePath("Test.swiftinterface")))
    XCTAssertEqual(plannedJobs[0].outputs[3].file, VirtualPath.relative(RelativePath("Test.private.swiftinterface")))
    XCTAssert(!plannedJobs[0].commandLine.contains(.flag("-primary-file")))
    XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-module-interface-path")))
    XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-private-module-interface-path")))

    XCTAssertEqual(plannedJobs[1].kind, .link)
  }

  func testMultiThreadedWholeModuleOptimizationCompiles() throws {
    do {
      var driver1 = try Driver(args: [
        "swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "wibble.swift",
        "-module-name", "Test", "-num-threads", "4"
      ])
      let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].outputs.count, 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, VirtualPath.temporary(RelativePath("foo.o")))
      XCTAssertEqual(plannedJobs[0].outputs[1].file, VirtualPath.temporary(RelativePath("bar.o")))
      XCTAssertEqual(plannedJobs[0].outputs[2].file, VirtualPath.temporary(RelativePath("wibble.o")))
      XCTAssert(!plannedJobs[0].commandLine.contains(.flag("-primary-file")))

      XCTAssertEqual(plannedJobs[1].kind, .link)
    }

    // emit-module
    do {
      var driver = try Driver(args: ["swiftc", "-module-name=ThisModule", "-wmo", "-num-threads", "4", "main.swift", "multi-threaded.swift", "-emit-module", "-o", "test.swiftmodule"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 2)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, VirtualPath.relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[0].inputs[1].file, VirtualPath.relative(RelativePath("multi-threaded.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, VirtualPath.relative(RelativePath("test.swiftmodule")))
    }
  }

  func testDashDashPassingDownInput() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-module-name=ThisModule", "-wmo", "-num-threads", "4", "-emit-module", "-o", "test.swiftmodule", "--", "main.swift", "multi-threaded.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertFalse(driver.diagnosticEngine.hasErrors)
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 2)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, VirtualPath.relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[0].inputs[1].file, VirtualPath.relative(RelativePath("multi-threaded.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, VirtualPath.relative(RelativePath("test.swiftmodule")))
    }
  }

  func testWholeModuleOptimizationOutputFileMap() throws {
    let contents = """
    {
      "": {
        "swiftinterface": "/tmp/salty/Test.swiftinterface"
      }
    }
    """

    try withTemporaryFile { file in
      try assertNoDiagnostics { diags in
        try localFileSystem.writeFileContents(file.path) { $0 <<< contents }
        var driver1 = try Driver(args: [
          "swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "wibble.swift", "-module-name", "Test",
          "-num-threads", "4", "-output-file-map", file.path.pathString, "-emit-module-interface"
        ])
        let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
        XCTAssertEqual(plannedJobs.count, 2)
        XCTAssertEqual(plannedJobs[0].kind, .compile)
        XCTAssertEqual(plannedJobs[0].outputs.count, 4)
        XCTAssertEqual(plannedJobs[0].outputs[0].file, VirtualPath.temporary(RelativePath("foo.o")))
        XCTAssertEqual(plannedJobs[0].outputs[1].file, VirtualPath.temporary(RelativePath("bar.o")))
        XCTAssertEqual(plannedJobs[0].outputs[2].file, VirtualPath.temporary(RelativePath("wibble.o")))
        XCTAssertEqual(plannedJobs[0].outputs[3].file, VirtualPath.absolute(AbsolutePath("/tmp/salty/Test.swiftinterface")))
        XCTAssert(!plannedJobs[0].commandLine.contains(.flag("-primary-file")))

        XCTAssertEqual(plannedJobs[1].kind, .link)
      }
    }
  }

  func testWholeModuleOptimizationUsingSupplementaryOutputFileMap() throws {
    var driver1 = try Driver(args: [
      "swiftc", "-whole-module-optimization", "foo.swift", "bar.swift", "wibble.swift", "-module-name", "Test",
      "-emit-module-interface", "-driver-filelist-threshold=0"
    ])
    let plannedJobs = try driver1.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertEqual(plannedJobs[0].kind, .compile)
    print(plannedJobs[0].commandLine.joinedArguments)
    XCTAssert(plannedJobs[0].commandLine.contains(.flag("-supplementary-output-file-map")))
  }

  func testMergeModulesOnly() throws {
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "-emit-dependencies", "-emit-module-doc-path", "/foo/bar/Test.swiftdoc", "-emit-module-source-info-path", "/foo/bar/Test.swiftsourceinfo"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertEqual(plannedJobs[0].outputs.count, 4)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("foo.swiftmodule")))
      XCTAssertEqual(plannedJobs[0].outputs[1].file, .temporary(RelativePath("foo.swiftdoc")))
      XCTAssertEqual(plannedJobs[0].outputs[2].file, .temporary(RelativePath("foo.swiftsourceinfo")))
      XCTAssertEqual(plannedJobs[0].outputs[3].file, .temporary(RelativePath("foo.d")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))

      XCTAssertEqual(plannedJobs[1].outputs.count, 4)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .temporary(RelativePath("bar.swiftmodule")))
      XCTAssertEqual(plannedJobs[1].outputs[1].file, .temporary(RelativePath("bar.swiftdoc")))
      XCTAssertEqual(plannedJobs[1].outputs[2].file, .temporary(RelativePath("bar.swiftsourceinfo")))
      XCTAssertEqual(plannedJobs[1].outputs[3].file, .temporary(RelativePath("bar.d")))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-import-objc-header")))

      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .absolute(AbsolutePath("/foo/bar/Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .absolute(AbsolutePath("/foo/bar/Test.swiftsourceinfo")))
      XCTAssert(plannedJobs[2].commandLine.contains(.flag("-import-objc-header")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", "/foo/bar/Test.swiftmodule" ])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .absolute(AbsolutePath("/foo/bar/Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .absolute(AbsolutePath("/foo/bar/Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .absolute(AbsolutePath("/foo/bar/Test.swiftsourceinfo")))
    }

    do {
      // Make sure the swiftdoc path is correct for a relative module
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", "Test.swiftmodule" ])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .relative(RelativePath("Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .relative(RelativePath("Test.swiftsourceinfo")))
    }

    do {
      // Make sure the swiftdoc path is correct for an inferred module
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-doc", "-emit-module"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertTrue(plannedJobs[2].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[2].outputs.count, 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .relative(RelativePath("Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .relative(RelativePath("Test.swiftsourceinfo")))
    }

    do {
      // -o specified
      var driver = try Driver(args: ["swiftc", "-emit-module", "-o", "/tmp/test.swiftmodule", "input.swift"])
      let plannedJobs = try driver.planBuild()

      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("input.swiftmodule")))
      XCTAssertEqual(plannedJobs[1].kind, .mergeModule)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, .temporary(RelativePath("input.swiftmodule")))
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .absolute(AbsolutePath("/tmp/test.swiftmodule")))
    }
  }

  func testEmitModuleSeparately() throws {
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", "/foo/bar/Test.swiftmodule", "-experimental-emit-module-separately", "-emit-library", "-target", "x86_64-apple-macosx10.15"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      XCTAssertTrue(plannedJobs[0].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[0].outputs.count, 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .absolute(AbsolutePath("/foo/bar/Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[0].outputs[1].file, .absolute(AbsolutePath("/foo/bar/Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[0].outputs[2].file, .absolute(AbsolutePath("/foo/bar/Test.swiftsourceinfo")))
    }

    do {
      // We don't expect partial jobs when asking only for the swiftmodule with
      // -experimental-emit-module-separately.
      var driver = try Driver(args: ["swiftc", "foo.swift", "bar.swift", "-module-name", "Test", "-emit-module-path", "/foo/bar/Test.swiftmodule", "-experimental-emit-module-separately"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertTrue(plannedJobs[0].tool.name.contains("swift"))
      XCTAssertEqual(plannedJobs[0].outputs.count, 3)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .absolute(AbsolutePath("/foo/bar/Test.swiftmodule")))
      XCTAssertEqual(plannedJobs[0].outputs[1].file, .absolute(AbsolutePath("/foo/bar/Test.swiftdoc")))
      XCTAssertEqual(plannedJobs[0].outputs[2].file, .absolute(AbsolutePath("/foo/bar/Test.swiftsourceinfo")))
    }
  }

  func testModuleWrapJob() throws {
    // FIXME: These tests will fail when run on macOS, because
    // swift-autolink-extract is not present
    #if os(Linux)
    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-unknown-linux-gnu", "-g", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 5)
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .mergeModule, .autolinkExtract, .moduleWrap, .link]))
      let wrapJob = plannedJobs.filter {$0.kind == .moduleWrap} .first!
      XCTAssertEqual(wrapJob.inputs.count, 1)
      XCTAssertTrue(wrapJob.commandLine.contains(subsequence: ["-target", "x86_64-unknown-linux-gnu"]))
      let mergeJob = plannedJobs.filter {$0.kind == .mergeModule} .first!
      XCTAssertTrue(mergeJob.outputs.contains(wrapJob.inputs.first!))
      XCTAssertTrue(plannedJobs[4].inputs.contains(wrapJob.outputs.first!))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-unknown-linux-gnu", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      // No merge module/module wrap jobs.
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .autolinkExtract, .link]))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-unknown-linux-gnu", "-gdwarf-types", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      // Merge module, but no module wrapping.
      XCTAssertEqual(Set(plannedJobs.map { $0.kind }), Set([.compile, .mergeModule, .autolinkExtract, .link]))
    }
    #endif
    // dsymutil won't be found on other platforms
    #if os(macOS)
    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-apple-macosx10.15", "-g", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 4)
      // No module wrapping with Mach-O.
      XCTAssertEqual(plannedJobs.map { $0.kind }, [.compile, .mergeModule, .link, .generateDSYM])
    }
    #endif
  }

  func testRepl() throws {
    // Do not run this test if no LLDB is found in the toolchain.
    if try !testEnvHasLLDB() {
      throw XCTSkip()
    }

    func isLLDBREPLFlag(_ arg: Job.ArgTemplate) -> Bool {
      if case .flag(let replString) = arg {
        return replString.hasPrefix("--repl=") &&
          !replString.contains("-module-name")
      }
      return false
    }

    do {
      var driver = try Driver(args: ["swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let replJob = plannedJobs.first!
      XCTAssertTrue(replJob.tool.name.contains("lldb"))
      XCTAssertTrue(replJob.requiresInPlaceExecution)
      XCTAssert(replJob.commandLine.contains(where: { isLLDBREPLFlag($0) }))
    }

    do {
      var driver = try Driver(args: ["swift", "-repl"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let replJob = plannedJobs.first!
      XCTAssertTrue(replJob.tool.name.contains("lldb"))
      XCTAssertTrue(replJob.requiresInPlaceExecution)
      XCTAssert(replJob.commandLine.contains(where: { isLLDBREPLFlag($0) }))
    }

    do {
      let (mode, args) = try Driver.invocationRunMode(forArgs: ["swift", "repl"])
      XCTAssertEqual(mode, .normal(isRepl: true))
      var driver = try Driver(args: args)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let replJob = plannedJobs.first!
      XCTAssertTrue(replJob.tool.name.contains("lldb"))
      XCTAssertTrue(replJob.requiresInPlaceExecution)
      XCTAssert(replJob.commandLine.contains(where: { isLLDBREPLFlag($0) }))
    }

    do {
      XCTAssertThrowsError(try Driver(args: ["swift", "-deprecated-integrated-repl"])) {
        XCTAssertEqual($0 as? Driver.Error, Driver.Error.integratedReplRemoved)
      }
    }

    do {
      var driver = try Driver(args: ["swift", "-repl", "/foo/bar/Test.swift"])
      XCTAssertThrowsError(try driver.planBuild()) { error in
        XCTAssertEqual(error as? PlanningError, .replReceivedInput)
      }
    }
  }

  func testImmediateMode() throws {
    do {
      var driver = try Driver(args: ["swift", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.requiresInPlaceExecution)
      XCTAssertEqual(job.inputs.count, 1)
      XCTAssertEqual(job.inputs[0].file, .relative(RelativePath("foo.swift")))
      XCTAssertEqual(job.outputs.count, 0)
      XCTAssertTrue(job.commandLine.contains(.flag("-frontend")))
      XCTAssertTrue(job.commandLine.contains(.flag("-interpret")))
      XCTAssertTrue(job.commandLine.contains(.flag("-module-name")))
      XCTAssertTrue(job.commandLine.contains(.flag("foo")))

      if driver.targetTriple.isMacOSX {
        XCTAssertTrue(job.commandLine.contains(.flag("-sdk")))
      }

      XCTAssertFalse(job.commandLine.contains(.flag("--")))
      XCTAssertTrue(job.extraEnvironment.keys.contains("\(driver.targetTriple.isDarwin ? "DYLD" : "LD")_LIBRARY_PATH"))
    }

    do {
      var driver = try Driver(args: ["swift", "foo.swift", "-some", "args", "-for=foo"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.requiresInPlaceExecution)
      XCTAssertEqual(job.inputs.count, 1)
      XCTAssertEqual(job.inputs[0].file, .relative(RelativePath("foo.swift")))
      XCTAssertEqual(job.outputs.count, 0)
      XCTAssertTrue(job.commandLine.contains(.flag("-frontend")))
      XCTAssertTrue(job.commandLine.contains(.flag("-interpret")))
      XCTAssertTrue(job.commandLine.contains(.flag("-module-name")))
      XCTAssertTrue(job.commandLine.contains(.flag("foo")))
      XCTAssertTrue(job.commandLine.contains(.flag("--")))
      XCTAssertTrue(job.commandLine.contains(.flag("-some")))
      XCTAssertTrue(job.commandLine.contains(.flag("args")))
      XCTAssertTrue(job.commandLine.contains(.flag("-for=foo")))
    }

    do {
      var driver = try Driver(args: ["swift", "-L/path/to/lib", "-F/path/to/framework", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.requiresInPlaceExecution)
      XCTAssertEqual(job.inputs.count, 1)
      XCTAssertEqual(job.inputs[0].file, .relative(RelativePath("foo.swift")))
      XCTAssertEqual(job.outputs.count, 0)
      XCTAssertTrue(job.extraEnvironment.contains {
        $0 == "\(driver.targetTriple.isDarwin ? "DYLD" : "LD")_LIBRARY_PATH" && $1.contains("/path/to/lib")
      })
      if driver.targetTriple.isDarwin {
        XCTAssertTrue(job.extraEnvironment.contains { $0 == "DYLD_FRAMEWORK_PATH" && $1.contains("/path/to/framework") })
      }
    }
  }

  func testTargetTriple() throws {
    let driver1 = try Driver(args: ["swiftc", "-c", "foo.swift", "-module-name", "Foo"])

    let expectedDefaultContents: String
    #if os(macOS)
    expectedDefaultContents = "x86_64-apple-macosx"
    #elseif os(Linux)
    expectedDefaultContents = "-unknown-linux"
    #else
    expectedDefaultContents = "-"
    #endif

    XCTAssert(driver1.targetTriple.triple.contains(expectedDefaultContents),
              "Default triple \(driver1.targetTriple) contains \(expectedDefaultContents)")

    let driver2 = try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-watchos12", "foo.swift", "-module-name", "Foo"])
    XCTAssertEqual(
      driver2.targetTriple.triple, "x86_64-apple-watchos12-simulator")

    let driver3 = try Driver(args: ["swiftc", "-c", "-target", "x86_64-watchos12", "foo.swift", "-module-name", "Foo"])
    XCTAssertEqual(
      driver3.targetTriple.triple, "x86_64-unknown-watchos12-simulator")
  }

  func testTargetVariant() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-ios13.0-macabi", "-target-variant", "x86_64-apple-macosx10.14", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-ios13.0-macabi")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-macosx10.14")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-library", "-target", "x86_64-apple-ios13.0-macabi", "-target-variant", "x86_64-apple-macosx10.14", "-module-name", "foo", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-ios13.0-macabi")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-macosx10.14")))

      XCTAssertEqual(plannedJobs[1].kind, .link)
      XCTAssertTrue(plannedJobs[1].commandLine.contains(subsequence: [
        "-platform_version", "mac-catalyst", "13.0.0"]))
      XCTAssertTrue(plannedJobs[1].commandLine.contains(subsequence: [
        "-platform_version", "macos", "10.14.0"]))
    }

    // Test -target-variant is passed to generate pch job
    do {
      var driver = try Driver(args: ["swiftc", "-target", "x86_64-apple-ios13.0-macabi", "-target-variant", "x86_64-apple-macosx10.14", "-enable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-ios13.0-macabi")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("x86_64-apple-macosx10.14")))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-target")))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("x86_64-apple-ios13.0-macabi")))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-target-variant")))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("x86_64-apple-macosx10.14")))

      XCTAssertEqual(plannedJobs[2].kind, .link)
      XCTAssertTrue(plannedJobs[2].commandLine.contains(subsequence: [
        "-platform_version", "mac-catalyst", "13.0.0"]))
      XCTAssertTrue(plannedJobs[2].commandLine.contains(subsequence: [
        "-platform_version", "macos", "10.14.0"]))
    }
  }


  func testPCHasCompileInput() throws {
    var driver = try Driver(args: ["swiftc", "-target", "x86_64-apple-macosx10.14", "-enable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
    let plannedJobs = try driver.planBuild()
    XCTAssertEqual(plannedJobs.count, 3)
    XCTAssert(plannedJobs[0].kind == .generatePCH)
    XCTAssert(plannedJobs[1].kind == .compile)
    XCTAssert(plannedJobs[1].inputs[0].file.extension == "swift")
    XCTAssert(plannedJobs[1].inputs[1].file.extension == "pch")
  }

  func testEnvironmentInferenceWarning() throws {
    try assertDriverDiagnostics(args: ["swiftc", "-target", "x86_64-apple-ios13.0", "foo.swift"]) {
      $1.expect(.warning("inferring simulator environment for target 'x86_64-apple-ios13.0'; use '-target x86_64-apple-ios13.0-simulator'"))
    }
    try assertDriverDiagnostics(args: ["swiftc", "-target", "x86_64-apple-watchos6.0", "foo.swift"]) {
      $1.expect(.warning("inferring simulator environment for target 'x86_64-apple-watchos6.0'; use '-target x86_64-apple-watchos6.0-simulator'"))
    }
    try assertNoDriverDiagnostics(args: "swiftc", "-target", "x86_64-apple-ios13.0-simulator", "foo.swift")
  }

  func testDarwinToolchainArgumentValidation() throws {
    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-ios6.0",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("iOS 7") = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-macosx10.4",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("OS X 10.9") = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "armv7-apple-ios12.0",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.iOSVersionAboveMaximumDeploymentTarget(12) = error else {
        XCTFail()
        return
      }
    }

    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-ios13.0",
                                           "-target-variant", "x86_64-apple-macosx10.14",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.unsupportedTargetVariant(variant: _) = error else {
        XCTFail()
        return
      }
    }
    
    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-static-stdlib", "-target", "x86_64-apple-macosx10.14",
                                           "foo.swift"])) { error in
      guard case DarwinToolchain.ToolchainValidationError.argumentNotSupported("-static-stdlib") = error else {
        XCTFail()
        return
      }
    }
    
    XCTAssertThrowsError(try Driver(args: ["swiftc", "-c", "-target", "x86_64-apple-macosx10.14", "-experimental-cxx-stdlib", "libstdc++",
                                           "foo.swift"])) { error in
        guard case DarwinToolchain.ToolchainValidationError.darwinOnlySupportsLibCxx = error else {
        XCTFail()
        return
      }
    }
    try assertNoDriverDiagnostics(args: "swiftc", "-c", "-target", "x86_64-apple-macosx10.14", "-link-objc-runtime", "foo.swift")
  }

  func testProfileArgValidation() throws {
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-profile-generate", "-profile-use=profile.profdata"]) {
      $1.expect(.error(Driver.Error.conflictingOptions(.profileGenerate, .profileUse)))
      $1.expect(.error(Driver.Error.missingProfilingData("profile.profdata")))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-profile-use=profile.profdata"]) {
      $1.expect(.error(Driver.Error.missingProfilingData("profile.profdata")))
    }

    try withTemporaryDirectory { path in
      try localFileSystem.writeFileContents(path.appending(component: "profile.profdata"), bytes: .init())
      try assertNoDriverDiagnostics(args: "swiftc", "-working-directory", path.pathString, "foo.swift", "-profile-use=profile.profdata")
    }

    try withTemporaryDirectory { path in
      try localFileSystem.writeFileContents(path.appending(component: "profile.profdata"), bytes: .init())
      try assertDriverDiagnostics(args: ["swiftc", "-working-directory", path.pathString, "foo.swift",
                                         "-profile-use=profile.profdata,profile2.profdata"]) {
        $1.expect(.error(Driver.Error.missingProfilingData(path.appending(component: "profile2.profdata").pathString)))
      }
    }
  }

  func testConditionalCompilationArgValidation() throws {
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-DFOO=BAR"]) {
      $1.expect(.warning("conditional compilation flags do not have values in Swift; they are either present or absent (rather than 'FOO=BAR')"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-D-DFOO"]) {
      $1.expect(.error(Driver.Error.conditionalCompilationFlagHasRedundantPrefix("-DFOO")))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-Dnot-an-identifier"]) {
      $1.expect(.error(Driver.Error.conditionalCompilationFlagIsNotValidIdentifier("not-an-identifier")))
    }

    try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-DFOO")
  }

  func testFrameworkSearchPathArgValidation() throws {
    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-F/some/dir/xyz.framework"]) {
      $1.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-F/some/dir/xyz.framework/"]) {
      $1.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework/"))
    }

    try assertDriverDiagnostics(args: ["swiftc", "foo.swift", "-Fsystem", "/some/dir/xyz.framework"]) {
      $1.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework"))
    }

   try assertNoDriverDiagnostics(args: "swiftc", "foo.swift", "-Fsystem", "/some/dir/")
  }

  func testMultipleValidationFailures() throws {
    try assertDiagnostics { engine, verifier in
      verifier.expect(.error(Driver.Error.conditionalCompilationFlagIsNotValidIdentifier("not-an-identifier")))
      verifier.expect(.warning("framework search path ends in \".framework\"; add directory containing framework instead: /some/dir/xyz.framework"))
      _ = try Driver(args: ["swiftc", "foo.swift", "-Dnot-an-identifier", "-F/some/dir/xyz.framework"], diagnosticsEngine: engine)
    }
  }

  func testToolsDirectory() throws {
    try withTemporaryDirectory { tmpDir in
      let ld = tmpDir.appending(component: "ld")
      try localFileSystem.writeFileContents(ld) { $0 <<< "" }
      try localFileSystem.chmod(.executable, path: AbsolutePath(ld.pathString))
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-apple-macosx10.14",
                                     "-tools-directory", tmpDir.pathString,
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()
      XCTAssertTrue(frontendJobs.count == 2)
      XCTAssertTrue(frontendJobs[1].tool.absolutePath!.pathString == ld.pathString)
    }
  }

  // Test cases ported from Driver/macabi-environment.swift
  func testDarwinSDKVersioning() throws {
    try withTemporaryDirectory { tmpDir in
      let sdk1 = tmpDir.appending(component: "MacOSX10.15.versioned.sdk")
      try localFileSystem.writeFileContents(sdk1.appending(component: "SDKSettings.json")) {
        $0 <<< """
        {
          "Version":"10.15",
          "VersionMap" : {
              "macOS_iOSMac" : {
                  "10.15" : "13.1",
                  "10.15.1" : "13.2"
              },
              "iOSMac_macOS" : {
                  "13.1" : "10.15",
                  "13.2" : "10.15.1"
              }
          }
        }
        """
      }

      let sdk2 = tmpDir.appending(component: "MacOSX10.15.4.versioned.sdk")
      try localFileSystem.writeFileContents(sdk2.appending(component: "SDKSettings.json")) {
        $0 <<< """
        {
          "Version":"10.15.4",
          "VersionMap" : {
              "macOS_iOSMac" : {
                  "10.14.4" : "12.4",
                  "10.14.3" : "12.3",
                  "10.14.2" : "12.2",
                  "10.14.1" : "12.1",
                  "10.15" : "13.0",
                  "10.14" : "12.0",
                  "10.14.5" : "12.5",
                  "10.15.1" : "13.2",
                  "10.15.4" : "13.4"
              },
              "iOSMac_macOS" : {
                  "13.0" : "10.15",
                  "12.3" : "10.14.3",
                  "12.0" : "10.14",
                  "12.4" : "10.14.4",
                  "12.1" : "10.14.1",
                  "12.5" : "10.14.5",
                  "12.2" : "10.14.2",
                  "13.2" : "10.15.1",
                  "13.4" : "10.15.4"
              }
          }
        }
        """
      }

      do {
        var driver = try Driver(args: ["swiftc",
                                       "-target", "x86_64-apple-macosx10.14",
                                       "-sdk", sdk1.description,
                                       "foo.swift"])
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("10.15.0")
        ]))
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.0"),
        ]))
      }

      do {
        var driver = try Driver(args: ["swiftc",
                                       "-target", "x86_64-apple-macosx10.14",
                                       "-target-variant", "x86_64-apple-ios13.0-macabi",
                                       "-sdk", sdk1.description,
                                       "foo.swift"])
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("10.15.0"),
          .flag("-target-variant-sdk-version"),
          .flag("13.1.0"),
        ]))
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.0"),
          .flag("-platform_version"),
          .flag("mac-catalyst"),
          .flag("13.0.0"),
          .flag("13.1.0"),
        ]))
      }

      do {
        var driver = try Driver(args: ["swiftc",
                                       "-target", "x86_64-apple-macosx10.14",
                                       "-target-variant", "x86_64-apple-ios13.0-macabi",
                                       "-sdk", sdk2.description,
                                       "foo.swift"])
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("10.15.4"),
          .flag("-target-variant-sdk-version"),
          .flag("13.4.0")
        ]))
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.4"),
          .flag("-platform_version"),
          .flag("mac-catalyst"),
          .flag("13.0.0"),
          .flag("13.4.0"),
        ]))
      }

      do {
        var driver = try Driver(args: ["swiftc",
                                       "-target-variant", "x86_64-apple-macosx10.14",
                                       "-target", "x86_64-apple-ios13.0-macabi",
                                       "-sdk", sdk2.description,
                                       "foo.swift"])
        let frontendJobs = try driver.planBuild()
        XCTAssertEqual(frontendJobs[0].kind, .compile)
        XCTAssertTrue(frontendJobs[0].commandLine.contains(subsequence: [
          .flag("-target-sdk-version"),
          .flag("13.4.0"),
          .flag("-target-variant-sdk-version"),
          .flag("10.15.4")
        ]))
        XCTAssertEqual(frontendJobs[1].kind, .link)
        XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
          .flag("-platform_version"),
          .flag("mac-catalyst"),
          .flag("13.0.0"),
          .flag("13.4.0"),
          .flag("-platform_version"),
          .flag("macos"),
          .flag("10.14.0"),
          .flag("10.15.4"),
        ]))
      }
    }
  }

  func testDarwinLinkerPlatformVersion() throws {
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-apple-macos10.15",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("macos"),
        .flag("10.15.0"),
      ]))
    }

    // Mac gained aarch64 support in v11
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "arm64-apple-macos10.15",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("macos"),
        .flag("11.0.0"),
      ]))
    }

    // Mac Catalyst on x86_64 was introduced in v13.
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-apple-ios12.0-macabi",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("mac-catalyst"),
        .flag("13.0.0"),
      ]))
    }

    // Mac Catalyst on arm was introduced in v14.
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-ios12.0-macabi",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("mac-catalyst"),
        .flag("14.0.0"),
      ]))
    }

    // Regular iOS
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-ios12.0",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("ios"),
        .flag("12.0.0"),
      ]))
    }

    // Regular tvOS
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-tvos12.0",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("tvos"),
        .flag("12.0.0"),
      ]))
    }

    // Regular watchOS
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-watchos6.0",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("watchos"),
        .flag("6.0.0"),
      ]))
    }

    // x86_64 iOS simulator
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-apple-ios12.0-simulator",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("ios-simulator"),
        .flag("12.0.0"),
      ]))
    }

    // aarch64 iOS simulator
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "aarch64-apple-ios12.0-simulator",
                                     "foo.swift"])
      let frontendJobs = try driver.planBuild()

      XCTAssertEqual(frontendJobs[1].kind, .link)
      XCTAssertTrue(frontendJobs[1].commandLine.contains(subsequence: [
        .flag("-platform_version"),
        .flag("ios-simulator"),
        .flag("14.0.0"),
      ]))
    }
  }

  func testDSYMGeneration() throws {
    let commonArgs = [
      "swiftc", "foo.swift", "bar.swift",
      "-emit-executable", "-module-name", "Test",
    ]

    do {
      // No dSYM generation (no -g)
      var driver = try Driver(args: commonArgs)
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .generateDSYM })
    }

    do {
      // No dSYM generation (-gnone)
      var driver = try Driver(args: commonArgs + ["-gnone"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .generateDSYM })
    }

    do {
      // dSYM generation (-g)
      var driver = try Driver(args: commonArgs + ["-g"])
      let plannedJobs = try driver.planBuild()

      let generateDSYMJob = plannedJobs.last!
      let cmd = generateDSYMJob.commandLine

      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs.count, 5)
        XCTAssertEqual(generateDSYMJob.outputs.last?.file, try VirtualPath(path: "Test.dSYM"))
      } else {
        XCTAssertEqual(plannedJobs.count, 6)
        XCTAssertFalse(plannedJobs.map { $0.kind }.contains(.generateDSYM))
      }

      XCTAssertTrue(cmd.contains(.path(try VirtualPath(path: "Test"))))
    }
  }

  func testEmitModuleTrace() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-emit-loaded-module-trace", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(
        job.commandLine.contains(subsequence: ["-emit-loaded-module-trace-path",
                                               .path(.relative(.init("foo.trace.json")))])
      )
    }
    do {
      var driver = try Driver(args: ["swiftc", "-typecheck",
                                     "-emit-loaded-module-trace",
                                     "foo.swift, bar.swift", "baz.swift"])
      let plannedJobs = try driver.planBuild()
      let tracedJobs = plannedJobs.filter {
        $0.commandLine.contains(subsequence: ["-emit-loaded-module-trace-path",
                                              .path(.relative(.init("main.trace.json")))])
      }
      XCTAssertEqual(tracedJobs.count, 1)
    }
    do {
      var env = ProcessEnv.vars
      env["SWIFT_LOADED_MODULE_TRACE_FILE"] = "/some/path/to/the.trace.json"
      var driver = try Driver(args: ["swiftc", "-typecheck",
                                     "-emit-loaded-module-trace", "foo.swift"],
                              env: env)
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(
        job.commandLine.contains(subsequence: ["-emit-loaded-module-trace-path",
                                               .path(.absolute(.init("/some/path/to/the.trace.json")))])
      )
    }
  }

  func testVerifyDebugInfo() throws {
    let commonArgs = [
      "swiftc", "foo.swift", "bar.swift",
      "-emit-executable", "-module-name", "Test", "-verify-debug-info"
    ]

    // No dSYM generation (no -g), therefore no verification
    try assertDriverDiagnostics(args: commonArgs) { driver, verifier in
      verifier.expect(.warning("ignoring '-verify-debug-info'; no debug info is being generated"))
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .verifyDebugInfo })
    }

    // No dSYM generation (-gnone), therefore no verification
    try assertDriverDiagnostics(args: commonArgs + ["-gnone"]) { driver, verifier in
      verifier.expect(.warning("ignoring '-verify-debug-info'; no debug info is being generated"))
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)
      XCTAssertFalse(plannedJobs.contains { $0.kind == .verifyDebugInfo })
    }

    do {
      // dSYM generation and verification (-g + -verify-debug-info)
      var driver = try Driver(args: commonArgs + ["-g"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()

      let verifyDebugInfoJob = plannedJobs.last!
      let cmd = verifyDebugInfoJob.commandLine

      if driver.targetTriple.isDarwin {
        XCTAssertEqual(plannedJobs.count, 6)
        XCTAssertEqual(verifyDebugInfoJob.inputs.first?.file, try VirtualPath(path: "Test.dSYM"))
        XCTAssertTrue(cmd.contains(.flag("--verify")))
        XCTAssertTrue(cmd.contains(.flag("--debug-info")))
        XCTAssertTrue(cmd.contains(.flag("--eh-frame")))
        XCTAssertTrue(cmd.contains(.flag("--quiet")))
        XCTAssertTrue(cmd.contains(.path(try VirtualPath(path: "Test.dSYM"))))
      } else {
        XCTAssertEqual(plannedJobs.count, 5)
      }
    }
  }

  func testLEqualPassedDownToLinkerInvocation() throws {
    var driver = try Driver(args: [
      "swiftc", "-working-directory", "/Foo/Bar", "-emit-executable", "test.swift", "-L=.", "-F=."
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.joinedOptionAndPath("-F=", .absolute(.init("/Foo/Bar")))))
    XCTAssertFalse(plannedJobs[0].commandLine.contains(.joinedOptionAndPath("-L=", .absolute(.init("/Foo/Bar")))))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.joinedOptionAndPath("-L=", .absolute(.init("/Foo/Bar")))))
    XCTAssertFalse(plannedJobs[1].commandLine.contains(.joinedOptionAndPath("-F=", .absolute(.init("/Foo/Bar")))))
    // Test implicit output file also honors the working directory.
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "/Foo/Bar/test"))))
  }

  func testWorkingDirectoryForImplicitOutputs() throws {
    var driver = try Driver(args: [
      "swiftc", "-working-directory", "/Foo/Bar", "-emit-executable", "-c", "/tmp/main.swift"
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 1)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/Foo/Bar/main.o"))))
  }

  func testWorkingDirectoryForImplicitModules() throws {
    var driver = try Driver(args: [
      "swiftc", "-working-directory", "/Foo/Bar", "-emit-module", "/tmp/main.swift"
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "/Foo/Bar/main.swiftmodule"))))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-emit-module-doc-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "/Foo/Bar/main.swiftdoc"))))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-emit-module-source-info-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "/Foo/Bar/main.swiftsourceinfo"))))
  }

  func testDOTFileEmission() throws {
    var driver = try Driver(args: [
      "swiftc", "-emit-executable", "test.swift", "-emit-module", "-avoid-emit-module-source-info"
    ])
    let plannedJobs = try driver.planBuild()

    var serializer = DOTJobGraphSerializer(jobs: plannedJobs)
    var output = ""
    serializer.writeDOT(to: &output)

    let dynamicLinker = driver.targetTriple.isDarwin ? "ld" : "clang"
    #if os(Linux)
    XCTAssertEqual(output,
    """
    digraph Jobs {
      "compile (swift-frontend)" [style=bold];
      "test.swift" [fontsize=12];
      "test.swift" -> "compile (swift-frontend)" [color=blue];
      "test.o" [fontsize=12];
      "compile (swift-frontend)" -> "test.o" [color=green];
      "test.swiftmodule" [fontsize=12];
      "compile (swift-frontend)" -> "test.swiftmodule" [color=green];
      "test.swiftdoc" [fontsize=12];
      "compile (swift-frontend)" -> "test.swiftdoc" [color=green];
      "autolinkExtract (swift-autolink-extract)" [style=bold];
      "test.o" -> "autolinkExtract (swift-autolink-extract)" [color=blue];
      "test.autolink" [fontsize=12];
      "autolinkExtract (swift-autolink-extract)" -> "test.autolink" [color=green];
      "mergeModule (swift-frontend)" [style=bold];
      "test.swiftmodule" -> "mergeModule (swift-frontend)" [color=blue];
      "mergeModule (swift-frontend)" -> "test.swiftmodule" [color=green];
      "mergeModule (swift-frontend)" -> "test.swiftdoc" [color=green];
      "link (clang)" [style=bold];
      "test.o" -> "link (clang)" [color=blue];
      "test.autolink" -> "link (clang)" [color=blue];
      "test" [fontsize=12];
      "link (clang)" -> "test" [color=green];
    }

    """)
    #else
    XCTAssertEqual(output,
    """
    digraph Jobs {
      "compile (swift-frontend)" [style=bold];
      "test.swift" [fontsize=12];
      "test.swift" -> "compile (swift-frontend)" [color=blue];
      "test.o" [fontsize=12];
      "compile (swift-frontend)" -> "test.o" [color=green];
      "test.swiftmodule" [fontsize=12];
      "compile (swift-frontend)" -> "test.swiftmodule" [color=green];
      "test.swiftdoc" [fontsize=12];
      "compile (swift-frontend)" -> "test.swiftdoc" [color=green];
      "mergeModule (swift-frontend)" [style=bold];
      "test.swiftmodule" -> "mergeModule (swift-frontend)" [color=blue];
      "mergeModule (swift-frontend)" -> "test.swiftmodule" [color=green];
      "mergeModule (swift-frontend)" -> "test.swiftdoc" [color=green];
      "link (\(dynamicLinker))" [style=bold];
      "test.o" -> "link (\(dynamicLinker))" [color=blue];
      "test" [fontsize=12];
      "link (\(dynamicLinker))" -> "test" [color=green];
    }

    """)
    #endif
  }

  func testRegressions() throws {
    var driverWithEmptySDK = try Driver(args: ["swiftc", "-sdk", "", "file.swift"])
    _ = try driverWithEmptySDK.planBuild()
  }

  func testDumpASTOverride() throws {
    try assertDriverDiagnostics(args: ["swiftc", "-wmo", "-dump-ast", "foo.swift"]) {
      $1.expect(.warning("ignoring '-wmo' because '-dump-ast' was also specified"))
      let jobs = try $0.planBuild()
      XCTAssertEqual(jobs[0].kind, .compile)
      XCTAssertFalse(jobs[0].commandLine.contains("-wmo"))
      XCTAssertTrue(jobs[0].commandLine.contains("-dump-ast"))
    }
    
    try assertDriverDiagnostics(args: ["swiftc", "-index-file", "-dump-ast",
                                       "foo.swift",
                                       "-index-file-path", "foo.swift",
                                       "-index-store-path", "store/path",
                                       "-index-ignore-stdlib", "-index-system-modules",
                                       "-index-ignore-system-modules"]) {
      $1.expect(.warning("ignoring '-index-file' because '-dump-ast' was also specified"))
      let jobs = try $0.planBuild()
      XCTAssertEqual(jobs[0].kind, .compile)
      XCTAssertFalse(jobs[0].commandLine.contains("-wmo"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-file"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-file-path"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-store-path"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-ignore-stdlib"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-system-modules"))
      XCTAssertFalse(jobs[0].commandLine.contains("-index-ignore-system-modules"))
      XCTAssertTrue(jobs[0].commandLine.contains("-dump-ast"))
    }
  }

  func testDeriveSwiftDocPath() throws {
    var driver = try Driver(args: [
      "swiftc", "-emit-module", "/tmp/main.swift", "-emit-module-path", "test-ios-macabi.swiftmodule"
    ])
    let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
    XCTAssertEqual(plannedJobs.count, 2)
    XCTAssertTrue(plannedJobs[1].kind == .mergeModule)
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-o")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "test-ios-macabi.swiftmodule"))))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-emit-module-doc-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "test-ios-macabi.swiftdoc"))))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.flag("-emit-module-source-info-path")))
    XCTAssertTrue(plannedJobs[1].commandLine.contains(.path(try VirtualPath(path: "test-ios-macabi.swiftsourceinfo"))))
  }

  func testToolchainClangPath() throws {
    // Overriding the swift executable to a specific location breaks this.
    guard ProcessEnv.vars["SWIFT_DRIVER_SWIFT_EXEC"] == nil,
          ProcessEnv.vars["SWIFT_DRIVER_SWIFT_FRONTEND_EXEC"] == nil else {
      return
    }
    // TODO: remove this conditional check once DarwinToolchain does not requires xcrun to look for clang.
    var toolchain: Toolchain
    let executor = try SwiftDriverExecutor(diagnosticsEngine: DiagnosticsEngine(),
                                           processSet: ProcessSet(),
                                           fileSystem: localFileSystem,
                                           env: ProcessEnv.vars)
    #if os(macOS)
    toolchain = DarwinToolchain(env: ProcessEnv.vars, executor: executor)
    #else
    toolchain = GenericUnixToolchain(env: ProcessEnv.vars, executor: executor)
    #endif

    XCTAssertEqual(
      try? toolchain.getToolPath(.swiftCompiler).parentDirectory,
      try? toolchain.getToolPath(.clang).parentDirectory
    )
  }

  func testExecutableFallbackPath() throws {
    let driver1 = try Driver(args: ["swift", "main.swift"])
    if !driver1.targetTriple.isDarwin {
      XCTAssertThrowsError(try driver1.toolchain.getToolPath(.dsymutil))
    }

    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
    let driver2 = try Driver(args: ["swift", "main.swift"], env: env)
    XCTAssertNoThrow(try driver2.toolchain.getToolPath(.dsymutil))
  }

  func testVersionRequest() throws {
    for arg in ["-version", "--version"] {
      var driver = try Driver(args: ["swift"] + [arg])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .versionRequest)
      XCTAssertEqual(job.commandLine, [.flag("--version")])
    }
  }

  func testNoInputs() throws {
    // A plain `swift` invocation requires lldb to be present
    if try testEnvHasLLDB() {
      do {
        var driver = try Driver(args: ["swift"])
        XCTAssertNoThrow(try driver.planBuild())
      }
    }
    do {
      var driver = try Driver(args: ["swiftc"])
      XCTAssertThrowsError(try driver.planBuild()) {
        XCTAssertEqual($0 as? Driver.Error, .noInputFiles)
      }
    }
    do {
      var driver = try Driver(args: ["swiftc", "-v"])
      XCTAssertNoThrow(try driver.planBuild())
    }
    do {
      var driver = try Driver(args: ["swiftc", "-v", "-whole-module-optimization"])
      XCTAssertNoThrow(try driver.planBuild())
    }
    do {
      var driver = try Driver(args: ["swiftc", "-whole-module-optimization"])
      XCTAssertThrowsError(try driver.planBuild()) {
        XCTAssertEqual($0 as? Driver.Error, .noInputFiles)
      }
    }
  }

  func testPrintTargetInfo() throws {
    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "arm64-apple-ios12.0", "-sdk", "bar", "-resource-dir", "baz"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-sdk")))
      XCTAssertTrue(job.commandLine.contains(.flag("-resource-dir")))
    }

    do {
      struct MockExecutor: DriverExecutor {
        let resolver: ArgsResolver
        
        func execute(job: Job, forceResponseFiles: Bool, recordedInputModificationDates: [TypedVirtualPath : Date]) throws -> ProcessResult {
          return ProcessResult(arguments: [], environment: [:], exitStatus: .terminated(code: 0), output: .success(Array("bad JSON".utf8)), stderrOutput: .success([]))
        }
        func execute(jobs: [Job], delegate: JobExecutionDelegate, numParallelJobs: Int, forceResponseFiles: Bool, recordedInputModificationDates: [TypedVirtualPath : Date]) throws {
          fatalError()
        }
        func checkNonZeroExit(args: String..., environment: [String : String]) throws -> String {
          return try Process.checkNonZeroExit(arguments: args, environment: environment)
        }
        func description(of job: Job, forceResponseFiles: Bool) throws -> String {
          fatalError()
        }
      }

      XCTAssertThrowsError(try Driver(args: ["swift", "-print-target-info"],
                                      executor: MockExecutor(resolver: ArgsResolver(fileSystem: InMemoryFileSystem())))) {
        error in
        if case .unableToDecodeFrontendTargetInfo = error as? Driver.Error {}
        else {
          XCTFail("not a decoding error")
        }
      }
    }

    do {
      XCTAssertThrowsError(try Driver(args: ["swift", "-print-target-info"],
                                      env: ["SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": "/bad/path/to/swift-frontend"])) {
        error in
        XCTAssertEqual(error as? Driver.Error, .failedToRetrieveFrontendTargetInfo)
      }
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-apple-ios13.0-macabi", "-target-variant", "x86_64-apple-macosx10.14", "-sdk", "bar", "-resource-dir", "baz"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target-variant")))
      XCTAssertTrue(job.commandLine.contains(.flag("-sdk")))
      XCTAssertTrue(job.commandLine.contains(.flag("-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-unknown-linux"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-unknown-linux", "-static-stdlib"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swift", "-print-target-info", "-target", "x86_64-unknown-linux", "-static-executable"])
      let plannedJobs = try driver.planBuild()
      XCTAssertTrue(plannedJobs.count == 1)
      let job = plannedJobs[0]
      XCTAssertEqual(job.kind, .printTargetInfo)
      XCTAssertTrue(job.commandLine.contains(.flag("-print-target-info")))
      XCTAssertTrue(job.commandLine.contains(.flag("-target")))
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }
  }

  func testPrintOutputFileMap() throws {
    try withTemporaryDirectory { path in
      // Replace the error stream with one we capture here.
      let errorStream = stderrStream
      let errorOutputFile = path.appending(component: "dummy_error_stream")
      TSCBasic.stderrStream = try! ThreadSafeOutputByteStream(LocalFileOutputByteStream(errorOutputFile))

      let dummyInput = path.appending(component: "output_file_map_test.swift")
      let outputFileMap = path.appending(component: "output_file_map.json")
      let fileMap = "{\"\(dummyInput.description)\": {\"object\": \"/build/basic_output_file_map.o\"}, \"\(path)/Inputs/main.swift\": {\"object\": \"/build/main.o\"}, \"\(path)/Inputs/lib.swift\": {\"object\": \"/build/lib.o\"}}"
      try localFileSystem.writeFileContents(outputFileMap) { $0 <<< fileMap }
      var driver = try Driver(args: ["swiftc", "-driver-print-output-file-map",
                                     "-target", "x86_64-apple-macosx10.9",
                                     "-o", "/build/basic_output_file_map.out",
                                     "-module-name", "OutputFileMap",
                                     "-output-file-map", outputFileMap.description])
      try driver.run(jobs: [])
      let invocationError = try localFileSystem.readFileContents(errorOutputFile).description
      XCTAssertTrue(invocationError.contains("/Inputs/lib.swift -> object: \"/build/lib.o\""))
      XCTAssertTrue(invocationError.contains("/Inputs/main.swift -> object: \"/build/main.o\""))
      XCTAssertTrue(invocationError.contains("/output_file_map_test.swift -> object: \"/build/basic_output_file_map.o\""))

      // Restore the error stream to what it was
      TSCBasic.stderrStream = errorStream
    }
  }

  func testDiagnosticOptions() throws {
    do {
      var driver = try Driver(args: ["swift", "-no-warnings-as-errors", "-warnings-as-errors", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-warnings-as-errors")))
    }

    do {
      var driver = try Driver(args: ["swift", "-warnings-as-errors", "-no-warnings-as-errors", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-no-warnings-as-errors")))
    }

    do {
      var driver = try Driver(args: ["swift", "-warnings-as-errors", "-no-warnings-as-errors", "-suppress-warnings", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-no-warnings-as-errors")))
      XCTAssertTrue(job.commandLine.contains(.flag("-suppress-warnings")))
    }

    do {
      try assertDriverDiagnostics(args: ["swift", "-no-warnings-as-errors", "-warnings-as-errors", "-suppress-warnings", "foo.swift"]) {
        $1.expect(.error(Driver.Error.conflictingOptions(.warningsAsErrors, .suppressWarnings)))
      }
    }

    do {
      var driver = try Driver(args: ["swift", "-print-educational-notes", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-print-educational-notes")))
    }
  }

  func testNumThreads() throws {
    XCTAssertEqual(try Driver(args: ["swiftc"]).numThreads, 0)

    XCTAssertEqual(try Driver(args: ["swiftc", "-num-threads", "4"]).numThreads, 4)

    XCTAssertEqual(try Driver(args: ["swiftc", "-num-threads", "0"]).numThreads, 0)

    try assertDriverDiagnostics(args: ["swift", "-num-threads", "-1"]) { driver, verify in
      verify.expect(.error("invalid value '-1' in '-num-threads'"))
      XCTAssertEqual(driver.numThreads, 0)
    }

    try assertDriverDiagnostics(args: "swiftc", "-enable-batch-mode", "-num-threads", "4") { driver, verify in
      verify.expect(.warning("ignoring -num-threads argument; cannot multithread batch mode"))
      XCTAssertEqual(driver.numThreads, 0)
    }
  }

  func testLTOOption() throws {
    XCTAssertEqual(try Driver(args: ["swiftc"]).lto, nil)

    XCTAssertEqual(try Driver(args: ["swiftc", "-lto=llvm-thin"]).lto, .llvmThin)

    XCTAssertEqual(try Driver(args: ["swiftc", "-lto=llvm-full"]).lto, .llvmFull)

    try assertDriverDiagnostics(args: ["swiftc", "-lto=nop"]) { driver, verify in
      verify.expect(.error("invalid value 'nop' in '-lto='"))
    }
  }

  func testLTOOutputs() throws {
    let targets = ["x86_64-unknown-linux-gnu", "x86_64-apple-macosx10.9"]
    for target in targets {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-lto=llvm-thin", "-target", target])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-bc")))
      XCTAssertEqual(plannedJobs[0].outputs.first!.file, VirtualPath.temporary(RelativePath("foo.bc")))
      XCTAssertEqual(plannedJobs[1].inputs.first!.file, VirtualPath.temporary(RelativePath("foo.bc")))
    }
  }

  func testBCasTopLevelOutput() throws {
    var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-bc", "-target", "x86_64-apple-macosx10.9"])
    let plannedJobs = try driver.planBuild()
    XCTAssertEqual(plannedJobs.count, 1)
    print(plannedJobs[0].commandLine.description)
    XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-bc")))
    XCTAssertEqual(plannedJobs[0].outputs.first!.file, VirtualPath.relative(RelativePath("foo.bc")))
  }

  func testScanDependenciesOption() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-scan-dependencies", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-scan-dependencies")))
    }

    // Test .d output
    do {
      var driver = try Driver(args: ["swiftc", "-scan-dependencies",
                                     "-emit-dependencies", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-scan-dependencies")))
      XCTAssertTrue(job.commandLine.contains(.flag("-emit-dependencies-path")))
      XCTAssertTrue(job.commandLine.contains(.path(.temporary(RelativePath("foo.d")))))
    }
  }

  func testVerifyEmittedInterfaceJob() throws {
    // Evolution enabled
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface",
                                     "-verify-emitted-module-interface",
                                     "-enable-library-evolution"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)
      let compileJob = plannedJobs[0]
      let mergeJob = plannedJobs[1]
      let verifyJob = plannedJobs[2]
      XCTAssertEqual(compileJob.kind, .compile)
      XCTAssertEqual(mergeJob.kind, .mergeModule)
      let mergeInterfaceOutputs = mergeJob.outputs.filter { $0.type == .swiftInterface }
      XCTAssertTrue(mergeInterfaceOutputs.count == 1,
                    "Merge module job should only have one swiftinterface output")
      XCTAssertEqual(verifyJob.kind, .verifyModuleInterface)
      XCTAssertTrue(verifyJob.inputs.count == 1)
      XCTAssertTrue(verifyJob.inputs[0] == mergeInterfaceOutputs[0])
      XCTAssertTrue(verifyJob.commandLine.contains(.path(mergeInterfaceOutputs[0].file)))
    }
    // No Evolution
    do {
      var driver = try Driver(args: ["swiftc", "foo.swift", "-emit-module", "-module-name",
                                     "foo", "-emit-module-interface", "-verify-emitted-module-interface"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)
    }
  }

  func testPCHGeneration() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("TestInputHeader.pch")))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-o")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(.temporary(RelativePath("TestInputHeader.pch")))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-import-objc-header")))
      XCTAssert(plannedJobs[1].commandLine.contains(.path(.temporary(RelativePath("TestInputHeader.pch")))))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-index-store-path", "idx", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("TestInputHeader.pch")))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-index-store-path")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "idx"))))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-o")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(.temporary(RelativePath("TestInputHeader.pch")))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, try VirtualPath(path: "/pch/TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "-embed-bitcode", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, try VirtualPath(path: "/pch/TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .temporary(RelativePath("foo.bc")))

      XCTAssertEqual(plannedJobs[2].kind, .backend)
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
      XCTAssertFalse(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-disable-bridging-pch", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-whole-module-optimization", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
      XCTAssertFalse(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-serialize-diagnostics", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 2)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("TestInputHeader.dia")))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .diagnostics)
      XCTAssertEqual(plannedJobs[0].outputs[1].file, try VirtualPath(path: "/pch/TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[1].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-serialize-diagnostics-path")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(.temporary(RelativePath("TestInputHeader.dia")))))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-serialize-diagnostics", "foo.swift", "-emit-module", "-emit-module-path", "/module-path-dir"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 2)
      XCTAssertNotNil(plannedJobs[0].outputs[0].file.name.range(of: #"/pch/TestInputHeader-.*.dia"#, options: .regularExpression))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .diagnostics)
      XCTAssertEqual(plannedJobs[0].outputs[1].file, try VirtualPath(path: "/pch/TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[1].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-serialize-diagnostics-path")))
      XCTAssert(plannedJobs[0].commandLine.contains {
        guard case .path(let path) = $0 else { return false }
        return path.name.range(of: #"/pch/TestInputHeader-.*.dia"#, options: .regularExpression) != nil
      })
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssert(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))

      // FIXME: validate that merge module is correct job and that it has correct inputs and flags
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-import-objc-header", "TestInputHeader.h", "-pch-output-dir", "/pch", "-whole-module-optimization", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, try VirtualPath(path: "/pch/TestInputHeader.pch"))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-pch-output-dir")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(try VirtualPath(path: "/pch"))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
      XCTAssertFalse(plannedJobs[1].commandLine.contains(.flag("-pch-disable-validation")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "-O", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("TestInputHeader.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("TestInputHeader.pch")))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-O")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-frontend")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-o")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(.temporary(RelativePath("TestInputHeader.pch")))))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertEqual(plannedJobs[1].inputs.count, 2)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, try VirtualPath(path: "foo.swift"))
    }

    // Ensure the merge-module step is not passed the precompiled header
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-import-objc-header", "header.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .generatePCH)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("header.h")))
      XCTAssertEqual(plannedJobs[0].inputs[0].type, .objcHeader)
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("header.pch")))
      XCTAssertEqual(plannedJobs[0].outputs[0].type, .pch)
      XCTAssertTrue(plannedJobs[0].commandLine.contains(.flag("-emit-pch")))
      XCTAssertTrue(plannedJobs[0].commandLine.contains(subsequence: ["-o", .path(.temporary(RelativePath("header.pch")))]))

      XCTAssertEqual(plannedJobs[1].kind, .compile)
      XCTAssertTrue(plannedJobs[1].commandLine.contains(subsequence:
                                                          ["-import-objc-header",
                                                           .path(.temporary(RelativePath("header.pch")))]))

      XCTAssertEqual(plannedJobs[2].kind, .mergeModule)
      XCTAssertTrue(plannedJobs[2].commandLine.contains(subsequence:
                                                          ["-import-objc-header",
                                                           .path(.relative(RelativePath("header.h")))]))
    }

    // Immediate mode doesn't generate a pch
    do {
      var driver = try Driver(args: ["swift", "-import-objc-header", "TestInputHeader.h", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .interpret)
      XCTAssert(plannedJobs[0].commandLine.contains(.flag("-import-objc-header")))
      XCTAssert(plannedJobs[0].commandLine.contains(.path(.relative(RelativePath("TestInputHeader.h")))))
    }
  }

  func testPCMGeneration() throws {
     do {
       var driver = try Driver(args: ["swiftc", "-emit-pcm", "module.modulemap", "-module-name", "Test"])
       let plannedJobs = try driver.planBuild()
       XCTAssertEqual(plannedJobs.count, 1)

       XCTAssertEqual(plannedJobs[0].kind, .generatePCM)
       XCTAssertEqual(plannedJobs[0].inputs.count, 1)
       XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("module.modulemap")))
       XCTAssertEqual(plannedJobs[0].outputs.count, 1)
       XCTAssertEqual(plannedJobs[0].outputs[0].file, .relative(RelativePath("Test.pcm")))
    }
  }

  func testIndexFilePathHandling() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-index-file", "-index-file-path",
                                     "bar.swift", "foo.swift", "bar.swift", "baz.swift"])
      let plannedJobs = try driver.planBuild()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(subsequence: [.path(.relative(.init("foo.swift"))),
                                                           "-primary-file",
                                                           .path(.relative(.init("bar.swift"))),
                                                           .path(.relative(.init("baz.swift")))]))
    }
  }

  func testEmbedBitcode() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "embed-bitcode.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("embed-bitcode.bc")))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, .temporary(RelativePath("embed-bitcode.bc")))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .temporary(RelativePath("embed-bitcode.o")))

      XCTAssertEqual(plannedJobs[2].kind, .link)
      XCTAssertEqual(plannedJobs[2].outputs.count, 1)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("embed-bitcode")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "main.swift", "hi.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 5)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 2)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[0].inputs[1].file, .relative(RelativePath("hi.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("main.bc")))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, .temporary(RelativePath("main.bc")))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .temporary(RelativePath("main.o")))

      XCTAssertEqual(plannedJobs[2].kind, .compile)
      XCTAssertEqual(plannedJobs[2].inputs.count, 2)
      XCTAssertEqual(plannedJobs[2].inputs[0].file, .relative(RelativePath("main.swift")))
      XCTAssertEqual(plannedJobs[2].inputs[1].file, .relative(RelativePath("hi.swift")))
      XCTAssertEqual(plannedJobs[2].outputs.count, 1)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .temporary(RelativePath("hi.bc")))

      XCTAssertEqual(plannedJobs[3].kind, .backend)
      XCTAssertEqual(plannedJobs[3].inputs.count, 1)
      XCTAssertEqual(plannedJobs[3].inputs[0].file, .temporary(RelativePath("hi.bc")))
      XCTAssertEqual(plannedJobs[3].outputs.count, 1)
      XCTAssertEqual(plannedJobs[3].outputs[0].file, .temporary(RelativePath("hi.o")))

      XCTAssertEqual(plannedJobs[4].kind, .link)
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-c", "-emit-module", "embed-bitcode.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 4)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("embed-bitcode.bc")))
      XCTAssertEqual(plannedJobs[0].outputs[1].file, .temporary(RelativePath("embed-bitcode.swiftmodule")))
      XCTAssertEqual(plannedJobs[0].outputs[2].file, .temporary(RelativePath("embed-bitcode.swiftdoc")))
      XCTAssertEqual(plannedJobs[0].outputs[3].file, .temporary(RelativePath("embed-bitcode.swiftsourceinfo")))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, .temporary(RelativePath("embed-bitcode.bc")))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .relative(RelativePath("embed-bitcode.o")))

      XCTAssertEqual(plannedJobs[2].kind, .mergeModule)
      XCTAssertEqual(plannedJobs[2].inputs.count, 1)
      XCTAssertEqual(plannedJobs[2].inputs[0].file, .temporary(RelativePath("embed-bitcode.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs.count, 3)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("main.swiftmodule")))
      XCTAssertEqual(plannedJobs[2].outputs[1].file, .relative(RelativePath("main.swiftdoc")))
      XCTAssertEqual(plannedJobs[2].outputs[2].file, .relative(RelativePath("main.swiftsourceinfo")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-wmo", "embed-bitcode.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 3)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 1)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("main.bc")))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, .temporary(RelativePath("main.bc")))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .temporary(RelativePath("main.o")))

      XCTAssertEqual(plannedJobs[2].kind, .link)
      XCTAssertEqual(plannedJobs[2].outputs.count, 1)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .relative(RelativePath("embed-bitcode")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-c", "-parse-as-library", "-emit-module",  "embed-bitcode.swift", "empty.swift", "-module-name", "ABC"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 5)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].outputs.count, 4)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("embed-bitcode.bc")))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, .temporary(RelativePath("embed-bitcode.bc")))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .relative(RelativePath("embed-bitcode.o")))

      XCTAssertEqual(plannedJobs[2].kind, .compile)
      XCTAssertEqual(plannedJobs[2].outputs.count, 4)
      XCTAssertEqual(plannedJobs[2].outputs[0].file, .temporary(RelativePath("empty.bc")))

      XCTAssertEqual(plannedJobs[3].kind, .backend)
      XCTAssertEqual(plannedJobs[3].inputs.count, 1)
      XCTAssertEqual(plannedJobs[3].inputs[0].file, .temporary(RelativePath("empty.bc")))
      XCTAssertEqual(plannedJobs[3].outputs.count, 1)
      XCTAssertEqual(plannedJobs[3].outputs[0].file, .relative(RelativePath("empty.o")))

      XCTAssertEqual(plannedJobs[4].kind, .mergeModule)
      XCTAssertEqual(plannedJobs[4].inputs.count, 2)
      XCTAssertEqual(plannedJobs[4].inputs[0].file, .temporary(RelativePath("embed-bitcode.swiftmodule")))
      XCTAssertEqual(plannedJobs[4].inputs[1].file, .temporary(RelativePath("empty.swiftmodule")))
      XCTAssertEqual(plannedJobs[4].outputs.count, 3)
      XCTAssertEqual(plannedJobs[4].outputs[0].file, .relative(RelativePath("ABC.swiftmodule")))
      XCTAssertEqual(plannedJobs[4].outputs[1].file, .relative(RelativePath("ABC.swiftdoc")))
      XCTAssertEqual(plannedJobs[4].outputs[2].file, .relative(RelativePath("ABC.swiftsourceinfo")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-embed-bitcode", "-c", "-parse-as-library", "-emit-module", "-whole-module-optimization", "embed-bitcode.swift", "-parse-stdlib", "-module-name", "Swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)

      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssertEqual(plannedJobs[0].inputs.count, 1)
      XCTAssertEqual(plannedJobs[0].inputs[0].file, .relative(RelativePath("embed-bitcode.swift")))
      XCTAssertEqual(plannedJobs[0].outputs.count, 4)
      XCTAssertEqual(plannedJobs[0].outputs[0].file, .temporary(RelativePath("Swift.bc")))

      XCTAssertEqual(plannedJobs[1].kind, .backend)
      XCTAssertEqual(plannedJobs[1].inputs.count, 1)
      XCTAssertEqual(plannedJobs[1].inputs[0].file, .temporary(RelativePath("Swift.bc")))
      XCTAssertEqual(plannedJobs[1].outputs.count, 1)
      XCTAssertEqual(plannedJobs[1].outputs[0].file, .relative(RelativePath("Swift.o")))
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-module", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-module-path", "a.swiftmodule",  "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-sib", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-sibgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-sil", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-silgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-ir", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-bc", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode", "-emit-assembly", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-module", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-module-path", "a.swiftmodule",  "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-sib", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-sibgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-sil", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-silgen", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-ir", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-bc", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }

    try assertDriverDiagnostics(args: ["swiftc", "-embed-bitcode-marker", "-emit-assembly", "embed-bitcode.swift"]) { driver, verify in
      verify.expect(.warning("ignoring -embed-bitcode-marker since no object file is being generated"))
      let plannedJobs = try driver.planBuild()

      for job in plannedJobs {
        XCTAssertFalse(job.commandLine.contains(.flag("-embed-bitcode-marker")))
      }
    }
  }

  func testCXXInteropOptions() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-enable-experimental-cxx-interop", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      let compileJob = plannedJobs[0]
      let linkJob = plannedJobs[1]
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-enable-cxx-interop")))
      if driver.targetTriple.isDarwin {
        XCTAssertTrue(linkJob.commandLine.contains(.flag("-lc++")))
      }
    }
    do {
      var driver = try Driver(args: ["swiftc", "-enable-experimental-cxx-interop",
                                     "-experimental-cxx-stdlib", "libc++", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 2)
      let compileJob = plannedJobs[0]
      let linkJob = plannedJobs[1]
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-enable-cxx-interop")))
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-stdlib=libc++")))
      if driver.targetTriple.isDarwin {
        XCTAssertTrue(linkJob.commandLine.contains(.flag("-lc++")))
      }
    }
  }

  func testVFSOverlay() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-c", "-vfsoverlay", "overlay.yaml", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(subsequence: [.flag("-vfsoverlay"), .path(.relative(RelativePath("overlay.yaml")))]))
    }

    // Verify that the overlays are passed to the frontend in the same order.
    do {
      var driver = try Driver(args: ["swiftc", "-c", "-vfsoverlay", "overlay1.yaml", "-vfsoverlay", "overlay2.yaml", "-vfsoverlay", "overlay3.yaml", "foo.swift"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      XCTAssertEqual(plannedJobs.count, 1)
      XCTAssertEqual(plannedJobs[0].kind, .compile)
      XCTAssert(plannedJobs[0].commandLine.contains(subsequence: [.flag("-vfsoverlay"), .path(.relative(RelativePath("overlay1.yaml"))), .flag("-vfsoverlay"), .path(.relative(RelativePath("overlay2.yaml"))), .flag("-vfsoverlay"), .path(.relative(RelativePath("overlay3.yaml")))]))
    }
  }

  func testSwiftHelpOverride() throws {
    // FIXME: On Linux, we might not have any Clang in the path. We need a
    // better override.
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_SWIFT_HELP_EXEC"] = "/usr/bin/nonexistent-swift-help"
    env["SWIFT_DRIVER_CLANG_EXEC"] = "/usr/bin/clang"
    var driver = try Driver(
      args: ["swiftc", "-help"],
      env: env)
    let jobs = try driver.planBuild()
    XCTAssert(jobs.count == 1)
    XCTAssertEqual(jobs.first!.tool.name, "/usr/bin/nonexistent-swift-help")
  }
  
  func testSourceInfoFileEmitOption() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module-source-info", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let compileJob = plannedJobs[0]
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-emit-module-source-info-path")))
      XCTAssertEqual(compileJob.outputs.count, 2)
      XCTAssertEqual(compileJob.outputs[0].file, .temporary(RelativePath("foo.o")))
      XCTAssertEqual(compileJob.outputs[1].file, .temporary(RelativePath("foo.swiftsourceinfo")))
    }
    // implicit
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let compileJob = plannedJobs[0]
      XCTAssertTrue(compileJob.commandLine.contains(.flag("-emit-module-source-info-path")))
      XCTAssertEqual(compileJob.outputs.count, 3)
      XCTAssertEqual(compileJob.outputs[0].file, .temporary(RelativePath("foo.swiftmodule")))
      XCTAssertEqual(compileJob.outputs[1].file, .temporary(RelativePath("foo.swiftdoc")))
      XCTAssertEqual(compileJob.outputs[2].file, .temporary(RelativePath("foo.swiftsourceinfo")))
    }
    // implicit with Project/ Directory
    do {
      try withTemporaryDirectory { path in
        let projectDirPath = path.appending(component: "Project")
        try localFileSystem.createDirectory(projectDirPath)
        var driver = try Driver(args: ["swiftc", "-emit-module",
                                       path.appending(component: "foo.swift").description,
                                       "-o", path.appending(component: "foo.swiftmodule").description])
        let plannedJobs = try driver.planBuild()
        let mergeModuleJob = plannedJobs[1]
        XCTAssertTrue(mergeModuleJob.commandLine.contains(.flag("-emit-module-source-info-path")))
        XCTAssertEqual(mergeModuleJob.outputs.count, 3)
        XCTAssertEqual(mergeModuleJob.outputs[0].file, .absolute(path.appending(component: "foo.swiftmodule")))
        XCTAssertEqual(mergeModuleJob.outputs[1].file, .absolute(path.appending(component: "foo.swiftdoc")))
        XCTAssertEqual(mergeModuleJob.outputs[2].file, .absolute(projectDirPath.appending(component: "foo.swiftsourceinfo")))
      }
    }
    // avoid implicit swiftsourceinfo
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-avoid-emit-module-source-info", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let compileJob = plannedJobs[0]
      XCTAssertFalse(compileJob.commandLine.contains(.flag("-emit-module-source-info-path")))
      XCTAssertEqual(compileJob.outputs.count, 2)
      XCTAssertEqual(compileJob.outputs[0].file, .temporary(RelativePath("foo.swiftmodule")))
      XCTAssertEqual(compileJob.outputs[1].file, .temporary(RelativePath("foo.swiftdoc")))
    }
  }

  func testUseStaticResourceDir() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-no-static-executable", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-no-static-stdlib", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertFalse(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-static-executable", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", "x86_64-unknown-linux", "-static-stdlib", "foo.swift"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.flag("-use-static-resource-dir")))
    }
  }

  func testFrontendTargetInfoWithWorkingDirectory() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-typecheck", "foo.swift",
                                     "-resource-dir", "resource/dir",
                                     "-sdk", "sdk",
                                     "-working-directory", "/absolute/path"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      XCTAssertTrue(job.commandLine.contains(.path(.absolute(.init("/absolute/path/resource/dir")))))
      XCTAssertFalse(job.commandLine.contains(.path(.relative(.init("resource/dir")))))
      XCTAssertTrue(job.commandLine.contains(.path(.absolute(.init("/absolute/path/sdk")))))
      XCTAssertFalse(job.commandLine.contains(.path(.relative(.init("sdk")))))
    }
  }

  func testRelativeResourceDir() throws {
    do {
      var driver = try Driver(args: ["swiftc",
                                     "-target", "x86_64-unknown-linux", "-lto=llvm-thin",
                                     "foo.swift",
                                     "-resource-dir", "resource/dir"])
      let plannedJobs = try driver.planBuild().removingAutolinkExtractJobs()
      let compileJob = plannedJobs[0]
      XCTAssertEqual(compileJob.kind, .compile)
      XCTAssertTrue(compileJob.commandLine.contains(subsequence: ["-resource-dir", .path(.relative(.init("resource/dir")))]))
      let linkJob = plannedJobs[1]
      XCTAssertEqual(linkJob.kind, .link)
      XCTAssertTrue(linkJob.commandLine.contains(subsequence:
                                              ["-Xlinker", "-rpath",
                                               "-Xlinker", .path(.relative(.init("resource/dir/linux")))]))
      XCTAssertTrue(linkJob.commandLine.contains(.path(.relative(.init("resource/dir/linux/x86_64/swiftrt.o")))))
      XCTAssertTrue(linkJob.commandLine.contains(subsequence:
                                              ["-L", .path(.relative(.init("resource/dir/linux")))]))
    }
  }

  func testSanitizerArgsForTargets() throws {
    let targets = ["x86_64-unknown-freebsd",  "x86_64-unknown-linux", "x86_64-apple-macosx10.9"]
    try targets.forEach {
      var driver = try Driver(args: ["swiftc", "-emit-module", "-target", $0, "foo.swift"])
      _ = try driver.planBuild()
      XCTAssertFalse(driver.diagnosticEngine.hasErrors)
    }
  }

  func testFilelist() throws {
    do {
      var driver = try Driver(args: ["swiftc", "-emit-module", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0"])
      let plannedJobs = try driver.planBuild()

      let jobA = plannedJobs[0]
      let flagA = jobA.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentA = jobA.commandLine[jobA.commandLine.index(after: flagA)]
      guard case let .path(.fileList(_, fileListA)) = fileListArgumentA else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapA) = fileListA else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      let filesA = try XCTUnwrap(mapA.entries[.relative(RelativePath("a.swift"))])
      XCTAssertTrue(filesA.keys.contains(.swiftModule))
      XCTAssertTrue(filesA.keys.contains(.swiftDocumentation))
      XCTAssertTrue(filesA.keys.contains(.swiftSourceInfoFile))

      let jobB = plannedJobs[1]
      let flagB = jobB.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentB = jobB.commandLine[jobB.commandLine.index(after: flagB)]
      guard case let .path(.fileList(_, fileListB)) = fileListArgumentB else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapB) = fileListB else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      let filesB = try XCTUnwrap(mapB.entries[.relative(RelativePath("b.swift"))])
      XCTAssertTrue(filesB.keys.contains(.swiftModule))
      XCTAssertTrue(filesB.keys.contains(.swiftDocumentation))
      XCTAssertTrue(filesB.keys.contains(.swiftSourceInfoFile))

      let jobC = plannedJobs[2]
      let flagC = jobC.commandLine.firstIndex(of: .flag("-supplementary-output-file-map"))!
      let fileListArgumentC = jobC.commandLine[jobC.commandLine.index(after: flagC)]
      guard case let .path(.fileList(_, fileListC)) = fileListArgumentC else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .outputFileMap(mapC) = fileListC else {
        XCTFail("FileList wasn't OutputFileMap")
        return
      }
      let filesC = try XCTUnwrap(mapC.entries[.relative(RelativePath("c.swift"))])
      XCTAssertTrue(filesC.keys.contains(.swiftModule))
      XCTAssertTrue(filesC.keys.contains(.swiftDocumentation))
      XCTAssertTrue(filesC.keys.contains(.swiftSourceInfoFile))
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      let inputsFlag = job.commandLine.firstIndex(of: .flag("-filelist"))!
      let inputFileListArgument = job.commandLine[job.commandLine.index(after: inputsFlag)]
      guard case let .path(.fileList(_, inputFileList)) = inputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(inputs) = inputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(inputs, [.relative(RelativePath("a.swift")), .relative(RelativePath("b.swift")), .relative(RelativePath("c.swift"))])

      let outputsFlag = job.commandLine.firstIndex(of: .flag("-output-filelist"))!
      let outputFileListArgument = job.commandLine[job.commandLine.index(after: outputsFlag)]
      guard case let .path(.fileList(_, outputFileList)) = outputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(outputs) = outputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(outputs, [.relative(RelativePath("main.o"))])
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization", "-num-threads", "1"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      let outputsFlag = job.commandLine.firstIndex(of: .flag("-output-filelist"))!
      let outputFileListArgument = job.commandLine[job.commandLine.index(after: outputsFlag)]
      guard case let .path(.fileList(_, outputFileList)) = outputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(outputs) = outputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(outputs, [.relative(RelativePath("a.o")), .relative(RelativePath("b.o")), .relative(RelativePath("c.o"))])
    }

    do {
      var driver = try Driver(args: ["swiftc", "-c", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization", "-num-threads", "1", "-embed-bitcode"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[0]
      let outputsFlag = job.commandLine.firstIndex(of: .flag("-output-filelist"))!
      let outputFileListArgument = job.commandLine[job.commandLine.index(after: outputsFlag)]
      guard case let .path(.fileList(_, outputFileList)) = outputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(outputs) = outputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(outputs, [.temporary(RelativePath("a.bc")), .temporary(RelativePath("b.bc")), .temporary(RelativePath("c.bc"))])
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-library", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[3]
      let inputsFlag = job.commandLine.firstIndex(of: .flag("-filelist"))!
      let inputFileListArgument = job.commandLine[job.commandLine.index(after: inputsFlag)]
      guard case let .path(.fileList(_, inputFileList)) = inputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(inputs) = inputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(inputs, [.temporary(RelativePath("a.o")), .temporary(RelativePath("b.o")), .temporary(RelativePath("c.o"))])
    }

    do {
      var driver = try Driver(args: ["swiftc", "-emit-library", "./a.swift", "./b.swift", "./c.swift", "-module-name", "main", "-target", "x86_64-apple-macosx10.9", "-driver-filelist-threshold=0", "-whole-module-optimization", "-num-threads", "1"])
      let plannedJobs = try driver.planBuild()
      let job = plannedJobs[1]
      let inputsFlag = job.commandLine.firstIndex(of: .flag("-filelist"))!
      let inputFileListArgument = job.commandLine[job.commandLine.index(after: inputsFlag)]
      guard case let .path(.fileList(_, inputFileList)) = inputFileListArgument else {
        XCTFail("Argument wasn't a filelist")
        return
      }
      guard case let .list(inputs) = inputFileList else {
        XCTFail("FileList wasn't List")
        return
      }
      XCTAssertEqual(inputs, [.temporary(RelativePath("a.o")), .temporary(RelativePath("b.o")), .temporary(RelativePath("c.o"))])
    }
  }
}

func assertString(
  _ haystack: String, contains needle: String, _ message: String = "",
  file: StaticString = #file, line: UInt = #line
) {
  XCTAssertTrue(haystack.contains(needle), """
                \(String(reflecting: needle)) not found in \
                \(String(reflecting: haystack))\
                \(message.isEmpty ? "" : ": " + message)
                """, file: file, line: line)
}

fileprivate extension Array where Element: Equatable {
  /// Returns true if the receiver contains the given elements as a subsequence
  /// (i.e., all elements are present, contiguous, and in the same order).
  ///
  /// A naïve implementation has been used here rather than a more efficient
  /// general purpose substring search algorithm since the arrays being tested
  /// are relatively small.
  func contains<Elements: Collection>(
    subsequence: Elements
  ) -> Bool
  where Elements.Element == Element
  {
    precondition(!subsequence.isEmpty,  "Subsequence may not be empty")

    let subsequenceCount = subsequence.count
    for index in 0...(self.count - subsequence.count) {
      let subsequenceEnd = index + subsequenceCount
      if self[index..<subsequenceEnd].elementsEqual(subsequence) {
        return true
      }
    }
    return false
  }
}

fileprivate extension Array
where Element == Job
{
  // Utility to drop autolink-extract jobs, which helps avoid introducing
  // platform-specific conditionals in tests unrelated to autolinking.
  func removingAutolinkExtractJobs() -> Self {
    var filtered = self
    filtered.removeAll(where: { $0.kind == .autolinkExtract })
    return filtered
  }
}
