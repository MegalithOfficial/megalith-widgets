use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::process::Command;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

const ENDPOINT: &str = "https://api.github.com/graphql";
const USER_AGENT: &str = "megalith-widgets";

const REQUESTED_QUERY: &str = "is:pr is:open archived:false review-requested:@me";
const REVIEWED_QUERY: &str = "is:pr is:open archived:false reviewed-by:@me -author:@me";

const QUERY: &str = r#"
query($requested: String!, $reviewed: String!, $gone: [ID!]!) {
  requested: search(query: $requested, type: ISSUE, first: 40) { nodes { ...pr } }
  reviewed: search(query: $reviewed, type: ISSUE, first: 40) { nodes { ...pr } }
  gone: nodes(ids: $gone) { ...pr }
}
fragment pr on PullRequest {
  id number title url isDraft updatedAt closedAt additions deletions headRefOid state mergeable
  repository { nameWithOwner }
  author { login avatarUrl(size: 96) }
  reviews(last: 50) { nodes { viewerDidAuthor state commit { oid } } }
  commits(last: 50) { nodes { commit { oid } } }
  latest: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}
"#;

/// Avatar bytes survive across refreshes so each author is downloaded once.
static AVATARS: LazyLock<Mutex<HashMap<String, Vec<u8>>>> = LazyLock::new(Default::default);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Open,
    Draft,
    Merged,
    Closed,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mergeable {
    Clean,
    Conflicting,
    Unknown,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Checks {
    None,
    Pending,
    Passing,
    Failing,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Status {
    /// Review requested and you have never reviewed it.
    Requested,
    /// You reviewed it before and were asked again.
    ReReview,
    /// You reviewed it and the author pushed since.
    NewCommits,
    /// Merged or closed after it was on your list.
    Done,
}

#[derive(Clone, Debug)]
pub struct Pr {
    pub id: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    pub repo: String,
    pub author: String,
    pub avatar_url: Option<String>,
    pub avatar: Option<Vec<u8>>,
    pub state: State,
    pub mergeable: Mergeable,
    pub checks: Checks,
    pub updated_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
    pub additions: u64,
    pub deletions: u64,
    pub head_oid: String,
    pub status: Status,
    /// Commits pushed after your last review; 0 when unknown (e.g. force-push).
    pub new_commits: usize,
}

impl Pr {
    /// Changes whenever the PR needs your attention again.
    pub fn attention_key(&self) -> String {
        format!("{}:{:?}:{}", self.id, self.status, self.head_oid)
    }
}

#[derive(Deserialize)]
struct Response {
    data: Option<Data>,
    errors: Option<Vec<GraphqlError>>,
}

#[derive(Deserialize)]
struct GraphqlError {
    message: String,
}

pub struct Snapshot {
    /// Open PRs waiting on you, newest activity first.
    pub open: Vec<Pr>,
    /// Previously tracked PRs that have since been merged or closed.
    pub done: Vec<Pr>,
}

#[derive(Deserialize)]
struct Data {
    requested: Search,
    reviewed: Search,
    gone: Vec<Option<Node>>,
}

#[derive(Deserialize)]
struct Search {
    nodes: Vec<Node>,
}

#[derive(Deserialize)]
struct Connection<T> {
    nodes: Vec<T>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Node {
    id: String,
    number: u64,
    title: String,
    url: String,
    is_draft: bool,
    updated_at: DateTime<Utc>,
    closed_at: Option<DateTime<Utc>>,
    state: String,
    mergeable: String,
    additions: u64,
    deletions: u64,
    head_ref_oid: String,
    repository: Repository,
    author: Option<Author>,
    reviews: Connection<Review>,
    commits: Connection<CommitNode>,
    latest: Connection<LatestCommit>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Repository {
    name_with_owner: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Author {
    login: String,
    avatar_url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Review {
    viewer_did_author: bool,
    state: String,
    commit: Option<Oid>,
}

#[derive(Deserialize)]
struct CommitNode {
    commit: Oid,
}

#[derive(Deserialize)]
struct LatestCommit {
    commit: CheckedCommit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CheckedCommit {
    status_check_rollup: Option<Rollup>,
}

#[derive(Deserialize)]
struct Rollup {
    state: String,
}

#[derive(Deserialize)]
struct Oid {
    oid: String,
}

/// Blocking: run it off the main thread. `tracked` are the ids currently on
/// screen, so anything that drops off the open lists can be reported as done.
pub fn fetch(tracked: Vec<String>) -> Result<Snapshot> {
    let token = token()?;
    let body = serde_json::json!({
        "query": QUERY,
        "variables": {
            "requested": REQUESTED_QUERY,
            "reviewed": REVIEWED_QUERY,
            "gone": tracked,
        },
    });

    let response: Response = match ureq::post(ENDPOINT)
        .set("Authorization", &format!("bearer {token}"))
        .set("User-Agent", USER_AGENT)
        .timeout(Duration::from_secs(20))
        .send_json(body)
    {
        Ok(response) => response
            .into_json()
            .context("unexpected response from GitHub")?,
        Err(ureq::Error::Status(401, _)) => bail!("GitHub rejected the token. run `gh auth login`"),
        Err(ureq::Error::Status(code, _)) => bail!("GitHub returned HTTP {code}"),
        Err(err) => return Err(anyhow!(err).context("couldn't reach GitHub")),
    };

    if let Some(error) = response.errors.and_then(|errors| errors.into_iter().next()) {
        bail!("GitHub: {}", error.message);
    }
    let data = response.data.context("GitHub returned no data")?;

    let mut seen = HashSet::new();
    let mut open: Vec<Pr> = data
        .requested
        .nodes
        .into_iter()
        .map(|node| (node, true))
        .chain(data.reviewed.nodes.into_iter().map(|node| (node, false)))
        .filter(|(node, _)| seen.insert(node.id.clone()))
        .filter_map(|(node, requested)| classify(node, requested))
        .collect();

    open.sort_by_key(|pr| std::cmp::Reverse(pr.updated_at));

    let mut done: Vec<Pr> = data
        .gone
        .into_iter()
        .flatten()
        .filter(|node| matches!(node.state.as_str(), "MERGED" | "CLOSED"))
        .filter_map(|node| classify(node, false))
        .collect();

    attach_avatars(&mut open);
    attach_avatars(&mut done);
    Ok(Snapshot { open, done })
}

fn token() -> Result<String> {
    if let Ok(token) = std::env::var("GITHUB_TOKEN")
        && !token.is_empty()
    {
        return Ok(token);
    }
    let output = Command::new("gh")
        .args(["auth", "token"])
        .output()
        .context("GitHub CLI not found. install `gh` or set GITHUB_TOKEN")?;
    if !output.status.success() {
        bail!("Not signed in. run `gh auth login`");
    }
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

fn classify(node: Node, requested: bool) -> Option<Pr> {
    let reviewed_oid = node
        .reviews
        .nodes
        .iter()
        .rev()
        .find(|review| review.viewer_did_author && review.state != "PENDING")
        .and_then(|review| review.commit.as_ref())
        .map(|commit| commit.oid.as_str());

    let state = match node.state.as_str() {
        "MERGED" => State::Merged,
        "CLOSED" => State::Closed,
        _ if node.is_draft => State::Draft,
        _ => State::Open,
    };

    let status = match (requested, reviewed_oid) {
        _ if matches!(state, State::Merged | State::Closed) => Status::Done,
        (true, None) => Status::Requested,
        (true, Some(_)) => Status::ReReview,
        (false, Some(oid)) if oid != node.head_ref_oid => Status::NewCommits,
        _ => return None,
    };

    let new_commits = reviewed_oid
        .and_then(|oid| {
            let commits = &node.commits.nodes;
            commits
                .iter()
                .position(|commit| commit.commit.oid == oid)
                .map(|index| commits.len() - index - 1)
        })
        .unwrap_or(0);

    let mergeable = match node.mergeable.as_str() {
        "MERGEABLE" => Mergeable::Clean,
        "CONFLICTING" => Mergeable::Conflicting,
        _ => Mergeable::Unknown,
    };

    let checks = node
        .latest
        .nodes
        .first()
        .and_then(|latest| latest.commit.status_check_rollup.as_ref())
        .map_or(Checks::None, |rollup| match rollup.state.as_str() {
            "SUCCESS" => Checks::Passing,
            "FAILURE" | "ERROR" => Checks::Failing,
            _ => Checks::Pending,
        });

    let (author, avatar_url) = match node.author {
        Some(author) => (author.login, Some(author.avatar_url)),
        None => ("ghost".to_owned(), None),
    };

    Some(Pr {
        id: node.id,
        number: node.number,
        title: node.title,
        url: node.url,
        repo: node.repository.name_with_owner,
        author,
        avatar_url,
        avatar: None,
        state,
        mergeable,
        checks,
        updated_at: node.updated_at,
        closed_at: node.closed_at,
        additions: node.additions,
        deletions: node.deletions,
        head_oid: node.head_ref_oid,
        status,
        new_commits,
    })
}

fn attach_avatars(prs: &mut [Pr]) {
    let mut cache = AVATARS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let missing: HashSet<&str> = prs
        .iter()
        .filter_map(|pr| pr.avatar_url.as_deref())
        .filter(|url| !cache.contains_key(*url))
        .collect();

    // Avatars are small; fetching them in parallel keeps the first load snappy.
    let downloaded: Vec<(String, Vec<u8>)> = std::thread::scope(|scope| {
        let handles: Vec<_> = missing
            .into_iter()
            .map(|url| scope.spawn(move || download(url).map(|bytes| (url.to_owned(), bytes))))
            .collect();
        handles
            .into_iter()
            .filter_map(|handle| handle.join().ok().flatten())
            .collect()
    });
    cache.extend(downloaded);

    for pr in prs {
        pr.avatar = pr
            .avatar_url
            .as_ref()
            .and_then(|url| cache.get(url).cloned());
    }
}

fn download(url: &str) -> Option<Vec<u8>> {
    let response = ureq::get(url)
        .timeout(Duration::from_secs(10))
        .call()
        .ok()?;
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(2 << 20)
        .read_to_end(&mut bytes)
        .ok()?;
    Some(bytes)
}
