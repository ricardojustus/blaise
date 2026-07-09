import Foundation
import Testing

@testable import BlaiseCore

// MARK: - #100 Part A — dominant-language detection seam (the REAL bundled
// driver script, pure-logic only).
//
// Each test spawns /usr/bin/python3 (NOT the research venv), imports the
// bundled whisper_driver.py via importlib, and CALLS one of the three pure
// stdlib functions (candidate_detection_starts / select_detection_windows /
// detect_dominant_language) with literal Python lists. The call SUCCEEDING
// under a bare system python3 IS the numpy-free guard: those functions must
// never touch numpy/mlx (those imports are deferred into main()'s
// `language is None` branch). Mirrors WhisperDriverLanguageClampTests.

@Suite struct WhisperDriverLanguageDetectTests {
    /// Imports the bundled driver as a module and prints `repr(<func>(<args…>))`
    /// where the function call + its literal args are supplied as a Python
    /// expression. Returns trimmed stdout; `terminationStatus` is asserted 0.
    /// `expectFailure: true` flips the contract: the process MUST exit non-zero
    /// (used for the len-mismatch ValueError case) and stderr is returned.
    private func call(_ expression: String, expectFailure: Bool = false) throws -> String {
        let driver = try #require(MLXWhisperEngine.bundledDriverScript())
        // The driver is imported under the module name `whisper_driver`; the
        // expression references it as `mod`. `repr` makes None/lists/strings
        // unambiguous to assert against.
        let script = """
            import importlib.util, sys
            spec = importlib.util.spec_from_file_location("whisper_driver", sys.argv[1])
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            assert "numpy" not in sys.modules, "numpy leaked into the pure detection seam"
            print(repr(\(expression)))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, driver.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if expectFailure {
            #expect(process.terminationStatus != 0)
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }
        #expect(process.terminationStatus == 0)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: candidate_detection_starts

    @Test func candidateStartsEmptyOnZeroOrNegative() throws {
        #expect(try call("mod.candidate_detection_starts(0)") == "[]")
        #expect(try call("mod.candidate_detection_starts(-5)") == "[]")
    }

    @Test func candidateStartsSingleWindowBelowN_SAMPLES() throws {
        // 0 < num_samples < N_SAMPLES (480000) -> [0].
        #expect(try call("mod.candidate_detection_starts(100)") == "[0]")
        #expect(try call("mod.candidate_detection_starts(479999)") == "[0]")
    }

    @Test func candidateStartsExactMultiple() throws {
        // 960000 == 2*N_SAMPLES -> [0, 480000] (range stops before 960000).
        #expect(try call("mod.candidate_detection_starts(960000)") == "[0, 480000]")
    }

    @Test func candidateStartsNonMultipleKeepsTailStart() throws {
        // A partial tail window's START index is still present (its RMS will
        // gate it out later if it is silence-padding).
        #expect(try call("mod.candidate_detection_starts(960001)") == "[0, 480000, 960000]")
        #expect(try call("mod.candidate_detection_starts(1000000)") == "[0, 480000, 960000]")
    }

    @Test func candidateStartsLargeAscendingUnique() throws {
        let out = try call("mod.candidate_detection_starts(5000000)")
        #expect(out == "[0, 480000, 960000, 1440000, 1920000, 2400000, 2880000, 3360000, 3840000, 4320000, 4800000]")
    }

    // MARK: select_detection_windows

    @Test func selectRaisesOnLengthMismatch() throws {
        // FIRST-statement guard: zip() would otherwise silently truncate.
        let stderr = try call("mod.select_detection_windows([0, 1], [0.5])", expectFailure: true)
        #expect(stderr.contains("ValueError"))
        #expect(stderr.contains("length mismatch"))
    }

    @Test func selectAllDeadOrNonFiniteYieldsEmpty() throws {
        // Below DEAD_SILENCE_RMS (1e-3) or non-finite -> excluded entirely.
        #expect(try call("mod.select_detection_windows([0, 480000], [0.0, 1e-4])") == "[]")
        #expect(
            try call("mod.select_detection_windows([0, 480000], [float('nan'), float('inf')])") == "[]")
    }

    @Test func selectAtOrBelowKReturnsAllAscending() throws {
        // <= k survivors -> all of them, ascending (no bucketing).
        #expect(
            try call("mod.select_detection_windows([0, 480000, 960000], [0.9, 0.8, 0.7])")
                == "[0, 480000, 960000]")
    }

    @Test func selectDeadWindowBetweenLiveOnesExcluded() throws {
        #expect(
            try call("mod.select_detection_windows([0, 480000, 960000], [0.9, 1e-5, 0.7])")
                == "[0, 960000]")
    }

    @Test func selectAboveKReturnsExactlyKTemporallySpreadAscending() throws {
        // 16 live windows, default k=8 -> exactly 8, ascending, one per
        // contiguous temporal bucket (loudest-per-bucket).
        let starts = (0..<16).map { String($0 * 480000) }.joined(separator: ", ")
        // Energies: a sawtooth so each bucket has a distinct loudest member.
        let energies = (0..<16).map { String(format: "%.2f", Double($0 % 4) + 0.5) }.joined(separator: ", ")
        let out = try call("mod.select_detection_windows([\(starts)], [\(energies)])")
        // Parse the printed Python list and assert structural properties.
        let nums = parsePyIntList(out)
        #expect(nums.count == 8)
        #expect(nums == nums.sorted())
        #expect(Set(nums).count == 8)  // unique
        // Temporally spread: one chosen start lands in each of the 8 buckets
        // (buckets = contiguous index ranges over the 16 survivors).
        #expect(nums.allSatisfy { $0 % 480000 == 0 })
    }

    @Test func selectEqualEnergyTieBreaksToSmallerStart() throws {
        // All equal energy, k=2 -> per bucket the SMALLER start wins the tie.
        #expect(
            try call("mod.select_detection_windows([0, 480000, 960000, 1440000], [1.0, 1.0, 1.0, 1.0], k=2)")
                == "[0, 960000]")
    }

    // MARK: detect_dominant_language

    @Test func detectPTWhenWindowsArePTConfident() throws {
        #expect(
            try call("mod.detect_dominant_language([{'pt': 0.9, 'en': 0.05}, {'pt': 0.85, 'en': 0.1}])")
                == "'pt'")
    }

    @Test func detectENWhenWindowsAreENConfident() throws {
        #expect(
            try call("mod.detect_dominant_language([{'pt': 0.05, 'en': 0.9}, {'pt': 0.1, 'en': 0.85}])")
                == "'en'")
    }

    @Test func detectZeroMarginPairReturnsNoneNotPT() throws {
        // Codex B3 REGRESSION PIN: pa == pb is NOT evidence for 'pt'. Two
        // identical 50/50 windows -> margin 0 each -> skipped -> None.
        #expect(
            try call("mod.detect_dominant_language([{'pt': 0.5, 'en': 0.5}, {'pt': 0.5, 'en': 0.5}])")
                == "None")
    }

    @Test func detectDiffuseMassBelowFloorSkipped() throws {
        // mass = 0.4 < MIN_PAIR_MASS (0.5) -> not counted -> None.
        #expect(
            try call("mod.detect_dominant_language([{'pt': 0.2, 'en': 0.2}, {'pt': 0.2, 'en': 0.2}])")
                == "None")
    }

    @Test func detectMarginBelowFloorSkipped() throws {
        // {pt:0.545,en:0.455} -> margin 0.09 < 0.10 -> skipped; only the second
        // window counts -> counted (1) < MIN_WINDOWS (2) -> None.
        #expect(
            try call(
                "mod.detect_dominant_language([{'pt': 0.545, 'en': 0.455}, {'pt': 0.9, 'en': 0.05}])")
                == "None")
    }

    @Test func detectFewerThanMinWindowsReturnsNone() throws {
        #expect(try call("mod.detect_dominant_language([{'pt': 0.9, 'en': 0.05}])") == "None")
    }

    @Test func detectCountedButTotalMarginBelowFloorReturnsNone() throws {
        // Two windows each margin exactly 0.10 -> counted 2 >= MIN_WINDOWS, but
        // total margin 0.20 < MIN_TOTAL_MARGIN (0.5) -> ambiguous -> None.
        #expect(
            try call("mod.detect_dominant_language([{'pt': 0.55, 'en': 0.45}, {'pt': 0.55, 'en': 0.45}])")
                == "None")
    }

    @Test func detectNaNProbWindowSkippedNoFlip() throws {
        // A NaN/Inf prob window is skipped (driver NaN hazard); the remaining
        // single PT window then fails MIN_WINDOWS -> None (no spurious flip).
        #expect(
            try call(
                "mod.detect_dominant_language([{'pt': float('nan'), 'en': 0.5}, {'pt': 0.9, 'en': 0.05}])")
                == "None")
    }

    @Test func detectBoundaryMarginAndMassAreCounted() throws {
        // Strict `<` semantics: margin == MIN_MARGIN (0.10) is COUNTED and
        // total == MIN_TOTAL_MARGIN (0.50) is NOT below the floor. Five
        // {pt:0.55,en:0.45} windows: margin 0.10 each, total 0.50 -> 'pt'.
        #expect(
            try call(
                "mod.detect_dominant_language([{'pt': 0.55, 'en': 0.45}] * 5)")
                == "'pt'")
        // mass == MIN_PAIR_MASS (0.50) clears the mass gate (strict `<`):
        // {pt:0.30,en:0.20} mass 0.50, margin 0.20 -> counted; x4 -> 'pt'.
        #expect(
            try call("mod.detect_dominant_language([{'pt': 0.30, 'en': 0.20}] * 4)")
                == "'pt'")
    }

    @Test func detectMixedSetMarginWeightedWinnerDeterministic() throws {
        // 3 strong EN windows outweigh 1 weak PT window by summed margin.
        #expect(
            try call(
                "mod.detect_dominant_language(["
                    + "{'pt': 0.1, 'en': 0.9}, {'pt': 0.15, 'en': 0.85}, "
                    + "{'pt': 0.2, 'en': 0.8}, {'pt': 0.6, 'en': 0.4}])")
                == "'en'")
    }

    // MARK: helpers

    /// Parses a printed Python int list like "[0, 480000, 960000]".
    private func parsePyIntList(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
