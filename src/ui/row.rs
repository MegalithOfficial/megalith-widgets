//! A single pull request row, laid out like a table so columns line up.

use crate::github::{Checks, Mergeable, Pr, State, Status};
use adw::prelude::*;
use chrono::{DateTime, Utc};
use gtk::{gdk, glib, pango};
use std::cell::RefCell;
use std::collections::HashMap;

const DIFFSTAT_WIDTH: i32 = 76;
const REF_CHARS: i32 = 15;

/// Shared column widths, so every row lines up like a table.
pub struct Columns([gtk::SizeGroup; 4]);

impl Default for Columns {
    fn default() -> Self {
        Self(std::array::from_fn(|_| {
            gtk::SizeGroup::new(gtk::SizeGroupMode::Horizontal)
        }))
    }
}

pub struct Row {
    pub id: String,
    pub url: String,
    pub widget: gtk::ListBoxRow,
    time: DateTime<Utc>,
    age: gtk::Label,
}

impl Row {
    /// `query` is the lowercased search text, highlighted in the title.
    pub fn new(
        pr: &Pr,
        avatar: Option<gdk::Texture>,
        pinned: bool,
        query: &str,
        columns: &Columns,
    ) -> Self {
        let (state_icon, state_tone, state_tip) = state(pr);
        let state = image(state_icon, 14, &["state", state_tone]);
        state.set_tooltip_text(Some(state_tip));

        let author = adw::Avatar::new(18, Some(&pr.author), true);
        author.set_custom_image(avatar.as_ref());
        author.set_tooltip_text(Some(&pr.author));

        let title = label("", &["pr-title"]);
        title.set_markup(&highlight(&pr.title, query));
        title.set_hexpand(true);
        title.set_ellipsize(pango::EllipsizeMode::End);
        let title_line = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        if pinned {
            let pin = image("pin-symbolic", 11, &["pin"]);
            pin.set_tooltip_text(Some("Pinned"));
            title_line.append(&pin);
        }
        title_line.append(&title);

        let reference = label(
            &format!("{} #{}", short_repo(&pr.repo), pr.number),
            &["pr-ref", "mono"],
        );
        reference.set_ellipsize(pango::EllipsizeMode::Middle);
        reference.set_width_chars(REF_CHARS);
        reference.set_max_width_chars(REF_CHARS);
        reference.set_tooltip_text(Some(&pr.repo));

        // An empty slot keeps the columns aligned when there are no checks.
        let checks = match checks(pr.checks) {
            Some((icon, tone, tip)) => {
                let checks = image(icon, 12, &["ci", tone]);
                checks.set_tooltip_text(Some(tip));
                checks
            }
            None => {
                let empty = gtk::Image::new();
                empty.set_pixel_size(12);
                empty
            }
        };

        let (status_icon, status_tone, status_text) = status(pr);
        let status = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        status.add_css_class("status");
        status.add_css_class(status_tone);
        status.append(&image(status_icon, 12, &[]));
        status.append(&label(&status_text, &[]));

        let diffstat = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        diffstat.add_css_class("diffstat");
        diffstat.add_css_class("mono");
        // The right-aligning hexpand below must not leak into the row layout.
        diffstat.set_hexpand(false);
        diffstat.set_margin_start(8);
        let additions = label(&format!("+{}", pr.additions), &["add"]);
        additions.set_hexpand(true);
        additions.set_xalign(1.0);
        diffstat.append(&additions);
        diffstat.append(&label(&format!("−{}", pr.deletions), &["del"]));

        let age = label("", &["age", "mono"]);
        age.set_width_chars(3);
        age.set_xalign(1.0);

        let [reference_column, status_column, diffstat_column, age_column] = &columns.0;
        reference_column.add_widget(&reference);
        status_column.add_widget(&status);
        diffstat_column.add_widget(&diffstat);
        age_column.add_widget(&age);

        let content = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        for child in [
            state.upcast_ref::<gtk::Widget>(),
            author.upcast_ref(),
            title_line.upcast_ref(),
            reference.upcast_ref(),
            checks.upcast_ref(),
            status.upcast_ref(),
            diffstat.upcast_ref(),
            age.upcast_ref(),
        ] {
            content.append(child);
        }

        let widget = gtk::ListBoxRow::builder().child(&content).build();
        widget.set_tooltip_text(Some(&format!(
            "{}\n{} #{} · {}",
            pr.title, pr.repo, pr.number, pr.author
        )));
        if pr.state == State::Draft {
            widget.add_css_class("draft");
        }

        let row = Self {
            id: pr.id.clone(),
            url: pr.url.clone(),
            widget,
            time: pr
                .closed_at
                .filter(|_| pr.status == Status::Done)
                .unwrap_or(pr.updated_at),
            age,
        };
        row.tick();
        row
    }

    /// Refreshes the relative timestamp.
    pub fn tick(&self) {
        self.age.set_label(&ago(self.time));
    }
}

/// A row-shaped stand-in shown while the first load is in flight.
pub fn placeholder(index: usize) -> gtk::Box {
    let bone = |width: i32, classes: &[&str]| {
        let bone = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        bone.add_css_class("bone");
        for class in classes {
            bone.add_css_class(class);
        }
        bone.set_size_request(width, -1);
        bone.set_valign(gtk::Align::Center);
        bone
    };

    // Varying title widths read as text rather than as a grid of blocks.
    let title_width = [260, 190, 230, 150, 210][index % 5];
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    row.add_css_class("placeholder");
    row.add_css_class(&format!("p{}", index % 5));
    row.append(&bone(14, &["dot"]));
    row.append(&bone(title_width, &[]));
    let filler = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    filler.set_hexpand(true);
    row.append(&filler);
    row.append(&bone(90, &[]));
    row.append(&bone(DIFFSTAT_WIDTH - 20, &[]));
    row
}

/// Decoded avatars, keyed by URL so each is decoded once per session.
#[derive(Default)]
pub struct Avatars(RefCell<HashMap<String, gdk::Texture>>);

impl Avatars {
    pub fn get(&self, pr: &Pr) -> Option<gdk::Texture> {
        let url = pr.avatar_url.as_ref()?;
        if let Some(texture) = self.0.borrow().get(url) {
            return Some(texture.clone());
        }
        let texture = gdk::Texture::from_bytes(&glib::Bytes::from(pr.avatar.as_ref()?)).ok()?;
        self.0.borrow_mut().insert(url.clone(), texture.clone());
        Some(texture)
    }
}

/// Everything that affects how a row looks, minus relative time.
pub fn signature(pr: &Pr) -> String {
    format!(
        "{}|{:?}|{:?}|{:?}|{}|{}|{}|{}|{}",
        pr.attention_key(),
        pr.state,
        pr.mergeable,
        pr.checks,
        pr.title,
        pr.additions,
        pr.deletions,
        pr.new_commits,
        pr.avatar.is_some(),
    )
}

pub fn label(text: &str, classes: &[&str]) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.set_xalign(0.0);
    for class in classes {
        label.add_css_class(class);
    }
    label
}

pub fn image(icon: &str, size: i32, classes: &[&str]) -> gtk::Image {
    let image = gtk::Image::from_icon_name(icon);
    image.set_pixel_size(size);
    for class in classes {
        image.add_css_class(class);
    }
    image
}

fn state(pr: &Pr) -> (&'static str, &'static str, &'static str) {
    match (pr.state, pr.mergeable) {
        (State::Merged, _) => ("git-merge-symbolic", "purple", "Merged"),
        (State::Closed, _) => ("git-pull-request-closed-symbolic", "red", "Closed"),
        (State::Draft, _) => ("git-pull-request-draft-symbolic", "muted", "Draft"),
        (State::Open, Mergeable::Conflicting) => {
            ("git-pull-request-symbolic", "red", "Merge conflicts")
        }
        (State::Open, Mergeable::Clean) => ("git-pull-request-symbolic", "green", "No conflicts"),
        (State::Open, Mergeable::Unknown) => (
            "git-pull-request-symbolic",
            "muted",
            "Checking for conflicts",
        ),
    }
}

fn checks(checks: Checks) -> Option<(&'static str, &'static str, &'static str)> {
    match checks {
        Checks::None => None,
        Checks::Passing => Some(("check-symbolic", "green", "Checks passing")),
        Checks::Failing => Some(("x-symbolic", "red", "Checks failing")),
        Checks::Pending => Some(("dot-fill-symbolic", "amber", "Checks running")),
    }
}

fn status(pr: &Pr) -> (&'static str, &'static str, String) {
    match pr.status {
        Status::Requested => ("eye-symbolic", "blue", "Review".to_owned()),
        Status::ReReview => ("sync-symbolic", "purple", "Re-review".to_owned()),
        Status::NewCommits if pr.new_commits > 0 => (
            "git-commit-symbolic",
            "amber",
            format!("{} new", pr.new_commits),
        ),
        Status::NewCommits => ("git-commit-symbolic", "amber", "Updated".to_owned()),
        Status::Done if pr.state == State::Merged => {
            ("git-merge-symbolic", "purple", "Merged".to_owned())
        }
        Status::Done => (
            "git-pull-request-closed-symbolic",
            "red",
            "Closed".to_owned(),
        ),
    }
}

/// Pango markup for `text` with every case-insensitive match of `query`
/// marked like Zed's search matches.
fn highlight(text: &str, query: &str) -> String {
    let lower = text.to_lowercase();
    // Lowercasing can change byte offsets for some scripts; skip those.
    if query.is_empty() || lower.len() != text.len() {
        return glib::markup_escape_text(text).to_string();
    }
    let mut markup = String::new();
    let mut rest = 0;
    for (start, _) in lower.match_indices(query) {
        if start < rest
            || !text.is_char_boundary(start)
            || !text.is_char_boundary(start + query.len())
        {
            continue;
        }
        markup.push_str(&glib::markup_escape_text(&text[rest..start]));
        markup.push_str(r##"<span background="#f2cc60" bgalpha="35%">"##);
        markup.push_str(&glib::markup_escape_text(&text[start..start + query.len()]));
        markup.push_str("</span>");
        rest = start + query.len();
    }
    markup.push_str(&glib::markup_escape_text(&text[rest..]));
    markup
}

fn short_repo(repo: &str) -> &str {
    repo.rsplit('/').next().unwrap_or(repo)
}

pub fn ago(time: DateTime<Utc>) -> String {
    let secs = (Utc::now() - time).num_seconds().max(0) as u64;
    if secs < 60 {
        "now".to_owned()
    } else {
        ago_secs(secs)
    }
}

pub fn ago_secs(secs: u64) -> String {
    match secs {
        0..3600 => format!("{}m", (secs / 60).max(1)),
        3600..86_400 => format!("{}h", secs / 3600),
        86_400..604_800 => format!("{}d", secs / 86_400),
        _ => format!("{}w", secs / 604_800),
    }
}
