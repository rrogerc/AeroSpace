public struct FullscreenCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .fullscreen,
        help: fullscreen_help_generated,
        flags: [
            "--no-outer-gaps": trueBoolFlag(\.noOuterGaps),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--width": singleValueSubArgParser(\.width, "<width>") { Double($0).toResult("Can't convert '\($0)' to Double") },
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [ArgParser(\.toggle, parseToggleEnum)],
    )

    public var toggle: ToggleEnum = .toggle
    public var noOuterGaps: Bool = false
    public var failIfNoop: Bool = false
    public var width: Double? = nil
}

func parseFullscreenCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FullscreenCmdArgs> {
    parseSpecificCmdArgs(FullscreenCmdArgs(rawArgs: args), args)
        .filterNot("--no-outer-gaps is incompatible with 'off' argument") { $0.toggle == .off && $0.noOuterGaps }
        .filterNot("--width is incompatible with 'off' argument") { $0.toggle == .off && $0.width != nil }
        .filter("--width must be greater than 0 and less than or equal to 1") { $0.width == nil || (0 < $0.width! && $0.width! <= 1) }
        .filter("--fail-if-noop requires 'on' or 'off' argument") { $0.failIfNoop.implies($0.toggle == .on || $0.toggle == .off) }
}
