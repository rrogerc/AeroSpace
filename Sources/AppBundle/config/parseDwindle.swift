import Common

struct DwindleConfig: ConvenienceMutable {
    var enabled: Bool = false
    var preserveSplit: Bool = true
    var splitWidthMultiplier: Double = 1.0
    var defaultSplitRatio: Double = 1.0
    var forceSplit: DwindleForceSplit = .right
    var permanentDirectionOverride: Bool = false
}

/// Which side of the split window a new window goes to. `left` also means top, `right` also means bottom
enum DwindleForceSplit: String {
    case left, right
}

private let dwindleParserTable: [String: any ParserProtocol<DwindleConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "preserve-split": Parser(\.preserveSplit, parseBool),
    "split-width-multiplier": Parser(\.splitWidthMultiplier, parseDouble(in: 0.1 ... 3.0)),
    "default-split-ratio": Parser(\.defaultSplitRatio, parseDouble(in: 0.1 ... 1.9)),
    "force-split": Parser(\.forceSplit, parseForceSplit),
    "permanent-direction-override": Parser(\.permanentDirectionOverride, parseBool),
]

func parseDwindle(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> DwindleConfig {
    parseTable(raw, DwindleConfig(), dwindleParserTable, backtrace, &c)
}

private func parseDouble(in range: ClosedRange<Double>) -> @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<Double> {
    { raw, backtrace in
        parseDouble(raw, backtrace)
            .filter(.init(backtrace, "Must be in [\(range.lowerBound), \(range.upperBound)] range")) { range.contains($0) }
    }
}

private func parseForceSplit(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<DwindleForceSplit> {
    parseString(raw, backtrace).flatMap {
        DwindleForceSplit(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse force-split '\($0)'. Possible values: left|right"))
    }
}
