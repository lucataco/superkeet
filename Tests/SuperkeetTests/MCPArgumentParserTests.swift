import XCTest
@testable import Superkeet

final class MCPArgumentParserTests: XCTestCase {
    func testPlainArgumentsSplitOnWhitespace() {
        XCTAssertEqual(MCPArgumentParser.split("-y  chrome-devtools-mcp@latest\t--autoConnect "), ["-y", "chrome-devtools-mcp@latest", "--autoConnect"])
        XCTAssertEqual(MCPArgumentParser.split("   "), [])
    }

    func testQuotesKeepSpacesInsideOneArgument() {
        XCTAssertEqual(MCPArgumentParser.split(#"-y server-files "/Users/me/My Docs" '/tmp/a b'"#),
                       ["-y", "server-files", "/Users/me/My Docs", "/tmp/a b"])
        XCTAssertEqual(MCPArgumentParser.split(#"--root="/Users/me/My Docs""#), ["--root=/Users/me/My Docs"])
        XCTAssertEqual(MCPArgumentParser.split(#"/Users/me/My\ Docs"#), ["/Users/me/My Docs"])
        XCTAssertEqual(MCPArgumentParser.split(#"a "" b"#), ["a", "", "b"])
    }

    func testBackslashesThatEscapeNothingStayLiteral() {
        XCTAssertEqual(MCPArgumentParser.split(#"--pattern=\d+ "\w""#), [#"--pattern=\d+"#, #"\w"#])
        XCTAssertEqual(MCPArgumentParser.split(#""say \"hi\"""#), [#"say "hi""#])
    }

    func testUnterminatedQuoteKeepsTheRest() {
        XCTAssertEqual(MCPArgumentParser.split(#"a "b c"#), ["a", "b c"])
    }

    func testJoinRoundTripsEveryArgument() {
        let cases: [[String]] = [
            ["-y", "chrome-devtools-mcp@latest", "--autoConnect"],
            ["-y", "server-files", "/Users/me/My Docs"],
            ["", #"say "hi""#, "it's", #"C:\path\to"#, #"\d+"#, "tab\there"]
        ]
        for arguments in cases {
            XCTAssertEqual(MCPArgumentParser.split(MCPArgumentParser.join(arguments)), arguments, MCPArgumentParser.join(arguments))
        }
        XCTAssertEqual(MCPArgumentParser.join(["-y", "chrome-devtools-mcp@latest"]), "-y chrome-devtools-mcp@latest", "Simple args stay unquoted.")
        XCTAssertEqual(MCPArgumentParser.join(["/Users/me/My Docs"]), #""/Users/me/My Docs""#)
    }
}
