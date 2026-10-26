use std::io::{self, BufRead, Write};

use super::safe_text;

/// Choose an original name using line-oriented input, or return `None` on cancellation.
/// Search uses Unicode lowercase substring matching; numbers refer to the original list.
pub(super) fn choose<R: BufRead, W: Write>(
    input: &mut R,
    output: &mut W,
    group: &str,
    choices: &[&str],
    current: Option<&str>,
) -> io::Result<Option<String>> {
    const PAGE_SIZE: usize = 15;

    writeln!(output, "Group: {}", safe_text(group))?;
    writeln!(
        output,
        "Profile selection (saved/default): {}",
        current
            .map(safe_text)
            .unwrap_or_else(|| "(none)".to_owned())
    )?;
    writeln!(
        output,
        "Enter a shown number, /text to search, / to clear, n/p for pages."
    )?;
    writeln!(
        output,
        "Blank, q, Escape, or EOF cancels. * marks the profile selection, not live state."
    )?;

    let mut matches: Vec<usize> = (0..choices.len()).collect();
    let mut page = 0;
    let mut line = String::new();
    loop {
        let pages = matches.len().div_ceil(PAGE_SIZE).max(1);
        let start = page * PAGE_SIZE;
        let visible = &matches[start..(start + PAGE_SIZE).min(matches.len())];
        writeln!(
            output,
            "Page {}/{} ({} matches)",
            page + 1,
            pages,
            matches.len()
        )?;
        for &index in visible {
            let marker = if current == Some(choices[index]) {
                '*'
            } else {
                ' '
            };
            writeln!(
                output,
                "{marker} {}: {}",
                index + 1,
                safe_text(choices[index])
            )?;
        }
        if matches.is_empty() {
            writeln!(output, "No matches. Try /text or / to clear.")?;
        }
        write!(output, "Select: ")?;
        output.flush()?;
        line.clear();
        if input.read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let command = line.trim();
        match command {
            "" | "q" | "\u{1b}" => return Ok(None),
            "n" => page = (page + 1).min(pages - 1),
            "p" => page = page.saturating_sub(1),
            _ => {
                if let Some(query) = command.strip_prefix('/') {
                    let query = query.to_lowercase();
                    matches = choices
                        .iter()
                        .enumerate()
                        .filter_map(|(index, name)| {
                            name.to_lowercase().contains(&query).then_some(index)
                        })
                        .collect();
                    page = 0;
                } else if let Some(index) = command
                    .parse::<usize>()
                    .ok()
                    .and_then(|number| number.checked_sub(1))
                    .filter(|index| visible.contains(index))
                {
                    return Ok(Some(choices[index].to_owned()));
                } else {
                    writeln!(output, "Enter a number shown on this page.")?;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::choose;
    use std::io::{self, Write};

    fn run(input: &str, choices: &[&str], current: Option<&str>) -> (Option<String>, String) {
        let mut output = Vec::new();
        let selected = choose(
            &mut input.as_bytes(),
            &mut output,
            "Group",
            choices,
            current,
        )
        .unwrap();
        (selected, String::from_utf8(output).unwrap())
    }

    #[test]
    fn shows_saved_selection_and_returns_original_name() {
        let (selected, output) = run("2\n", &["Alpha", "東京"], Some("東京"));
        assert_eq!(selected.as_deref(), Some("東京"));
        assert!(output.starts_with("Group: Group\nProfile selection (saved/default): 東京\n"));
        assert!(output.contains("  1: Alpha\n* 2: 東京\n"));
        assert!(output.contains("Page 1/1 (2 matches)\n"));
        let (_, output) = run("q\n", &["Alpha"], Some("removed"));
        assert!(output.contains("Profile selection (saved/default): removed\n"));
        assert!(!output.contains("* 1:"));
    }

    #[test]
    fn pages_use_original_numbers_and_reject_hidden_choices() {
        let names: Vec<_> = (1..=31).map(|i| format!("Proxy {i}")).collect();
        let choices: Vec<_> = names.iter().map(String::as_str).collect();
        let (_, first) = run("q\n", &choices, None);
        assert!(first.contains("  15: Proxy 15\n"));
        assert!(!first.contains("16: Proxy 16"));
        let (selected, output) = run("16\nn\n1\np\nn\nn\nn\n31\n", &choices, None);
        assert_eq!(selected.as_deref(), Some("Proxy 31"));
        assert_eq!(
            output.matches("Enter a number shown on this page.").count(),
            2
        );
        assert!(output.contains("Page 2/3 (31 matches)"));
        assert!(output.contains("Page 3/3 (31 matches)"));
        let (selected, _) = run("p\n1\n", &choices, None);
        assert_eq!(selected.as_deref(), Some("Proxy 1"));
    }

    #[test]
    fn search_is_unicode_case_insensitive_and_clears() {
        let names: Vec<_> = (1..=16).map(|i| format!("Other {i}")).collect();
        let mut choices: Vec<_> = names.iter().map(String::as_str).collect();
        choices.extend(["ZÜRICH 東京", "Elsewhere"]);
        let (selected, output) = run("n\n/zürICH\n1\n17\n", &choices, None);
        assert_eq!(selected.as_deref(), Some("ZÜRICH 東京"));
        assert!(output.contains("Page 1/1 (1 matches)\n  17: ZÜRICH 東京\n"));
        let (selected, output) = run("/missing\nn\np\n1\n/東京\n/\n1\n", &choices, None);
        assert_eq!(selected.as_deref(), Some("Other 1"));
        assert!(output.contains("No matches. Try /text or / to clear.\n"));
        assert!(output.contains("Page 1/2 (18 matches)"));
    }

    #[test]
    fn retries_invalid_input_and_handles_empty_choices() {
        let (selected, output) = run(
            "0\n999999999999999999999999999999\n-1\nwat\n2\n1\n",
            &["A"],
            None,
        );
        assert_eq!(selected.as_deref(), Some("A"));
        assert_eq!(
            output.matches("Enter a number shown on this page.").count(),
            5
        );
        let (selected, output) = run("1\n/x\n/\nq\n", &[], None);
        assert_eq!(selected, None);
        assert!(output.contains("Profile selection (saved/default): (none)"));
        assert!(output.contains("Page 1/1 (0 matches)"));
    }

    #[test]
    fn cancels_on_blank_q_escape_or_eof() {
        for input in ["\n", "  \r\n", "q\n", "\x1b\n", "", "/missing\n"] {
            assert_eq!(run(input, &["A"], None).0, None, "{input:?}");
        }
        assert_eq!(run("1\r\n", &["A"], None).0.as_deref(), Some("A"));
    }

    #[test]
    fn sanitizes_display_but_preserves_selected_value() {
        let name = "東京\x1b[31m\n\t\u{202e}";
        let mut output = Vec::new();
        let selected = choose(
            &mut &b"1\n"[..],
            &mut output,
            "G\r\u{2066}",
            &[name],
            Some(name),
        )
        .unwrap();
        assert_eq!(selected.as_deref(), Some(name));
        let output = String::from_utf8(output).unwrap();
        assert!(output.contains("Group: G\\r\\u{2066}"));
        assert!(output.contains("* 1: 東京\\u{1b}[31m\\n\\t\\u{202e}"));
        assert!(
            !output
                .chars()
                .any(|c| (c.is_control() && c != '\n') || c == '\u{202e}' || c == '\u{2066}')
        );
    }

    #[test]
    fn flushes_prompt_and_propagates_io_errors() {
        #[derive(Default)]
        struct Output {
            bytes: Vec<u8>,
            flushes: usize,
            fail: bool,
        }
        impl Write for Output {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.bytes.extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                assert!(self.bytes.ends_with(b"Select: "));
                self.flushes += 1;
                if self.fail {
                    Err(io::Error::other("flush failed"))
                } else {
                    Ok(())
                }
            }
        }
        let mut output = Output::default();
        choose(&mut &b"bad\n1\n"[..], &mut output, "G", &["A"], None).unwrap();
        assert_eq!(output.flushes, 2);
        output.fail = true;
        assert!(choose(&mut &b"1\n"[..], &mut output, "G", &["A"], None).is_err());
        assert!(choose(&mut &b"\xff\n"[..], &mut Vec::new(), "G", &["A"], None).is_err());
        assert!(choose(&mut &b"1\n"[..], &mut &mut [0u8; 0][..], "G", &["A"], None).is_err());
    }
}
