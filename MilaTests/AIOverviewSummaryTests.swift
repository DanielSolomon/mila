import XCTest
@testable import Mila

/// Covers `AIOverviewSection.summaryAttributed` — the saved-recording
/// summary renderer. It renders a few PROSE lines with NO bullets (the
/// action-items section is the bulleted list). Risks: chopping decimals /
/// abbreviations / domains / URLs mid-token, and leaving bullet markers in.
final class AIOverviewSummaryTests: XCTestCase {

    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    func test_multiSentence_paragraph_splits_into_lines_without_bullets() {
        let s = "We shipped the beta. Dana will send the deck. Yossi books the room."
        let out = plain(AIOverviewSection.summaryAttributed(s))
        XCTAssertEqual(out.components(separatedBy: "\n").count, 3, "three sentences → three lines")
        XCTAssertFalse(out.contains("•"), "summary must NOT be a bulleted list")
    }

    func test_llm_dash_bullets_are_stripped() {
        let s = "- First point.\n- Second point.\n- Third point."
        let out = plain(AIOverviewSection.summaryAttributed(s))
        XCTAssertEqual(out.components(separatedBy: "\n").count, 3)
        XCTAssertFalse(out.contains("•"))
        XCTAssertFalse(out.split(separator: "\n").contains { $0.hasPrefix("- ") },
                       "leading '- ' markers must be stripped")
        XCTAssertTrue(out.contains("First point."))
    }

    func test_decimals_and_abbreviations_are_not_split_midtoken() {
        let s = "The sync is at 3.30 p.m. and the budget is 1.5M."
        let out = plain(AIOverviewSection.summaryAttributed(s))
        XCTAssertTrue(out.contains("3.30"), "decimal time must stay intact")
        XCTAssertTrue(out.contains("1.5M"), "decimal figure must stay intact")
    }

    func test_domains_and_urls_are_not_split() {
        let s = "Check acme.com and https://example.com/path for details."
        let out = plain(AIOverviewSection.summaryAttributed(s))
        XCTAssertTrue(out.contains("acme.com"))
        XCTAssertTrue(out.contains("https://example.com/path"))
    }

    func test_single_sentence_is_not_bulleted() {
        let out = plain(AIOverviewSection.summaryAttributed("Just one short note."))
        XCTAssertFalse(out.contains("•"))
    }

    func test_empty_or_blank_is_safe() {
        XCTAssertTrue(plain(AIOverviewSection.summaryAttributed("")).isEmpty)
        XCTAssertTrue(plain(AIOverviewSection.summaryAttributed("   ")).isEmpty)
    }

    func test_multiline_markdown_content_preserved_without_bullets() {
        let s = "**Topic:** test\n\n- did a thing\n- found a bug"
        let out = plain(AIOverviewSection.summaryAttributed(s))
        XCTAssertTrue(out.contains("did a thing"))
        XCTAssertTrue(out.contains("found a bug"))
        XCTAssertFalse(out.contains("•"))
    }
}
