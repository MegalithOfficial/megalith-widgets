pub fn normalize(input: &str) -> Option<String> {
    let input = input.trim();
    let path = input
        .strip_prefix("https://github.com/")
        .or_else(|| input.strip_prefix("http://github.com/"))
        .or_else(|| input.strip_prefix("github.com/"))
        .unwrap_or(input)
        .trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, repo) = path.split_once('/')?;
    let valid = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
    };
    (valid(owner) && valid(repo)).then(|| format!("{owner}/{repo}"))
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn accepts_names_and_github_urls() {
        for input in [
            " Pumpkin-MC/Pumpkin ",
            "https://github.com/Pumpkin-MC/Pumpkin/",
            "github.com/Pumpkin-MC/Pumpkin.git",
        ] {
            assert_eq!(normalize(input).as_deref(), Some("Pumpkin-MC/Pumpkin"));
        }
    }

    #[test]
    fn rejects_other_hosts_and_non_repository_paths() {
        for input in [
            "",
            "Pumpkin",
            "https://example.com/owner/repo",
            "owner/repo/pulls",
            "owner/repo?tab=readme",
            "owner/..",
            "owner/repo name",
        ] {
            assert!(normalize(input).is_none(), "accepted {input}");
        }
    }
}
