import Foundation

enum SettingsWalletEntropyMethod: String, CaseIterable, Identifiable,
    Sendable
{
    case dice
    case coin
    case digits

    var id: Self { self }
}

enum SettingsWalletEntropyCoinSide: Equatable, Sendable {
    case heads
    case tails
}

enum SettingsWalletEntropySource: Equatable, Sendable {
    case dice(face: Int)
    case coin(side: SettingsWalletEntropyCoinSide)
    case digit(Int)
}

struct SettingsWalletEntropyEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: SettingsWalletEntropySource
    let contributedBits: Int

    init(
        id: UUID = UUID(),
        source: SettingsWalletEntropySource,
        contributedBits: Int
    ) {
        self.id = id
        self.source = source
        self.contributedBits = contributedBits
    }
}

enum SettingsWalletEntropyHealthIssue: Equatable, Sendable {
    case repetition(method: SettingsWalletEntropyMethod)
    case dominance(method: SettingsWalletEntropyMethod)
    case predictablePattern(method: SettingsWalletEntropyMethod)

    var messageKey: String {
        switch self {
        case .repetition:
            "wallet.creation.entropy.health.warning.repetition"
        case .dominance:
            "wallet.creation.entropy.health.warning.dominance"
        case .predictablePattern:
            "wallet.creation.entropy.health.warning.pattern"
        }
    }
}

struct SettingsWalletEntropyHealthAssessment: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case monitoring
        case noWarningSigns
        case warning(SettingsWalletEntropyHealthIssue)
    }

    let status: Status
    let flaggedEntryIDs: Set<UUID>

    var requiresIntervention: Bool {
        if case .warning = status {
            true
        } else {
            false
        }
    }

    var permitsFurtherInput: Bool {
        !requiresIntervention
    }

    var permitsWalletCreation: Bool {
        !requiresIntervention
    }

    var informationSummaryKey: String {
        warningMessageKey
            ?? "wallet.creation.entropy.health.monitoring"
    }

    var informationGuidanceKey: String {
        switch status {
        case .monitoring, .noWarningSigns:
            "wallet.creation.entropy.health.info.message"
        case .warning:
            "wallet.creation.entropy.health.warning.fix"
        }
    }

    var warningMessageKey: String? {
        guard case let .warning(issue) = status else { return nil }
        return issue.messageKey
    }
}

enum SettingsWalletEntropyHealthAnalyzer {
    // NIST SP 800-90B uses 2^-20 as a reasonable type-I error
    // probability for continuous entropy-source health tests. Each test
    // below applies a conservative union bound over every possible input
    // position, input method, and test family in this 256-entry flow.
    static let targetFalsePositiveProbability = pow(2.0, -20.0)

    private static let maximumEntryCount =
        SettingsWalletEntropyAccumulator.requiredBitCount
    private static let methodCount =
        SettingsWalletEntropyMethod.allCases.count
    private static let testFamilyCount = 3
    private static let maximumPatternLag = 32
    private static let patternSubtestCount = 2

    static func assess(
        entries: [SettingsWalletEntropyEntry]
    ) -> SettingsWalletEntropyHealthAssessment {
        guard !entries.isEmpty else {
            return SettingsWalletEntropyHealthAssessment(
                status: .monitoring,
                flaggedEntryIDs: []
            )
        }

        let detectedCandidates = SettingsWalletEntropyMethod.allCases
            .flatMap { method in
                candidates(
                    for: samples(from: entries, method: method),
                    method: method
                )
            }
            .filter {
                $0.adjustedFalseAlarmUpperBound
                    <= targetFalsePositiveProbability
            }

        guard let strongest = detectedCandidates.min(by: {
            $0.adjustedFalseAlarmUpperBound
                < $1.adjustedFalseAlarmUpperBound
        }) else {
            return SettingsWalletEntropyHealthAssessment(
                status: .noWarningSigns,
                flaggedEntryIDs: []
            )
        }

        return SettingsWalletEntropyHealthAssessment(
            status: .warning(strongest.issue),
            flaggedEntryIDs: strongest.flaggedEntryIDs
        )
    }

    static func binomialUpperTail(
        trials: Int,
        successesAtLeast lowerBound: Int,
        successProbability: Double
    ) -> Double {
        guard trials >= 0,
              lowerBound > 0,
              lowerBound <= trials,
              successProbability > 0,
              successProbability < 1
        else {
            if lowerBound <= 0 { return 1 }
            return 0
        }

        // Sum the exact finite binomial tail. Advancing each probability
        // from the previous term avoids factorials and their overflow.
        let failureProbability = 1 - successProbability
        var pointProbability = pow(
            failureProbability,
            Double(trials)
        )
        var upperTail = 0.0

        for successes in 0...trials {
            if successes >= lowerBound {
                upperTail += pointProbability
            }
            guard successes < trials else { break }

            pointProbability *= Double(trials - successes)
                / Double(successes + 1)
                * successProbability
                / failureProbability
        }

        return min(max(upperTail, 0), 1)
    }

    private struct Sample: Sendable {
        let id: UUID
        let value: Int
    }

    private struct Candidate: Sendable {
        let issue: SettingsWalletEntropyHealthIssue
        let adjustedFalseAlarmUpperBound: Double
        let flaggedEntryIDs: Set<UUID>
    }

    private static func samples(
        from entries: [SettingsWalletEntropyEntry],
        method: SettingsWalletEntropyMethod
    ) -> [Sample] {
        entries.compactMap { entry in
            switch (method, entry.source) {
            case let (.dice, .dice(face)) where (1...6).contains(face):
                Sample(id: entry.id, value: face - 1)
            case let (.coin, .coin(side)):
                Sample(id: entry.id, value: side == .heads ? 0 : 1)
            case let (.digits, .digit(digit))
                where (0...9).contains(digit):
                Sample(id: entry.id, value: digit)
            default:
                nil
            }
        }
    }

    private static func candidates(
        for samples: [Sample],
        method: SettingsWalletEntropyMethod
    ) -> [Candidate] {
        guard !samples.isEmpty else { return [] }

        let alphabetSize = alphabetSize(for: method)
        return [
            repetitionCandidate(
                samples: samples,
                method: method,
                alphabetSize: alphabetSize
            ),
            dominanceCandidate(
                samples: samples,
                method: method,
                alphabetSize: alphabetSize
            ),
            patternCandidate(
                samples: samples,
                method: method,
                alphabetSize: alphabetSize
            )
        ].compactMap { $0 }
    }

    private static func alphabetSize(
        for method: SettingsWalletEntropyMethod
    ) -> Int {
        switch method {
        case .coin:
            2
        case .dice:
            6
        case .digits:
            10
        }
    }

    private static func repetitionCandidate(
        samples: [Sample],
        method: SettingsWalletEntropyMethod,
        alphabetSize: Int
    ) -> Candidate? {
        guard samples.count >= 2 else { return nil }

        var currentStart = 0
        var bestRange = 0..<1

        for index in 1..<samples.count {
            if samples[index].value != samples[index - 1].value {
                currentStart = index
            }
            let currentRange = currentStart..<(index + 1)
            if currentRange.count >= bestRange.count {
                bestRange = currentRange
            }
        }

        let fixedStartProbability = pow(
            Double(alphabetSize),
            Double(1 - bestRange.count)
        )
        let adjustedProbability = adjustedProbability(
            fixedStartProbability
        )

        return Candidate(
            issue: .repetition(method: method),
            adjustedFalseAlarmUpperBound: adjustedProbability,
            flaggedEntryIDs: Set(bestRange.map { samples[$0].id })
        )
    }

    private static func dominanceCandidate(
        samples: [Sample],
        method: SettingsWalletEntropyMethod,
        alphabetSize: Int
    ) -> Candidate? {
        guard samples.count >= 2 else { return nil }

        var counts = [Int](repeating: 0, count: alphabetSize)
        for sample in samples {
            counts[sample.value] += 1
        }
        guard let maximumCount = counts.max(),
              let dominantValue = counts.firstIndex(of: maximumCount)
        else {
            return nil
        }

        // Each fair source value has a Binomial(n, 1/k) count. The factor
        // k is a union bound for selecting the most frequent value after
        // observing the samples.
        let anyValueProbability = min(
            Double(alphabetSize) * binomialUpperTail(
                trials: samples.count,
                successesAtLeast: maximumCount,
                successProbability: 1 / Double(alphabetSize)
            ),
            1
        )

        return Candidate(
            issue: .dominance(method: method),
            adjustedFalseAlarmUpperBound: adjustedProbability(
                anyValueProbability
            ),
            flaggedEntryIDs: Set(
                samples.lazy
                    .filter { $0.value == dominantValue }
                    .map(\.id)
            )
        )
    }

    private static func patternCandidate(
        samples: [Sample],
        method: SettingsWalletEntropyMethod,
        alphabetSize: Int
    ) -> Candidate? {
        guard samples.count >= 3 else { return nil }

        let stepCandidate = constantStepPattern(
            samples: samples,
            alphabetSize: alphabetSize
        )
        let lagCandidate = repeatedLagPattern(
            samples: samples,
            alphabetSize: alphabetSize
        )

        guard let strongest = [stepCandidate, lagCandidate]
            .compactMap({ $0 })
            .min(by: { $0.probability < $1.probability })
        else {
            return nil
        }

        let patternFamilyProbability = min(
            strongest.probability * Double(patternSubtestCount),
            1
        )
        return Candidate(
            issue: .predictablePattern(method: method),
            adjustedFalseAlarmUpperBound: adjustedProbability(
                patternFamilyProbability
            ),
            flaggedEntryIDs: strongest.flaggedEntryIDs
        )
    }

    private struct PatternEvidence {
        let probability: Double
        let flaggedEntryIDs: Set<UUID>
    }

    private static func constantStepPattern(
        samples: [Sample],
        alphabetSize: Int
    ) -> PatternEvidence? {
        // For independent uniform k-symbol samples, X[0] together with
        // the modular differences uniquely determines the sequence. The
        // differences are therefore independent and uniform as well.
        var stepCounts = [Int](repeating: 0, count: alphabetSize)
        var steps: [Int] = []

        for index in 1..<samples.count {
            let step = (
                samples[index].value
                    - samples[index - 1].value
                    + alphabetSize
            ) % alphabetSize
            stepCounts[step] += 1
            steps.append(step)
        }
        guard let maximumCount = stepCounts.max(),
              let dominantStep = stepCounts.firstIndex(of: maximumCount)
        else {
            return nil
        }

        let probability = min(
            Double(alphabetSize) * binomialUpperTail(
                trials: steps.count,
                successesAtLeast: maximumCount,
                successProbability: 1 / Double(alphabetSize)
            ),
            1
        )
        var flaggedEntryIDs = Set<UUID>()
        for (offset, step) in steps.enumerated()
        where step == dominantStep {
            flaggedEntryIDs.insert(samples[offset].id)
            flaggedEntryIDs.insert(samples[offset + 1].id)
        }
        return PatternEvidence(
            probability: probability,
            flaggedEntryIDs: flaggedEntryIDs
        )
    }

    private static func repeatedLagPattern(
        samples: [Sample],
        alphabetSize: Int
    ) -> PatternEvidence? {
        let largestLag = min(maximumPatternLag, samples.count - 1)
        var strongest: PatternEvidence?

        for lag in 1...largestLag {
            // At a fixed lag, equality comparisons form independent
            // chains. Every comparison is Bernoulli(1/k), so its match
            // count has the exact binomial null distribution used here.
            var matchingIndices: [Int] = []
            for index in lag..<samples.count
            where samples[index].value == samples[index - lag].value {
                matchingIndices.append(index)
            }

            let probability = binomialUpperTail(
                trials: samples.count - lag,
                successesAtLeast: matchingIndices.count,
                successProbability: 1 / Double(alphabetSize)
            )
            guard strongest == nil
                    || probability < strongest!.probability
            else {
                continue
            }

            var flaggedEntryIDs = Set<UUID>()
            for index in matchingIndices {
                flaggedEntryIDs.insert(samples[index].id)
                flaggedEntryIDs.insert(samples[index - lag].id)
            }
            strongest = PatternEvidence(
                probability: probability,
                flaggedEntryIDs: flaggedEntryIDs
            )
        }

        guard let strongest else { return nil }
        return PatternEvidence(
            probability: min(
                strongest.probability * Double(maximumPatternLag),
                1
            ),
            flaggedEntryIDs: strongest.flaggedEntryIDs
        )
    }

    private static func adjustedProbability(
        _ probability: Double
    ) -> Double {
        let multiplier = Double(
            methodCount * testFamilyCount * maximumEntryCount
        )
        return min(probability * multiplier, 1)
    }
}

struct SettingsWalletEntropyAccumulator: Equatable, Sendable {
    static let requiredBitCount = 256

    private(set) var entries: [SettingsWalletEntropyEntry] = []
    private var bits: [UInt8] = []
    private(set) var healthAssessment =
        SettingsWalletEntropyHealthAnalyzer.assess(entries: [])

    var bitCount: Int {
        bits.count
    }

    var latestSource: SettingsWalletEntropySource? {
        entries.last?.source
    }

    func latestEntryID(
        for source: SettingsWalletEntropySource
    ) -> UUID? {
        guard let latestEntry = entries.last,
              latestEntry.source == source
        else {
            return nil
        }
        return latestEntry.id
    }

    var remainingBitCount: Int {
        max(Self.requiredBitCount - bitCount, 0)
    }

    var isComplete: Bool {
        bitCount == Self.requiredBitCount
    }

    var isReadyForWalletCreation: Bool {
        isComplete && healthAssessment.permitsWalletCreation
    }

    var entropyData: Data? {
        guard isReadyForWalletCreation else { return nil }

        var bytes = [UInt8](
            repeating: 0,
            count: Self.requiredBitCount / 8
        )
        for (index, bit) in bits.enumerated() {
            bytes[index / 8] |= bit << UInt8(7 - (index % 8))
        }
        return Data(bytes)
    }

    @discardableResult
    mutating func appendDiceFace(_ face: Int) -> Bool {
        guard (1...6).contains(face) else { return false }
        return append(
            number: face - 1,
            base: 6,
            source: .dice(face: face)
        )
    }

    @discardableResult
    mutating func appendCoinSide(
        _ side: SettingsWalletEntropyCoinSide
    ) -> Bool {
        append(
            number: side == .heads ? 0 : 1,
            base: 2,
            source: .coin(side: side)
        )
    }

    @discardableResult
    mutating func appendDigit(_ digit: Int) -> Bool {
        guard (0...9).contains(digit) else { return false }
        return append(
            number: digit,
            base: 10,
            source: .digit(digit)
        )
    }

    mutating func undoLastEntry() {
        guard let entry = entries.popLast() else { return }
        bits.removeLast(entry.contributedBits)
        refreshHealthAssessment()
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        bits.removeAll(keepingCapacity: true)
        refreshHealthAssessment()
    }

    static func unbiasedContribution(
        number: Int,
        base: Int
    ) -> (value: Int, bitCount: Int)? {
        guard base > 1, number >= 0, number < base else {
            return nil
        }

        var maximumBitCount = 1
        while (1 << (maximumBitCount + 1)) <= base {
            maximumBitCount += 1
        }

        var candidateBitCount = maximumBitCount
        var lowerBound = 0
        while candidateBitCount >= 1 {
            let blockSize = 1 << candidateBitCount
            guard lowerBound + blockSize <= base else {
                candidateBitCount -= 1
                continue
            }

            if number < lowerBound + blockSize {
                return (
                    value: number - lowerBound,
                    bitCount: candidateBitCount
                )
            }

            lowerBound += blockSize
            candidateBitCount -= 1
        }

        return nil
    }

    private mutating func append(
        number: Int,
        base: Int,
        source: SettingsWalletEntropySource
    ) -> Bool {
        guard !isComplete,
              healthAssessment.permitsFurtherInput,
              let contribution = Self.unbiasedContribution(
                number: number,
                base: base
              )
        else {
            return false
        }

        let acceptedBitCount = min(
            contribution.bitCount,
            remainingBitCount
        )
        guard acceptedBitCount > 0 else { return false }

        for offset in 0..<acceptedBitCount {
            let shift = contribution.bitCount - offset - 1
            bits.append(UInt8((contribution.value >> shift) & 1))
        }
        entries.append(
            SettingsWalletEntropyEntry(
                source: source,
                contributedBits: acceptedBitCount
            )
        )
        refreshHealthAssessment()
        return true
    }

    private mutating func refreshHealthAssessment() {
        healthAssessment = SettingsWalletEntropyHealthAnalyzer.assess(
            entries: entries
        )
    }
}
