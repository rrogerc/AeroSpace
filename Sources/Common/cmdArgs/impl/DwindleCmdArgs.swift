public struct DwindleCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .dwindle,
        help: dwindle_help_generated,
        flags: [
            "--unstable": trueBoolFlag(\.unstable),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [newMandatoryPosArgParser(\.message, parseDwindleMessage, placeholder: DwindleMessage.argsUnion)],
    )

    public var message: Lateinit<DwindleMessage> = .uninitialized
    public var unstable: Bool = false
}

/// The layout messages of Hyprland's dwindle layout
public enum DwindleMessage: Equatable, Sendable {
    case togglesplit
    case swapsplit
    case rotatesplit(degrees: Int)
    case splitratio(DwindleSplitRatio)
    case preselect(CardinalDirection?)
    case movetoroot

    static let argsUnion: String = "(togglesplit|swapsplit|rotatesplit|splitratio|preselect|movetoroot)"
}

public enum DwindleSplitRatio: Equatable, Sendable {
    case set(Double)
    case add(Double)
}

func parseDwindleCmdArgs(_ args: StrArrSlice) -> ParsedCmd<DwindleCmdArgs> {
    parseSpecificCmdArgs(DwindleCmdArgs(rawArgs: args), args)
        .filter("--unstable is only allowed with 'movetoroot'") { $0.unstable.implies($0.message.val == .movetoroot) }
}

// The values are parsed here, not as separate positional arguments, because negative values look like flags
private func parseDwindleMessage(i: PosArgParserInput) -> ParsedCliArgs<DwindleMessage> {
    switch i.arg {
        case "togglesplit": return .succ(.togglesplit, advanceBy: 1)
        case "swapsplit": return .succ(.swapsplit, advanceBy: 1)
        case "movetoroot": return .succ(.movetoroot, advanceBy: 1)
        case "rotatesplit":
            guard let degrees = i.getOrNil(relativeIndex: 1).flatMap({ Int($0) }) else { return .succ(.rotatesplit(degrees: 90), advanceBy: 1) }
            if degrees % 90 != 0 { return .fail("The angle must be a multiple of 90. Got: \(degrees)", advanceBy: 2) }
            return .succ(.rotatesplit(degrees: degrees), advanceBy: 2)
        case "splitratio":
            guard let arg = i.getOrNil(relativeIndex: 1) else { return .fail("splitratio must be followed by [+|-]<ratio>", advanceBy: 1) }
            guard let value = Double(arg), value.isFinite else { return .fail("Can't parse ratio '\(arg)'", advanceBy: 2) }
            let ratio: DwindleSplitRatio = arg.starts(with: "+") || arg.starts(with: "-") ? .add(value) : .set(value)
            return .succ(.splitratio(ratio), advanceBy: 2)
        case "preselect":
            guard let arg = i.getOrNil(relativeIndex: 1) else {
                return .fail("preselect must be followed by (left|down|up|right|none)", advanceBy: 1)
            }
            if arg == "none" { return .succ(.preselect(nil), advanceBy: 2) }
            return .init(parseEnum(arg, CardinalDirection.self).map { .preselect($0) }, advanceBy: 2)
        default:
            return .fail("Unknown argument '\(i.arg)'. Possible values: \(DwindleMessage.argsUnion)", advanceBy: 1)
    }
}
