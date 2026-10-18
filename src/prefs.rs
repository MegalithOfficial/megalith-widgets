//! Settings plus pinned, hidden and muted pull requests, persisted as JSON.

use crate::github::{Pr, State};
use gtk::glib;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::PathBuf;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    #[default]
    System,
    Dark,
    Light,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Corner {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    Custom,
}

impl Corner {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "top-left" => Some(Self::TopLeft),
            "top-right" => Some(Self::TopRight),
            "bottom-left" => Some(Self::BottomLeft),
            "bottom-right" => Some(Self::BottomRight),
            "custom" => Some(Self::Custom),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::TopLeft => "top-left",
            Self::TopRight => "top-right",
            Self::BottomLeft => "bottom-left",
            Self::BottomRight => "bottom-right",
            Self::Custom => "custom",
        }
    }
}

impl Default for Corner {
    fn default() -> Self {
        std::env::var("MEGALITH_WIDGETS_CORNER")
            .ok()
            .and_then(|value| Self::parse(&value))
            .filter(|corner| *corner != Self::Custom)
            .unwrap_or(Self::TopLeft)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub notifications: bool,
    pub show_drafts: bool,
    pub refresh_minutes: u32,
    pub appearance: Appearance,
    pub corner: Corner,
    pub custom_x: i32,
    pub custom_y: i32,
    pub automatic_placement: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            notifications: true,
            show_drafts: true,
            refresh_minutes: 2,
            appearance: Appearance::System,
            corner: Corner::default(),
            custom_x: 10,
            custom_y: 10,
            automatic_placement: true,
        }
    }
}

#[derive(Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    pub settings: Settings,
    /// PR node ids kept at the top of every list.
    pinned: BTreeSet<String>,
    /// PR node ids that are never shown or announced again.
    ignored: BTreeSet<String>,
    /// `owner/repo` names switched off in settings.
    unwatched: BTreeSet<String>,
}

impl Prefs {
    pub fn load() -> Self {
        let path = path();
        let Ok(text) = std::fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str(&text).unwrap_or_else(|err| {
            eprintln!("ignoring unreadable {}: {err}", path.display());
            Self::default()
        })
    }

    pub fn save(&self) {
        let path = path();
        let result = (|| {
            std::fs::create_dir_all(path.parent().expect("config path has a parent"))?;
            // Write-then-rename so a crash never leaves a truncated file behind.
            let temp = path.with_extension("json.tmp");
            std::fs::write(&temp, serde_json::to_vec_pretty(self)?)?;
            std::fs::rename(&temp, &path)
        })();
        if let Err(err) = result {
            eprintln!("couldn't save {}: {err}", path.display());
        }
    }

    pub fn is_pinned(&self, pr: &Pr) -> bool {
        self.pinned.contains(&pr.id)
    }

    /// Ignored PRs and PRs from unwatched repositories are never shown or announced.
    pub fn is_hidden(&self, pr: &Pr) -> bool {
        self.ignored.contains(&pr.id) || !self.is_watched(&pr.repo)
    }

    /// Whether the PR belongs on screen at all, given hides and settings.
    pub fn is_visible(&self, pr: &Pr) -> bool {
        !self.is_hidden(pr) && (self.settings.show_drafts || pr.state != State::Draft)
    }

    pub fn set_pinned(&mut self, pr: &Pr, pinned: bool) {
        if pinned {
            self.pinned.insert(pr.id.clone());
        } else {
            self.pinned.remove(&pr.id);
        }
    }

    pub fn ignore(&mut self, pr: &Pr) {
        self.ignored.insert(pr.id.clone());
        self.pinned.remove(&pr.id);
    }

    pub fn unignore_all(&mut self) {
        self.ignored.clear();
    }

    pub fn is_watched(&self, repo: &str) -> bool {
        !self.unwatched.contains(repo)
    }

    pub fn set_watched(&mut self, repo: &str, watched: bool) {
        if watched {
            self.unwatched.remove(repo);
        } else {
            self.unwatched.insert(repo.to_owned());
        }
    }

    /// Ignored PRs among `prs` that would otherwise be shown.
    pub fn ignored_count(&self, prs: &[Pr]) -> usize {
        prs.iter()
            .filter(|pr| self.is_watched(&pr.repo) && self.ignored.contains(&pr.id))
            .count()
    }

    /// Repositories seen in `prs` plus any switched off, sorted for display.
    pub fn repositories(&self, prs: &[Pr]) -> Vec<String> {
        let mut repos: BTreeSet<&str> = prs.iter().map(|pr| pr.repo.as_str()).collect();
        repos.extend(self.unwatched.iter().map(String::as_str));
        repos.into_iter().map(str::to_owned).collect()
    }

    /// Forgets pins for PRs that are gone. Ignores are kept, so a reopened
    /// PR stays ignored. Returns whether anything was dropped.
    pub fn prune(&mut self, prs: &[Pr]) -> bool {
        let before = self.pinned.len();
        self.pinned.retain(|id| prs.iter().any(|pr| &pr.id == id));
        before != self.pinned.len()
    }
}

fn path() -> PathBuf {
    glib::user_config_dir()
        .join(env!("CARGO_PKG_NAME"))
        .join("prefs.json")
}

#[cfg(test)]
mod tests {
    use super::{Corner, Prefs};

    #[test]
    fn old_preferences_keep_their_settings() {
        let prefs: Prefs =
            serde_json::from_str(r#"{"settings":{"refresh_minutes":5},"pinned":["pr-id"]}"#)
                .unwrap();
        assert_eq!(prefs.settings.refresh_minutes, 5);
        assert!(prefs.settings.automatic_placement);
        assert_eq!(prefs.settings.custom_x, 10);
        assert!(prefs.pinned.contains("pr-id"));
    }

    #[test]
    fn custom_position_survives_a_preferences_round_trip() {
        let mut prefs = Prefs::default();
        prefs.settings.corner = Corner::Custom;
        prefs.settings.custom_x = -1200;
        prefs.settings.custom_y = 160;
        prefs.settings.automatic_placement = false;
        let restored: Prefs = serde_json::from_slice(&serde_json::to_vec(&prefs).unwrap()).unwrap();
        assert!(restored == prefs);
    }

    #[test]
    fn macos_placement_fields_are_preserved() {
        let json = r#"{"settings":{"corner":"bottom-right","automatic_placement":false,"custom_x":80,"custom_y":120}}"#;
        let prefs: Prefs = serde_json::from_str(json).unwrap();
        assert_eq!(prefs.settings.corner, Corner::BottomRight);
        assert!(!prefs.settings.automatic_placement);
        let encoded = serde_json::to_value(&prefs).unwrap();
        assert_eq!(encoded["settings"]["custom_x"], 80);
        assert_eq!(encoded["settings"]["custom_y"], 120);
    }
}
